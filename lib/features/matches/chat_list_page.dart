// FILE: lib/features/matches/chat_list_page.dart
// Chat list (pure Flutter + Supabase) — Tinder-like layout
//
// - Search bar (“Search N matches”).
// - “New Matches” horizontal rail = matches with no messages yet.
// - Left “Likes” card (counts swipes where liked=true & swipee_id = me).
// - Messages list with online dot and optional “Your turn” chip.
// - Realtime: refresh on new messages.
// - Presence: same "Online" channel as swipe page.
// - Taps navigate to ChatPage via router (query param "id").
//
// Styling matches your app’s dark look used in the swipe page.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_page.dart'; // for ChatPage.routeName
import '../paywall/paywall_page.dart'; // for Likes card tap (optional paywall)

class ChatListPage extends StatefulWidget {
  const ChatListPage({super.key});

  static const String routeName = 'chat_list';
  static const String routePath = '/chats';

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage> {
  final _supa = Supabase.instance.client;

  bool _loading = true;
  List<_ChatListItem> _items = const [];
  String _query = '';
  int _likesCount = 0;

  // Presence
  static const _presenceChannel = 'Online';
  RealtimeChannel? _presence;
  final Set<String> _onlineUserIds = <String>{};

  // Realtime messages
  RealtimeChannel? _msgChannel;
  Set<int> _myChatIds = <int>{};

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _startPresence();
    await _load();
    _subscribeMessages();
  }

  @override
  void dispose() {
    _presence?.unsubscribe();
    _msgChannel?.unsubscribe();
    super.dispose();
  }

  // ───────────────────────────── Presence
  Future<void> _startPresence() async {
    final me = _supa.auth.currentUser?.id;
    if (me == null) return;

    await _presence?.unsubscribe();
    final ch = _supa.channel(
      _presenceChannel,
      opts: const RealtimeChannelConfig(self: true),
    );

    ch
        .onPresenceSync((_) {
          final states = ch.presenceState();
          _onlineUserIds
            ..clear()
            ..addAll(states
                .expand((s) => s.presences)
                .map((p) => p.payload['user_id']?.toString())
                .whereType<String>());
          if (mounted) setState(() {});
        })
        .onPresenceJoin((payload) {
          for (final p in payload.newPresences) {
            final id = p.payload['user_id']?.toString();
            if (id != null) _onlineUserIds.add(id);
          }
          if (mounted) setState(() {});
        })
        .onPresenceLeave((payload) {
          for (final p in payload.leftPresences) {
            final id = p.payload['user_id']?.toString();
            if (id != null) _onlineUserIds.remove(id);
          }
          if (mounted) setState(() {});
        })
        .subscribe((status, error) async {
          if (status == RealtimeSubscribeStatus.subscribed) {
            await ch.track({
              'user_id': me,
              'online_at': DateTime.now().toUtc().toIso8601String(),
            });
          }
        });

    _presence = ch;
  }

  // ───────────────────────────── Load data
  Future<void> _load() async {
    final me = _supa.auth.currentUser?.id;
    if (me == null) {
      setState(() {
        _loading = false;
        _items = const [];
      });
      return;
    }

    setState(() => _loading = true);

    try {
      // 1) Matches where user_ids contains me
      final matches = await _supa
          .from('matches')
          .select('id, user_ids, updated_at')
          .contains('user_ids', [me])
          .order('updated_at', ascending: false);

      final matchRows = (matches as List).cast<Map<String, dynamic>>();
      if (matchRows.isEmpty) {
        setState(() {
          _items = const [];
          _myChatIds = {};
          _likesCount = 0;
          _loading = false;
        });
        return;
      }

      final chatIds = <int>[];
      final otherIds = <String>[];
      for (final m in matchRows) {
        final id = m['id'] is int ? m['id'] as int : int.tryParse('${m['id']}');
        if (id == null) continue;
        chatIds.add(id);
        final uids =
            (m['user_ids'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
        final other = (uids.length == 2)
            ? (uids[0] == me ? uids[1] : uids[0])
            : uids.firstWhere((uid) => uid != me, orElse: () => '');
        if (other.isNotEmpty) otherIds.add(other);
      }
      _myChatIds = chatIds.toSet();

      // 2) Batch load profiles for others
      Map<String, Map<String, dynamic>> profilesById = {};
      if (otherIds.isNotEmpty) {
        final profs = await _supa
            .from('profiles')
            .select('user_id, name, profile_pictures, is_online, last_seen')
            .inFilter('user_id', otherIds);
        for (final p in (profs as List).cast<Map<String, dynamic>>()) {
          profilesById[p['user_id']?.toString() ?? ''] = p;
        }
      }

      // 3) Batch load last messages (newest per chat)
      Map<int, Map<String, dynamic>> lastMsgByChat = {};
      if (chatIds.isNotEmpty) {
        final msgs = await _supa
            .from('messages')
            .select('chat_id, message, sender_id, created_at')
            .inFilter('chat_id', chatIds)
            .order('created_at', ascending: false);
        for (final m in (msgs as List).cast<Map<String, dynamic>>()) {
          final cid = m['chat_id'] is int
              ? m['chat_id'] as int
              : int.tryParse('${m['chat_id']}');
          if (cid == null) continue;
          lastMsgByChat.putIfAbsent(cid, () => m); // first = newest
          if (lastMsgByChat.length == chatIds.length) break;
        }
      }

      // 4) Likes count (simple count of swipes that liked you)
      int likes = 0;
      try {
        final likeRows = await _supa
            .from('swipes')
            .select('id')
            .eq('swipee_id', me)
            .eq('liked', true)
            .eq('status', 'active')
            .limit(999);
        likes = (likeRows as List).length;
      } catch (_) {
        likes = 0; // table exists in your app; if it fails, just zero
      }

      // 5) Compose list items
      final items = <_ChatListItem>[];
      for (final row in matchRows) {
        final cid =
            row['id'] is int ? row['id'] as int : int.tryParse('${row['id']}');
        if (cid == null) continue;

        final uids =
            (row['user_ids'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
        final other = (uids.length == 2)
            ? (uids[0] == me ? uids[1] : uids[0])
            : uids.firstWhere((uid) => uid != me, orElse: () => '');

        final prof = profilesById[other] ?? const {};
        final pics = (prof['profile_pictures'] as List?) ?? const [];
        final avatar = pics.isNotEmpty ? (pics.first?.toString() ?? '') : '';
        final name = (prof['name'] ?? 'Member').toString();

        final last = lastMsgByChat[cid];
        final lastText = (last?['message'] ?? '').toString();
        final lastAt = DateTime.tryParse('${last?['created_at']}');
        final lastSenderId = last?['sender_id']?.toString();

        items.add(_ChatListItem(
          chatId: cid,
          otherUserId: other,
          name: name,
          avatarUrl: avatar,
          lastMessage: lastText,
          lastAt: lastAt,
          lastSenderId: lastSenderId,
        ));
      }

      if (!mounted) return;
      setState(() {
        _items = items; // matches already ordered by updated_at desc
        _likesCount = likes;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _items = const [];
        _likesCount = 0;
        _loading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load chats: $e')),
      );
    }
  }

  // ───────────────────────────── Realtime: refresh when a new message lands
  void _subscribeMessages() {
    _msgChannel?.unsubscribe();
    _msgChannel = _supa
        .channel('public:messages')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          callback: (payload) {
            final map = payload.newRecord;
            final cidRaw = map['chat_id'];
            final cid = cidRaw is int ? cidRaw : int.tryParse('$cidRaw');
            if (cid != null && _myChatIds.contains(cid)) {
              _load();
            }
          },
        )
        .subscribe();
  }

  // ───────────────────────────── UI
  @override
  Widget build(BuildContext context) {
    final me = _supa.auth.currentUser?.id;
    final unreplied = me == null
        ? 0
        : _items.where((i) => (i.lastSenderId?.isNotEmpty ?? false) && i.lastSenderId != me).length;

    final filtered = _query.trim().isEmpty
        ? _items
        : _items
            .where((i) => i.name.toLowerCase().contains(_query.trim().toLowerCase()))
            .toList(growable: false);

    final newMatches = filtered.where((i) => i.lastMessage.isEmpty).toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0E0F13),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E0F13),
        elevation: 0,
        centerTitle: false,
        title: const Text('Bangher', style: TextStyle(fontWeight: FontWeight.w900)),
        actions: const [
          SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                color: const Color(0xFF6759FF),
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                  slivers: [
                    SliverToBoxAdapter(child: _searchBar(filtered.length)),
                    SliverToBoxAdapter(child: _sectionHeader('New Matches')),
                    SliverToBoxAdapter(child: _newMatchesRail(newMatches)),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                        child: Row(
                          children: [
                            const Text('Messages',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                            if (unreplied > 0) ...[
                              const SizedBox(width: 8),
                              _badge(unreplied),
                            ]
                          ],
                        ),
                      ),
                    ),
                    if (filtered.isEmpty)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(
                            child: Text('No conversations found',
                                style: TextStyle(color: Colors.white70)),
                          ),
                        ),
                      )
                    else
                      SliverList.separated(
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final it = filtered[i];
                          final online = _onlineUserIds.contains(it.otherUserId);
                          final meId = _supa.auth.currentUser?.id;
                          final yourTurn =
                              it.lastSenderId != null && it.lastSenderId != meId && (it.lastMessage.isNotEmpty);
                          return _ChatTile(
                            item: it,
                            online: online,
                            yourTurn: yourTurn,
                            onTap: () => context.goNamed(
                              ChatPage.routeName,
                              queryParameters: {'id': it.chatId.toString()},
                            ),
                          );
                        },
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 18)),
                  ],
                ),
              ),
      ),
    );
  }

  // Search
  Widget _searchBar(int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF14151A),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF23242A)),
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            const Icon(Icons.search, color: Colors.white70),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                style: const TextStyle(fontSize: 16),
                decoration: InputDecoration(
                  hintText: 'Search $count matches',
                  hintStyle: const TextStyle(color: Colors.white54),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
      child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
    );
  }

  // Horizontal “New Matches” rail + Likes card
  Widget _newMatchesRail(List<_ChatListItem> newMatches) {
    return SizedBox(
      height: 116,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: 1 + newMatches.length, // first tile = Likes
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          if (i == 0) {
            return _LikesTile(
              count: _likesCount,
              onTap: () => context.goNamed(PaywallPage.routeName),
            );
          }
          final m = newMatches[i - 1];
          final online = _onlineUserIds.contains(m.otherUserId);
          return _MiniMatchCard(
            name: m.name,
            imageUrl: m.avatarUrl,
            online: online,
            onTap: () => context.goNamed(
              ChatPage.routeName,
              queryParameters: {'id': m.chatId.toString()},
            ),
          );
        },
      ),
    );
  }

  Widget _badge(int n) {
    final s = n > 99 ? '99+' : '$n';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFFF3B30),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(s, style: const TextStyle(fontWeight: FontWeight.w800)),
    );
  }
}

// ───────────────────────────── Models

class _ChatListItem {
  final int chatId;
  final String otherUserId;
  final String name;
  final String avatarUrl;
  final String lastMessage;
  final DateTime? lastAt;
  final String? lastSenderId;

  const _ChatListItem({
    required this.chatId,
    required this.otherUserId,
    required this.name,
    required this.avatarUrl,
    required this.lastMessage,
    required this.lastAt,
    required this.lastSenderId,
  });
}

// ───────────────────────────── Widgets

class _ChatTile extends StatelessWidget {
  const _ChatTile({
    required this.item,
    required this.online,
    required this.yourTurn,
    required this.onTap,
  });

  final _ChatListItem item;
  final bool online;
  final bool yourTurn;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final time = item.lastAt == null ? '' : _prettyTime(item.lastAt!.toLocal());

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF14151A),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF23242A)),
          boxShadow: const [
            BoxShadow(blurRadius: 12, color: Colors.black38, offset: Offset(0, 6)),
          ],
        ),
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            _Avatar(url: item.avatarUrl, online: online),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      if (yourTurn) const SizedBox(width: 8),
                      if (yourTurn)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF22252C),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: const Color(0xFF2F86FF)),
                          ),
                          child: const Text('Your turn',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.lastMessage.isEmpty ? 'Say hi 👋' : item.lastMessage,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(time, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  String _prettyTime(DateTime t) {
    final now = DateTime.now();
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return DateFormat('HH:mm').format(t);
    }
    if (t.isAfter(now.subtract(const Duration(days: 6)))) {
      return DateFormat('EEE').format(t); // Mon, Tue...
    }
    return DateFormat('d MMM').format(t); // 3 Jan
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.url, required this.online});
  final String url;
  final bool online;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: const BoxDecoration(shape: BoxShape.circle),
          child: ClipOval(
            child: url.isEmpty
                ? const ColoredBox(color: Color(0xFF1E1F24))
                : CachedNetworkImage(
                    imageUrl: url,
                    fit: BoxFit.cover,
                    fadeInDuration: const Duration(milliseconds: 120),
                    errorWidget: (_, __, ___) => const ColoredBox(color: Color(0xFF1E1F24)),
                  ),
          ),
        ),
        // Online dot
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: online ? const Color(0xFF2ECC71) : const Color(0xFF50535B),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF14151A), width: 2),
            ),
          ),
        ),
      ],
    );
  }
}

class _MiniMatchCard extends StatelessWidget {
  const _MiniMatchCard({
    required this.name,
    required this.imageUrl,
    required this.online,
    required this.onTap,
  });

  final String name;
  final String imageUrl;
  final bool online;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: 86,
        child: Column(
          children: [
            Stack(
              children: [
                Container(
                  width: 86,
                  height: 86,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFF2A2C33), width: 2),
                  ),
                  child: ClipOval(
                    child: imageUrl.isEmpty
                        ? const ColoredBox(color: Color(0xFF1E1F24))
                        : CachedNetworkImage(
                            imageUrl: imageUrl,
                            fit: BoxFit.cover,
                            fadeInDuration: const Duration(milliseconds: 120),
                            errorWidget: (_, __, ___) =>
                                const ColoredBox(color: Color(0xFF1E1F24)),
                          ),
                  ),
                ),
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: online ? const Color(0xFF2ECC71) : const Color(0xFF50535B),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF0E0F13), width: 2),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}

class _LikesTile extends StatelessWidget {
  const _LikesTile({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final badge = count > 0 ? (count > 99 ? '99+' : '$count') : null;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: 86,
        child: Column(
          children: [
            Container(
              width: 86,
              height: 86,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [Color(0xFFFFD54F), Color(0xFFFFB300)],
                ),
                boxShadow: const [
                  BoxShadow(blurRadius: 12, color: Colors.black45, offset: Offset(0, 6)),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 78,
                    height: 78,
                    decoration: const BoxDecoration(
                      color: Color(0xFF0E0F13),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.favorite, color: Colors.amber, size: 34),
                  ),
                  if (badge != null)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.amber,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          badge,
                          style: const TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.w800,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            const Text('Likes',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
