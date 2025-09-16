// FILE: lib/features/matches/chat_list_page.dart
// Chat list (Flutter + Supabase) — clean, compiling, optimized.
// - Debounced search
// - Parallel data loads
// - Incremental realtime message updates (no full reload)
// - Robust presence parsing for multiple SDK shapes

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_page.dart';
import '../paywall/paywall_page.dart';

/// Global date formatters (shared, avoid per-build allocations)
final DateFormat kFmtTime = DateFormat('HH:mm');
final DateFormat kFmtDow = DateFormat('EEE');
final DateFormat kFmtDayMon = DateFormat('d MMM');

class ChatListPage extends StatefulWidget {
  const ChatListPage({super.key});

  static const String routeName = 'chat_list';
  static const String routePath = '/chats';

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage> {
  final SupabaseClient _supa = Supabase.instance.client;

  bool _loading = true;
  List<_ChatListItem> _items = const [];
  String _query = '';
  int _likesCount = 0;

  // Debounce for search edits
  Timer? _searchDebounce;
  static const Duration _searchDelay = Duration(milliseconds: 150);

  // Presence
  static const String _presenceChannel = 'Online';
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
    _searchDebounce?.cancel();
    super.dispose();
  }

  // ──────────────────────────── Presence
  Future<void> _startPresence() async {
    final String? me = _supa.auth.currentUser?.id;
    if (me == null) return;

    await _presence?.unsubscribe();
    final ch = _supa.channel(
      _presenceChannel,
      opts: const RealtimeChannelConfig(self: true),
    );

    ch
        .onPresenceSync((_) {
          final dynamic state = ch.presenceState();
          _onlineUserIds.clear();

          // Support both shapes returned by different supabase_dart versions.
          if (state is Map) {
            for (final group in state.values) {
              if (group is Iterable) {
                for (final p in group) {
                  final id = (p as dynamic).payload?['user_id']?.toString();
                  if (id != null && id.isNotEmpty) _onlineUserIds.add(id);
                }
              }
            }
          } else if (state is List) {
            for (final s in state) {
              final presences = (s as dynamic).presences;
              if (presences is Iterable) {
                for (final p in presences) {
                  final id = (p as dynamic).payload?['user_id']?.toString();
                  if (id != null && id.isNotEmpty) _onlineUserIds.add(id);
                }
              }
            }
          }
          if (mounted) setState(() {});
        })
        .onPresenceJoin((payload) {
          for (final p in payload.newPresences) {
            final id = p.payload['user_id']?.toString();
            if (id != null && id.isNotEmpty) _onlineUserIds.add(id);
          }
          if (mounted) setState(() {});
        })
        .onPresenceLeave((payload) {
          for (final p in payload.leftPresences) {
            final id = p.payload['user_id']?.toString();
            if (id != null && id.isNotEmpty) _onlineUserIds.remove(id);
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

  // ──────────────────────────── Load data
  Future<void> _load() async {
    final String? me = _supa.auth.currentUser?.id;
    if (me == null) {
      if (!mounted) return;
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

      final List<Map<String, dynamic>> matchRows = (matches as List).cast<Map<String, dynamic>>();
      if (matchRows.isEmpty) {
        if (!mounted) return;
        setState(() {
          _items = const [];
          _myChatIds = {};
          _likesCount = 0;
          _loading = false;
        });
        return;
      }

      // 2) Derive chatIds + counterpart ids
      final List<int> chatIds = <int>[];
      final List<String> otherIds = <String>[];
      for (final m in matchRows) {
        final int? cid = _asInt(m['id']);
        if (cid == null) continue;
        chatIds.add(cid);
        final List<String> uids = (m['user_ids'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
        final String other = (uids.length == 2)
            ? (uids[0] == me ? uids[1] : uids[0])
            : uids.firstWhere((uid) => uid != me, orElse: () => '');
        if (other.isNotEmpty) otherIds.add(other);
      }
      _myChatIds = chatIds.toSet();

      // 3) Parallel fetch profiles, last messages, likes
      final futures = <Future<dynamic>>[
        otherIds.isEmpty
            ? Future<List<Map<String, dynamic>>>.value(const [])
            : _supa
                .from('profiles')
                .select('user_id, name, profile_pictures')
                .inFilter('user_id', otherIds),
        chatIds.isEmpty
            ? Future<List<Map<String, dynamic>>>.value(const [])
            : _fetchLastMessagesSnapshot(chatIds),
        _fetchLikesCountCompat(me),
      ];

      final results = await Future.wait(futures);
      final List<Map<String, dynamic>> profilesRaw = (results[0] as List).cast<Map<String, dynamic>>();
      final List<Map<String, dynamic>> lastMsgsRaw = (results[1] as List).cast<Map<String, dynamic>>();
      final int likes = results[2] as int;

      final Map<String, Map<String, dynamic>> profilesById = <String, Map<String, dynamic>>{
        for (final p in profilesRaw) (p['user_id']?.toString() ?? ''): p,
      };

      final Map<int, Map<String, dynamic>> lastMsgByChat = <int, Map<String, dynamic>>{};
      for (final m in lastMsgsRaw) {
        final int? cid = _asInt(m['chat_id']);
        if (cid == null) continue;
        lastMsgByChat.putIfAbsent(cid, () => m); // first is newest
      }

      // 4) Compose list
      final List<_ChatListItem> items = <_ChatListItem>[];
      for (final row in matchRows) {
        final int? cid = _asInt(row['id']);
        if (cid == null) continue;

        final List<String> uids = (row['user_ids'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
        final String other = (uids.length == 2)
            ? (uids[0] == me ? uids[1] : uids[0])
            : uids.firstWhere((uid) => uid != me, orElse: () => '');

        final Map<String, dynamic> prof = profilesById[other] ?? const {};
        final List<dynamic> pics = (prof['profile_pictures'] as List?) ?? const [];
        final String avatar = pics.isNotEmpty ? (pics.first?.toString() ?? '') : '';
        final String name = (prof['name'] ?? 'Member').toString();

        final Map<String, dynamic>? last = lastMsgByChat[cid];
        final String lastText = (last?['message'] ?? '').toString();
        final DateTime? lastAt = DateTime.tryParse('${last?['created_at']}');
        final String? lastSenderId = last?['sender_id']?.toString();

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
        _items = items;
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

  Future<List<Map<String, dynamic>>> _fetchLastMessagesSnapshot(List<int> chatIds) async {
    final msgs = await _supa
        .from('messages')
        .select('chat_id, message, sender_id, created_at')
        .inFilter('chat_id', chatIds)
        .order('created_at', ascending: false);
    return (msgs as List).cast<Map<String, dynamic>>();
  }

  Future<int> _fetchLikesCountCompat(String me) async {
    try {
      final likeRows = await _supa
          .from('swipes')
          .select('id')
          .eq('swipee_id', me)
          .eq('liked', true)
          .eq('status', 'active')
          .limit(9999);
      return (likeRows as List).length;
    } catch (_) {
      return 0;
    }
  }

  // ──────────────────────────── Realtime messages (incremental)
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
            final int? cid = _asInt(map['chat_id']);
            if (cid == null) return;
            if (!_myChatIds.contains(cid)) return;

            final DateTime? createdAt = DateTime.tryParse('${map['created_at']}');
            final String? senderId = map['sender_id']?.toString();
            final String text = (map['message'] ?? '').toString();

            final int idx = _items.indexWhere((e) => e.chatId == cid);
            if (idx == -1) return;

            final _ChatListItem updated = _items[idx].copyWith(
              lastMessage: text,
              lastAt: createdAt,
              lastSenderId: senderId,
            );

            final List<_ChatListItem> next = List<_ChatListItem>.from(_items)
              ..removeAt(idx)
              ..insert(0, updated);

            if (mounted) setState(() => _items = next);
          },
        )
        .subscribe();
  }

  // ──────────────────────────── UI
  @override
  Widget build(BuildContext context) {
    final String? me = _supa.auth.currentUser?.id;
    final int unreplied = me == null
        ? 0
        : _items.where((i) => (i.lastSenderId?.isNotEmpty ?? false) && i.lastSenderId != me).length;

    final String q = _query.trim().toLowerCase();
    final List<_ChatListItem> filtered = q.isEmpty
        ? _items
        : _items.where((i) => i.name.toLowerCase().contains(q)).toList(growable: false);

    final List<_ChatListItem> newMatches = filtered.where((i) => i.lastMessage.isEmpty).toList(growable: false);

    return Scaffold(
      backgroundColor: const Color(0xFF0E0F13),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E0F13),
        elevation: 0,
        centerTitle: false,
        title: const Text('Bangher', style: TextStyle(fontWeight: FontWeight.w900)),
        actions: const [SizedBox(width: 8)],
      ),
      body: SafeArea(
        child: _loading
            ? const _ChatListSkeleton()
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
                            const Text('Messages', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
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
                            child: Text('No conversations found', style: TextStyle(color: Colors.white70)),
                          ),
                        ),
                      )
                    else
                      SliverList.separated(
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final it = filtered[i];
                          final bool online = _onlineUserIds.contains(it.otherUserId);
                          final String? meId = _supa.auth.currentUser?.id;
                          final bool yourTurn = it.lastSenderId != null && it.lastSenderId != meId && it.lastMessage.isNotEmpty;
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

  // Search (debounced)
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
                onChanged: (v) {
                  _searchDebounce?.cancel();
                  _searchDebounce = Timer(_searchDelay, () {
                    if (!mounted) return;
                    setState(() => _query = v);
                  });
                },
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
        itemCount: 1 + newMatches.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          if (i == 0) {
            return _LikesTile(
              count: _likesCount,
              onTap: () => context.goNamed(PaywallPage.routeName),
            );
          }
          final m = newMatches[i - 1];
          final bool online = _onlineUserIds.contains(m.otherUserId);
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
    final String s = n > 99 ? '99+' : '$n';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFFF3B30),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(s, style: const TextStyle(fontWeight: FontWeight.w800)),
    );
  }

  // Helpers
  int? _asInt(dynamic v) => v is int ? v : int.tryParse('$v');
}

// ──────────────────────────── Models

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

  _ChatListItem copyWith({
    String? name,
    String? avatarUrl,
    String? lastMessage,
    DateTime? lastAt,
    String? lastSenderId,
  }) => _ChatListItem(
        chatId: chatId,
        otherUserId: otherUserId,
        name: name ?? this.name,
        avatarUrl: avatarUrl ?? this.avatarUrl,
        lastMessage: lastMessage ?? this.lastMessage,
        lastAt: lastAt ?? this.lastAt,
        lastSenderId: lastSenderId ?? this.lastSenderId,
      );
}

// ──────────────────────────── Widgets

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
    final String time = item.lastAt == null ? '' : _prettyTime(item.lastAt!.toLocal());

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF14151A),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF23242A)),
          boxShadow: const [BoxShadow(blurRadius: 12, color: Colors.black38, offset: Offset(0, 6))],
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
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
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
                          child: const Text('Your turn', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
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
    final DateTime now = DateTime.now();
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return kFmtTime.format(t);
    }
    if (t.isAfter(now.subtract(const Duration(days: 6)))) {
      return kFmtDow.format(t);
    }
    return kFmtDayMon.format(t);
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
                            errorWidget: (_, __, ___) => const ColoredBox(color: Color(0xFF1E1F24)),
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
    final String? badge = count > 0 ? (count > 99 ? '99+' : '$count') : null;

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
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [Color(0xFFFFD54F), Color(0xFFFFB300)]),
                boxShadow: [BoxShadow(blurRadius: 12, color: Colors.black45, offset: Offset(0, 6))],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 78,
                    height: 78,
                    decoration: const BoxDecoration(color: Color(0xFF0E0F13), shape: BoxShape.circle),
                    child: const Icon(Icons.favorite, color: Colors.amber, size: 34),
                  ),
                  if (badge != null)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: Colors.amber, borderRadius: BorderRadius.circular(999)),
                        child: Text(badge,
                            style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 11)),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            const Text('Likes', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────── Skeletons

class _ChatListSkeleton extends StatelessWidget {
  const _ChatListSkeleton();

  @override
  Widget build(BuildContext context) {
    return _PulseAll(
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        slivers: const [
          SliverToBoxAdapter(child: _SearchBarSkeleton()),
          SliverToBoxAdapter(child: _SectionTitleSkeleton()),
          SliverToBoxAdapter(child: _NewMatchesRailSkeleton()),
          SliverToBoxAdapter(child: _MessagesHeaderSkeleton()),
          _ChatListTilesSkeleton(count: 6),
          SliverToBoxAdapter(child: SizedBox(height: 18)),
        ],
      ),
    );
  }
}

class _SearchBarSkeleton extends StatelessWidget {
  const _SearchBarSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: const Color(0xFF14151A),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF23242A)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: const [
            _SkeletonCircle(d: 20),
            SizedBox(width: 10),
            Expanded(child: _SkeletonBox(height: 12, radius: 6)),
          ],
        ),
      ),
    );
  }
}

class _SectionTitleSkeleton extends StatelessWidget {
  const _SectionTitleSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(12, 14, 12, 8),
      child: _SkeletonBox(width: 120, height: 16, radius: 6),
    );
  }
}

class _NewMatchesRailSkeleton extends StatelessWidget {
  const _NewMatchesRailSkeleton();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 116,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemBuilder: (_, i) => Column(
          children: const [
            _SkeletonCircle(d: 86),
            SizedBox(height: 6),
            _SkeletonBox(width: 60, height: 10, radius: 4),
          ],
        ),
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemCount: 6,
      ),
    );
  }
}

class _MessagesHeaderSkeleton extends StatelessWidget {
  const _MessagesHeaderSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Row(
        children: const [
          _SkeletonBox(width: 100, height: 16, radius: 6),
          SizedBox(width: 8),
          _SkeletonBox(width: 28, height: 16, radius: 999),
        ],
      ),
    );
  }
}

class _ChatListTilesSkeleton extends StatelessWidget {
  const _ChatListTilesSkeleton({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return SliverList.separated(
      itemCount: count,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, __) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF14151A),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF23242A)),
            boxShadow: const [BoxShadow(blurRadius: 12, color: Colors.black38, offset: Offset(0, 6))],
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            children: const [
              _SkeletonCircle(d: 56),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SkeletonBox(width: 140, height: 12, radius: 6),
                    SizedBox(height: 8),
                    _SkeletonBox(width: double.infinity, height: 10, radius: 6),
                  ],
                ),
              ),
              SizedBox(width: 10),
              _SkeletonBox(width: 40, height: 10, radius: 6),
            ],
          ),
        ),
      ),
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  const _SkeletonBox({this.width = double.infinity, required this.height, this.radius = 12});
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: const Color(0xFF202227), borderRadius: BorderRadius.circular(radius)),
    );
  }
}

class _SkeletonCircle extends StatelessWidget {
  const _SkeletonCircle({required this.d});
  final double d;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: d,
      height: d,
      decoration: const BoxDecoration(color: Color(0xFF202227), shape: BoxShape.circle),
    );
  }
}

class _PulseAll extends StatefulWidget {
  const _PulseAll({required this.child});
  final Widget child;

  @override
  State<_PulseAll> createState() => _PulseAllState();
}

class _PulseAllState extends State<_PulseAll> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
  late final Animation<double> _a =
      CurvedAnimation(parent: _c, curve: Curves.easeInOut).drive(Tween(begin: 0.55, end: 1.0));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _a,
      child: widget.child,
      builder: (_, child) => Opacity(opacity: _a.value, child: child),
    );
  }
}
