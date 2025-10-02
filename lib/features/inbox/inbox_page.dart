// FILE: lib/features/inbox/inbox_page.dart
// A modern 4-tab inbox for a dating app (Flutter + Supabase)
//
// Tabs:
//  • Chats: search, New Matches rail, message list with realtime bumps
//  • Matches: all your matches in a tidy grid
//  • Likes: everyone who liked you; blurred + CTA if not premium
//  • Requests: super-like chat requests (pending matches with an opener)
//
// Notes:
//  • Schema used: matches(id, user_ids, status, updated_at), messages, profiles, swipes
//  • Presence: shows green dot when a peer is online (shared “Online” channel)
//  • Navigation: opens ChatPage by matchId
//  • If you already use PeerAvatar, it’s leveraged below
//
// Optional: plug a real premium flag where indicated (_hasPremium)

import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../chat/chat_page.dart';
import '../chat/widgets/peer_avatar.dart';
import '../paywall/paywall_page.dart';

final DateFormat _fmtTime = DateFormat('HH:mm');
final DateFormat _fmtDow = DateFormat('EEE');
final DateFormat _fmtDayMon = DateFormat('d MMM');

class InboxPage extends StatefulWidget {
  const InboxPage({super.key});

  static const String routeName = 'inbox';
  static const String routePath = '/inbox';

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> with TickerProviderStateMixin {
  final _supa = Supabase.instance.client;

  // premium gating (replace with your real entitlement)
  final bool _hasPremium = false;

  // presence (shared with your app)
  static const String _presenceChannel = 'Online';
  RealtimeChannel? _presence;
  final Set<String> _onlineIds = <String>{};

  // realtime message inserts to bump chats
  RealtimeChannel? _msgChannel;

  // data
  bool _loading = true;
  String _query = '';
  Timer? _searchDebounce;
  static const _searchDelay = Duration(milliseconds: 150);

  // chats list
  List<_ChatRow> _chats = const [];
  Set<int> _myChatIds = <int>{};

  // matches grid (all)
  List<_MatchCard> _matches = const [];

  // likes grid (people who liked me)
  List<_MatchCard> _likes = const [];

  // requests (pending matches with first message)
  List<_RequestRow> _requests = const [];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _startPresence();
    await _loadAll();
    _subscribeMessages();
  }

  @override
  void dispose() {
    _presence?.unsubscribe();
    _msgChannel?.unsubscribe();
    _searchDebounce?.cancel();
    super.dispose();
  }

  // ───────────────────────── presence
  Future<void> _startPresence() async {
    final me = _supa.auth.currentUser?.id;
    if (me == null) return;

    await _presence?.unsubscribe();
    final ch = _supa.channel(_presenceChannel, opts: const RealtimeChannelConfig(self: true));

    ch
        .onPresenceSync((_) {
          final dynamic state = ch.presenceState();
          _onlineIds.clear();

          if (state is Map) {
            for (final group in state.values) {
              if (group is Iterable) {
                for (final p in group) {
                  final id = (p as dynamic).payload?['user_id']?.toString();
                  if (id != null && id.isNotEmpty) _onlineIds.add(id);
                }
              }
            }
          } else if (state is List) {
            for (final s in state) {
              final presences = (s as dynamic).presences;
              if (presences is Iterable) {
                for (final p in presences) {
                  final id = (p as dynamic).payload?['user_id']?.toString();
                  if (id != null && id.isNotEmpty) _onlineIds.add(id);
                }
              }
            }
          }

          if (mounted) setState(() {});
        })
        .onPresenceJoin((payload) {
          for (final p in payload.newPresences) {
            final id = p.payload['user_id']?.toString();
            if (id != null && id.isNotEmpty) _onlineIds.add(id);
          }
          if (mounted) setState(() {});
        })
        .onPresenceLeave((payload) {
          for (final p in payload.leftPresences) {
            final id = p.payload['user_id']?.toString();
            if (id != null && id.isNotEmpty) _onlineIds.remove(id);
          }
          if (mounted) setState(() {});
        })
        .subscribe((status, _) async {
          if (status == RealtimeSubscribeStatus.subscribed) {
            await ch.track({
              'user_id': me,
              'online_at': DateTime.now().toUtc().toIso8601String(),
            });
          }
        });

    _presence = ch;
  }

  // ───────────────────────── data
  Future<void> _loadAll() async {
    final me = _supa.auth.currentUser?.id;
    if (me == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    setState(() => _loading = true);

    try {
      // fetch matches rows first (active only for chats/matches)
      final matches = await _supa
          .from('matches')
          .select('id, user_ids, updated_at, status')
          .contains('user_ids', [me])
          .order('updated_at', ascending: false);

      final matchRows = (matches as List).cast<Map<String, dynamic>>();
      final List<int> chatIds = [];
      final List<String> othersActive = [];
      for (final m in matchRows) {
        if ((m['status'] ?? 'active') != 'active') continue;
        final id = _asInt(m['id']);
        if (id == null) continue;
        chatIds.add(id);
        final uids = ((m['user_ids'] as List?) ?? const []).map((e) => '$e').toList();
        final other = uids.length == 2 ? (uids[0] == me ? uids[1] : uids[0]) : uids.firstWhere((u) => u != me, orElse: () => '');
        if (other.isNotEmpty) othersActive.add(other);
      }
      _myChatIds = chatIds.toSet();

      // parallel loads: profiles for others, last messages, likes for me, pending requests
      final results = await Future.wait([
        othersActive.isEmpty
            ? Future<List<Map<String, dynamic>>>.value(const [])
            : _supa.from('profiles').select('user_id, name, profile_pictures').inFilter('user_id', othersActive),
        chatIds.isEmpty
            ? Future<List<Map<String, dynamic>>>.value(const [])
            : _supa
                .from('messages')
                .select('chat_id, message, sender_id, created_at')
                .inFilter('chat_id', chatIds)
                .order('created_at', ascending: false),
        _supa
            .from('swipes')
            .select('swiper_id')
            .eq('swipee_id', me)
            .eq('liked', true)
            .eq('status', 'active')
            .limit(500),
        // pending requests: matches where I'm in user_ids AND status='pending'
        _supa
            .from('matches')
            .select('id, user_ids, updated_at, status')
            .contains('user_ids', [me])
            .eq('status', 'pending')
            .order('updated_at', ascending: false),
      ]);

      final profiles = (results[0] as List).cast<Map<String, dynamic>>();
      final lastMsgs = (results[1] as List).cast<Map<String, dynamic>>();
      final likesRows = (results[2] as List).cast<Map<String, dynamic>>();
      final pendingRows = (results[3] as List).cast<Map<String, dynamic>>();

      final likers = likesRows.map((r) => r['swiper_id']?.toString() ?? '').where((s) => s.isNotEmpty).toList();
      final byId = {for (final p in profiles) (p['user_id']?.toString() ?? ''): p};
      final Map<int, Map<String, dynamic>> lastByChat = {};
      for (final m in lastMsgs) {
        final cid = _asInt(m['chat_id']);
        if (cid == null) continue;
        lastByChat.putIfAbsent(cid, () => m); // first is newest due to order desc
      }

      // compose chats + matches
      final List<_ChatRow> chats = [];
      final List<_MatchCard> matchesCards = [];
      for (final row in matchRows) {
        if ((row['status'] ?? 'active') != 'active') continue;
        final cid = _asInt(row['id']);
        if (cid == null) continue;

        final uids = ((row['user_ids'] as List?) ?? const []).map((e) => '$e').toList();
        final other = uids.length == 2 ? (uids[0] == me ? uids[1] : uids[0]) : uids.firstWhere((u) => u != me, orElse: () => '');

        final prof = byId[other] ?? const {};
        final name = (prof['name'] ?? 'Member').toString();
        final pics = (prof['profile_pictures'] as List?) ?? const [];
        final avatar = pics.isNotEmpty ? (pics.first?.toString() ?? '') : '';

        final last = lastByChat[cid];
        final text = (last?['message'] ?? '').toString();
        final at = DateTime.tryParse('${last?['created_at']}');
        final lastSenderId = last?['sender_id']?.toString();

        chats.add(_ChatRow(
          chatId: cid,
          otherUserId: other,
          name: name,
          avatarUrl: avatar,
          lastMessage: text,
          lastAt: at,
          lastSenderId: lastSenderId,
        ));

        matchesCards.add(_MatchCard(userId: other, name: name, avatarUrl: avatar));
      }

      // compose likes
      List<_MatchCard> likesCards = [];
      if (likers.isNotEmpty) {
        final likersProf = await _supa
            .from('profiles')
            .select('user_id, name, profile_pictures')
            .inFilter('user_id', likers);

        for (final p in (likersProf as List).cast<Map<String, dynamic>>()) {
          final pics = (p['profile_pictures'] as List?) ?? const [];
          likesCards.add(_MatchCard(
            userId: p['user_id']?.toString() ?? '',
            name: (p['name'] ?? 'Member').toString(),
            avatarUrl: pics.isNotEmpty ? (pics.first?.toString() ?? '') : '',
          ));
        }
      }

      // compose requests (pending matches)
      final List<_RequestRow> requests = [];
      if (pendingRows.isNotEmpty) {
        final Set<String> reqOtherIds = {};
        final List<int> reqChatIds = [];

        for (final r in pendingRows) {
          final uids = ((r['user_ids'] as List?) ?? const []).map((e) => '$e').toList();
          final other = uids.length == 2 ? (uids[0] == me ? uids[1] : uids[0]) : uids.firstWhere((u) => u != me, orElse: () => '');
          if (other.isEmpty) continue;
          reqOtherIds.add(other);
          final id = _asInt(r['id']);
          if (id != null) reqChatIds.add(id);
        }

        final reqProfiles = reqOtherIds.isEmpty
            ? const <Map<String, dynamic>>[]
            : (await _supa.from('profiles').select('user_id, name, profile_pictures').inFilter('user_id', reqOtherIds.toList()))
                .cast<Map<String, dynamic>>();

        final Map<String, Map<String, dynamic>> reqProfById = {
          for (final p in reqProfiles) (p['user_id']?.toString() ?? ''): p
        };

        // get first (oldest) message for each pending chat (the opener)
        final reqMsgs = reqChatIds.isEmpty
            ? const <Map<String, dynamic>>[]
            : (await _supa
                    .from('messages')
                    .select('chat_id, message, sender_id, created_at')
                    .inFilter('chat_id', reqChatIds)
                    .order('created_at', ascending: true))
                .cast<Map<String, dynamic>>();

        final Map<int, Map<String, dynamic>> firstByChat = {};
        for (final m in reqMsgs) {
          final cid = _asInt(m['chat_id']);
          if (cid == null) continue;
          firstByChat.putIfAbsent(cid, () => m); // first is oldest due to ascending
        }

        for (final r in pendingRows) {
          final cid = _asInt(r['id']);
          if (cid == null) continue;
          final uids = ((r['user_ids'] as List?) ?? const []).map((e) => '$e').toList();
          final other = uids.length == 2 ? (uids[0] == me ? uids[1] : uids[0]) : uids.firstWhere((u) => u != me, orElse: () => '');
          if (other.isEmpty) continue;

          final prof = reqProfById[other] ?? const {};
          final name = (prof['name'] ?? 'Member').toString();
          final pics = (prof['profile_pictures'] as List?) ?? const [];
          final avatar = pics.isNotEmpty ? (pics.first?.toString() ?? '') : '';
          final opener = firstByChat[cid];
          final openerText = (opener?['message'] ?? '').toString();
          final openerAt = DateTime.tryParse('${opener?['created_at']}');

          requests.add(_RequestRow(
            matchId: cid,
            otherUserId: other,
            name: name,
            avatarUrl: avatar,
            opener: openerText,
            sentAt: openerAt,
          ));
        }
      }

      if (!mounted) return;
      setState(() {
        _chats = chats;
        _matches = matchesCards;
        _likes = likesCards;
        _requests = requests;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load inbox: $e')));
    }
  }

  // Accept a request: flip match to active (and optionally create your like)
  Future<void> _acceptRequest(_RequestRow r) async {
    try {
      await _supa.from('matches').update({'status': 'active'}).eq('id', r.matchId);
      // OPTIONAL: also record your like in swipes if you need that audit trail:
      // await _supa.from('swipes').insert({
      //   'swiper_id': _supa.auth.currentUser!.id,
      //   'swipee_id': r.otherUserId,
      //   'liked': true,
      //   'status': 'active',
      // });

      // move it to chats immediately
      await _loadAll();
      if (!mounted) return;
      // Go straight into the chat if you want:
      context.goNamed(ChatPage.routeName, queryParameters: {'id': r.matchId.toString()});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not accept: $e')));
    }
  }

  // Decline a request: archive/delete (here we just set status to 'archived')
  Future<void> _declineRequest(_RequestRow r) async {
    try {
      await _supa.from('matches').update({'status': 'archived'}).eq('id', r.matchId);
      await _loadAll();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not decline: $e')));
    }
  }

  // bump chats list on new message
  void _subscribeMessages() {
    _msgChannel?.unsubscribe();
    _msgChannel = _supa
        .channel('public:messages')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          callback: (payload) {
            final r = payload.newRecord;
            final cid = _asInt(r['chat_id']);
            if (cid == null) return;

            // if this belongs to an active chat → bump
            if (_myChatIds.contains(cid)) {
              final createdAt = DateTime.tryParse('${r['created_at']}');
              final senderId = r['sender_id']?.toString();
              final text = (r['message'] ?? '').toString();

              final idx = _chats.indexWhere((c) => c.chatId == cid);
              if (idx == -1) return;

              final updated = _chats[idx].copyWith(
                lastMessage: text,
                lastAt: createdAt,
                lastSenderId: senderId,
              );

              final next = List<_ChatRow>.from(_chats)..removeAt(idx)..insert(0, updated);
              if (mounted) setState(() => _chats = next);
            } else {
              // if it belongs to a pending match we have in Requests, update the opener text
              final idx = _requests.indexWhere((q) => q.matchId == cid);
              if (idx != -1) {
                final updated = _requests[idx].copyWith(
                  opener: (r['message'] ?? '').toString(),
                  sentAt: DateTime.tryParse('${r['created_at']}'),
                );
                final next = List<_RequestRow>.from(_requests);
                next[idx] = updated;
                if (mounted) setState(() => _requests = next);
              }
            }
          },
        )
        .subscribe();
  }

  // ───────────────────────── helpers
  int? _asInt(dynamic v) => v is int ? v : int.tryParse('$v');

  String _prettyTime(DateTime t) {
    final now = DateTime.now();
    if (t.year == now.year && t.month == now.month && t.day == now.day) return _fmtTime.format(t);
    if (t.isAfter(now.subtract(const Duration(days: 6)))) return _fmtDow.format(t);
    return _fmtDayMon.format(t);
  }

  // ───────────────────────── UI

  @override
  Widget build(BuildContext context) {
    final me = _supa.auth.currentUser?.id;
    final unreplied = me == null
        ? 0
        : _chats.where((c) => (c.lastSenderId?.isNotEmpty ?? false) && c.lastSenderId != me).length;

    final q = _query.trim().toLowerCase();
    final filteredChats = q.isEmpty ? _chats : _chats.where((c) => c.name.toLowerCase().contains(q)).toList();
    final newMatches = filteredChats.where((c) => c.lastMessage.isEmpty).toList();

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        backgroundColor: const Color(0xFF0E0F13),
        appBar: AppBar(
          title: const Text('Inbox', style: TextStyle(fontWeight: FontWeight.w900)),
          centerTitle: false,
          backgroundColor: const Color(0xFF0E0F13),
          bottom: const TabBar(
            isScrollable: false,
            indicatorColor: Color(0xFF6759FF),
            tabs: [
              Tab(text: 'Chats'),
              Tab(text: 'Matches'),
              Tab(text: 'Likes'),
              Tab(text: 'Requests'),
            ],
          ),
          actions: const [SizedBox(width: 8)],
        ),
        body: SafeArea(
          child: _loading
              ? const _InboxSkeleton()
              : RefreshIndicator(
                  color: const Color(0xFF6759FF),
                  onRefresh: _loadAll,
                  child: TabBarView(
                    physics: const BouncingScrollPhysics(),
                    children: [
                      // ───────── Chats tab
                      CustomScrollView(
                        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                        slivers: [
                          SliverToBoxAdapter(child: _searchBar(filteredChats.length)),
                          SliverToBoxAdapter(child: _header('New Matches')),
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
                                  ],
                                ],
                              ),
                            ),
                          ),
                          if (filteredChats.isEmpty)
                            const SliverToBoxAdapter(
                              child: Padding(
                                padding: EdgeInsets.all(24),
                                child: Center(child: Text('No conversations', style: TextStyle(color: Colors.white70))),
                              ),
                            )
                          else
                            SliverList.separated(
                              itemCount: filteredChats.length,
                              separatorBuilder: (_, __) => const SizedBox(height: 10),
                              itemBuilder: (_, i) {
                                final it = filteredChats[i];
                                final online = _onlineIds.contains(it.otherUserId);
                                final yourTurn = it.lastSenderId != null &&
                                    it.lastSenderId != me &&
                                    it.lastMessage.isNotEmpty;
                                final time = it.lastAt == null ? '' : _prettyTime(it.lastAt!.toLocal());
                                return Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  child: InkWell(
                                    onTap: () => context.goNamed(
                                      ChatPage.routeName,
                                      queryParameters: {'id': it.chatId.toString()},
                                    ),
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
                                          PeerAvatar(
                                            userId: it.otherUserId,
                                            online: online,
                                            size: 56,
                                            border: Border.all(color: const Color(0xFF2A2C33), width: 2),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: Text(
                                                        it.name,
                                                        maxLines: 1,
                                                        overflow: TextOverflow.ellipsis,
                                                        style: const TextStyle(
                                                            fontWeight: FontWeight.w700, fontSize: 16),
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
                                                  it.lastMessage.isEmpty ? 'Say hi 👋' : it.lastMessage,
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
                                  ),
                                );
                              },
                            ),
                          const SliverToBoxAdapter(child: SizedBox(height: 18)),
                        ],
                      ),

                      // ───────── Matches tab (grid)
                      _PeopleGrid(
                        people: _matches,
                        onlineIds: _onlineIds,
                        onTapCard: (u) {
                          // open chat if there is one
                          final row = _chats.firstWhere((c) => c.otherUserId == u, orElse: () => _ChatRow.empty());
                          if (row.chatId != -1) {
                            context.goNamed(ChatPage.routeName, queryParameters: {'id': row.chatId.toString()});
                          }
                        },
                      ),

                      // ───────── Likes tab (grid, blurred if !premium)
                      Stack(
                        children: [
                          _PeopleGrid(
                            people: _likes,
                            onlineIds: _onlineIds,
                            onTapCard: (u) {
                              if (!_hasPremium) return;
                              // e.g. open their profile or start a match flow
                            },
                          ),
                          if (!_hasPremium)
                            Positioned.fill(
                              child: ClipRRect(
                                child: BackdropFilter(
                                  filter: ImageFilter.blur(sigmaX: 3, sigmaY: 3),
                                  child: Container(
                                    color: const Color(0xAA0E0F13),
                                    child: Center(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.favorite, size: 42, color: Colors.amber),
                                          const SizedBox(height: 10),
                                          const Text('See who liked you',
                                              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                                          const SizedBox(height: 6),
                                          const Text('Unlock with Premium',
                                              style: TextStyle(color: Colors.white70)),
                                          const SizedBox(height: 14),
                                          ElevatedButton(
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: const Color(0xFF6759FF),
                                              foregroundColor: Colors.white,
                                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                                            ),
                                            onPressed: () => context.goNamed(PaywallPage.routeName),
                                            child: const Text('Upgrade'),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),

                      // ───────── Requests tab
                      _RequestsList(
                        items: _requests,
                        onlineIds: _onlineIds,
                        onAccept: _acceptRequest,
                        onDecline: _declineRequest,
                        onViewProfile: (r) {
                          // TODO: push your profile route here if you have one.
                          // For now, open chat read-only? We’ll no-op.
                        },
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  // ───────────────────────── small widgets

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

  Widget _header(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
        child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      );

  Widget _newMatchesRail(List<_ChatRow> items) {
    return SizedBox(
      height: 116,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: 1 + items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          if (i == 0) {
            // Likes CTA card sits first
            final likesCount = _likes.length;
            final String? badge = likesCount > 0 ? (likesCount > 99 ? '99+' : '$likesCount') : null;
            return InkWell(
              onTap: () => context.goNamed(PaywallPage.routeName),
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
                    const Text('Likes', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            );
          }

          final m = items[i - 1];
          final online = _onlineIds.contains(m.otherUserId);
          return InkWell(
            onTap: () => context.goNamed(ChatPage.routeName, queryParameters: {'id': m.chatId.toString()}),
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
                      border: Border.all(color: const Color(0xFF2A2C33), width: 2),
                    ),
                    child: ClipOval(
                      child: Center(
                        child: PeerAvatar(
                          userId: m.otherUserId,
                          online: online,
                          size: 86,
                          border: Border.all(color: const Color(0xFF2A2C33), width: 2),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    m.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ],
              ),
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
      decoration: BoxDecoration(color: const Color(0xFFFF3B30), borderRadius: BorderRadius.circular(999)),
      child: Text(s, style: const TextStyle(fontWeight: FontWeight.w800)),
    );
  }
}

// ───────────────────────── grids & cells

class _PeopleGrid extends StatelessWidget {
  const _PeopleGrid({
    required this.people,
    required this.onlineIds,
    required this.onTapCard,
  });

  final List<_MatchCard> people;
  final Set<String> onlineIds;
  final void Function(String userId) onTapCard;

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) {
      return const Center(child: Text('Nothing here yet', style: TextStyle(color: Colors.white70)));
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.72,
      ),
      itemCount: people.length,
      itemBuilder: (_, i) {
        final m = people[i];
        final online = onlineIds.contains(m.userId);
        return InkWell(
          onTap: () => onTapCard(m.userId),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF14151A),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF23242A)),
            ),
            child: Column(
              children: [
                const SizedBox(height: 10),
                PeerAvatar(
                  userId: m.userId,
                  online: online,
                  size: 76,
                  border: Border.all(color: const Color(0xFF2A2C33), width: 2),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    m.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 6),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ───────────────────────── Requests list

class _RequestsList extends StatelessWidget {
  const _RequestsList({
    required this.items,
    required this.onlineIds,
    required this.onAccept,
    required this.onDecline,
    required this.onViewProfile,
  });

  final List<_RequestRow> items;
  final Set<String> onlineIds;
  final void Function(_RequestRow) onAccept;
  final void Function(_RequestRow) onDecline;
  final void Function(_RequestRow) onViewProfile;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Center(child: Text('No requests yet', style: TextStyle(color: Colors.white70)));
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final r = items[i];
        final online = onlineIds.contains(r.otherUserId);
        final time = r.sentAt == null ? '' : _prettyTimeStatic(r.sentAt!.toLocal());
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF14151A),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF23242A)),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Row(
                children: [
                  PeerAvatar(
                    userId: r.otherUserId,
                    online: online,
                    size: 56,
                    border: Border.all(color: const Color(0xFF2A2C33), width: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                        const SizedBox(height: 4),
                        Text(r.opener.isEmpty ? 'Sent you a message' : r.opener,
                            maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 14)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(time, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => onViewProfile(r),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: BorderSide(color: Colors.white.withValues(alpha: .6)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: const Text('View profile', style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => onAccept(r),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6759FF),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: const Text('Like back', style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton(
                    tooltip: 'Dismiss',
                    onPressed: () => onDecline(r),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  static String _prettyTimeStatic(DateTime t) {
    final now = DateTime.now();
    if (t.year == now.year && t.month == now.month && t.day == now.day) return _fmtTime.format(t);
    if (t.isAfter(now.subtract(const Duration(days: 6)))) return _fmtDow.format(t);
    return _fmtDayMon.format(t);
  }
}

// ───────────────────────── models

class _ChatRow {
  final int chatId;
  final String otherUserId;
  final String name;
  final String avatarUrl;
  final String lastMessage;
  final DateTime? lastAt;
  final String? lastSenderId;

  const _ChatRow({
    required this.chatId,
    required this.otherUserId,
    required this.name,
    required this.avatarUrl,
    required this.lastMessage,
    required this.lastAt,
    required this.lastSenderId,
  });

  static _ChatRow empty() => const _ChatRow(
        chatId: -1,
        otherUserId: '',
        name: '',
        avatarUrl: '',
        lastMessage: '',
        lastAt: null,
        lastSenderId: null,
      );

  _ChatRow copyWith({
    String? name,
    String? avatarUrl,
    String? lastMessage,
    DateTime? lastAt,
    String? lastSenderId,
  }) {
    return _ChatRow(
      chatId: chatId,
      otherUserId: otherUserId,
      name: name ?? this.name,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      lastMessage: lastMessage ?? this.lastMessage,
      lastAt: lastAt ?? this.lastAt,
      lastSenderId: lastSenderId ?? this.lastSenderId,
    );
  }
}

class _MatchCard {
  final String userId;
  final String name;
  final String avatarUrl;

  const _MatchCard({required this.userId, required this.name, required this.avatarUrl});
}

class _RequestRow {
  final int matchId;
  final String otherUserId;
  final String name;
  final String avatarUrl;
  final String opener;
  final DateTime? sentAt;

  const _RequestRow({
    required this.matchId,
    required this.otherUserId,
    required this.name,
    required this.avatarUrl,
    required this.opener,
    required this.sentAt,
  });

  _RequestRow copyWith({String? opener, DateTime? sentAt}) => _RequestRow(
        matchId: matchId,
        otherUserId: otherUserId,
        name: name,
        avatarUrl: avatarUrl,
        opener: opener ?? this.opener,
        sentAt: sentAt ?? this.sentAt,
      );
}

// ───────────────────────── skeleton

class _InboxSkeleton extends StatelessWidget {
  const _InboxSkeleton();

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        // fake search bar
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFF14151A),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF23242A)),
              ),
            ),
          ),
        ),
        // shimmer-ish rows
        SliverList.separated(
          itemCount: 6,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (_, __) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Container(
              height: 78,
              decoration: BoxDecoration(
                color: const Color(0xFF14151A),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF23242A)),
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}
