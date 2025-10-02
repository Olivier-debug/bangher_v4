// FILE: lib/features/chat/chat_page.dart
// Modern chat screen with larger avatar, clean header, soft bubbles, pill composer,
// realtime profile updates, presence, typing indicators, and PeerProfileCache seeding.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_repository.dart';
import '../../core/cache/peer_profile_cache.dart';
// If you added the dedicated avatar widget earlier, you can swap the header image
// to PeerAvatar by importing it and replacing the CachedNetworkImage below.
// import 'widgets/peer_avatar.dart';

/// Strongly-typed navigation args for ChatPage.
class ChatPageArgs {
  const ChatPageArgs({required this.matchId});
  final int matchId;
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.matchId});

  static const String routePath = '/chat';
  static const String routeName = 'chat';

  static Route<void> route(ChatPageArgs args) {
    return MaterialPageRoute<void>(
      settings: const RouteSettings(name: ChatPage.routeName),
      builder: (_) => ChatPage(matchId: args.matchId),
    );
  }

  final int matchId;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late final ChatRepository _repo;
  final _client = Supabase.instance.client;

  late final TextEditingController _textCtrl;
  late final ScrollController _scrollCtrl;

  StreamSubscription<List<Map<String, dynamic>>>? _messagesSub;
  RealtimeChannel? _presenceChannel;
  RealtimeChannel? _profileChannel;

  final List<ChatMessage> _messages = <ChatMessage>[];
  final Set<String> _onlineUserIds = <String>{};
  final Set<String> _typingUserIds = <String>{};

  String? _currentUserId;
  Timer? _typingDebounce;
  Timer? _lastSeenTicker;

  // Peer (the person you're chatting with)
  String? _peerUserId;
  String _peerName = 'Member';
  String _peerAvatar = '';
  DateTime? _peerLastSeenUtc;

  @override
  void initState() {
    super.initState();
    _repo = ChatRepository();
    _textCtrl = TextEditingController();
    _scrollCtrl = ScrollController();

    _currentUserId = _client.auth.currentUser?.id;
    if (_currentUserId == null) return;

    _bootstrapPeer().then((_) => _subscribeProfileUpdates());

    _messagesSub = _repo.streamMessages(widget.matchId).listen((rows) {
      setState(() {
        _messages
          ..clear()
          ..addAll(rows.map(ChatMessage.fromMap));
      });
      _scrollToBottom();
    });

    _repo.subscribeToMessageInserts(chatId: widget.matchId, onInsert: (_) {});

    _repo.listenTyping(onTyping: (payload) {
      final uid = payload['user_id']?.toString();
      final typing = (payload['typing'] as bool?) ?? false;
      if (uid == null || uid == _currentUserId) return;
      setState(() {
        if (typing) {
          _typingUserIds.add(uid);
        } else {
          _typingUserIds.remove(uid);
        }
      });
      Future.delayed(const Duration(seconds: 5), () {
        if (!mounted) return;
        setState(() => _typingUserIds.remove(uid));
      });
    });

    _presenceChannel = _repo.joinPresence(
      chatId: widget.matchId,
      userId: _currentUserId!,
      onSync: (ids) => setState(() => _onlineUserIds
        ..clear()
        ..addAll(ids)),
      onJoin: (uid) => setState(() => _onlineUserIds.add(uid)),
      onLeave: (uid) => setState(() => _onlineUserIds.remove(uid)),
    );

    _lastSeenTicker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _messagesSub?.cancel();
    _typingDebounce?.cancel();
    _lastSeenTicker?.cancel();

    if (_presenceChannel != null) {
      _presenceChannel!.unsubscribe();
      _client.removeChannel(_presenceChannel!);
    }
    if (_profileChannel != null) {
      _profileChannel!.unsubscribe();
      _client.removeChannel(_profileChannel!);
    }

    _repo.dispose();
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ──────────────────────────── Peer bootstrap & live updates

  Future<void> _bootstrapPeer() async {
    try {
      final matchRow = await _client
          .from('matches')
          .select('user_ids')
          .eq('id', widget.matchId)
          .single();

      final List<String> userIds =
          ((matchRow['user_ids'] as List?) ?? const [])
              .map((e) => e.toString())
              .toList();

      final String me = _currentUserId!;
      final String other = userIds.firstWhere((u) => u != me, orElse: () => '');
      if (other.isEmpty) return;
      _peerUserId = other;

      final cached = await PeerProfileCache.instance.read(other);
      if (cached != null && mounted) {
        final String name = (cached['name'] ?? 'Member').toString();
        final List<dynamic> pics = (cached['profile_pictures'] as List?) ?? const [];
        final String avatar = pics.isNotEmpty ? (pics.first?.toString() ?? '') : '';
        final DateTime? lastSeen = _parseTsUtc(cached['last_seen']);
        setState(() {
          _peerName = name;
          _peerAvatar = avatar;
          _peerLastSeenUtc = lastSeen;
        });
      }

      final prof = await _client
          .from('profiles')
          .select('name, profile_pictures, last_seen')
          .eq('user_id', other)
          .maybeSingle();

      if (!mounted || prof == null) return;

      final String name = (prof['name']?.toString() ?? 'Member');
      final List<dynamic> pics = (prof['profile_pictures'] as List?) ?? const [];
      final String avatar = pics.isNotEmpty ? (pics.first?.toString() ?? '') : '';
      final DateTime? lastSeen = _parseTsUtc(prof['last_seen']);

      setState(() {
        _peerName = name;
        _peerAvatar = avatar;
        _peerLastSeenUtc = lastSeen;
      });

      await PeerProfileCache.instance.write(other, {
        'user_id': other,
        'name': name,
        'profile_pictures': pics,
        'last_seen': lastSeen?.toIso8601String(),
      });
    } catch (_) {}
  }

  void _subscribeProfileUpdates() {
    final peer = _peerUserId;
    if (peer == null || peer.isEmpty) return;

    _profileChannel = _client
        .channel('profile-${peer}_updates')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'profiles',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: peer,
          ),
          callback: (payload) async {
            final newRec = payload.newRecord;
            if (!mounted) return;

            String name = _peerName;
            String avatar = _peerAvatar;
            DateTime? lastSeen = _peerLastSeenUtc;
            List<dynamic> pics = <dynamic>[];

            if (newRec.containsKey('name')) {
              name = (newRec['name']?.toString() ?? name);
            }
            if (newRec.containsKey('profile_pictures')) {
              pics = (newRec['profile_pictures'] as List?) ?? const [];
              if (pics.isNotEmpty) avatar = pics.first?.toString() ?? avatar;
            }
            if (newRec.containsKey('last_seen')) {
              lastSeen = _parseTsUtc(newRec['last_seen']);
            }

            setState(() {
              _peerName = name;
              _peerAvatar = avatar;
              _peerLastSeenUtc = lastSeen;
            });

            try {
              await PeerProfileCache.instance.write(peer, {
                'user_id': peer,
                'name': name,
                'profile_pictures': pics.isEmpty ? [_peerAvatar] : pics,
                'last_seen': lastSeen?.toIso8601String(),
              });
            } catch (_) {}
          },
        )
        .subscribe();
  }

  DateTime? _parseTsUtc(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v.toUtc();
    try {
      return DateTime.parse(v.toString()).toUtc();
    } catch (_) {
      return null;
    }
  }

  // ──────────────────────────── Typing & send helpers

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _sendMessage() async {
    final uid = _currentUserId;
    if (uid == null) return;
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;

    await _repo.sendMessage(
      chatId: widget.matchId,
      senderId: uid,
      text: text,
    );

    _textCtrl.clear();
    _sendTyping(isTyping: false);
  }

  void _onChangedInput(String value) {
    _typingDebounce?.cancel();
    _sendTyping(isTyping: true);
    _typingDebounce = Timer(const Duration(seconds: 2), () {
      _sendTyping(isTyping: false);
    });
  }

  Future<void> _sendTyping({required bool isTyping}) async {
    final uid = _currentUserId;
    if (uid == null) return;
    await _repo.sendTyping(
      chatId: widget.matchId,
      userId: uid,
      isTyping: isTyping,
    );
  }

  // ──────────────────────────── Status helpers

  bool get _peerOnline => _peerUserId != null && _onlineUserIds.contains(_peerUserId);
  bool get _peerTyping => _peerUserId != null && _typingUserIds.contains(_peerUserId);

  String _statusLine() {
    if (_peerTyping) return 'typing…';
    if (_peerOnline) return 'online';
    if (_peerLastSeenUtc == null) return '';
    final dt = _peerLastSeenUtc!.toLocal();
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'last seen just now';
    if (diff.inMinutes < 60) return 'last seen ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'last seen ${diff.inHours}h ago';
    return 'last seen ${DateFormat('d MMM, HH:mm').format(dt)}';
  }

  // ──────────────────────────── UI

  @override
  Widget build(BuildContext context) {
    if (_currentUserId == null) {
      return const Scaffold(
        body: Center(child: Text('Sign in required to chat.')),
      );
    }

    const bg = Color(0xFF0B0C10);
    final bubbleMe = const LinearGradient(
      colors: [Color(0xFFFF0F7B), Color(0xFF6759FF)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
    const bubbleOther = Color(0xFF1A1C22);

    return Scaffold(
      backgroundColor: bg,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(72),
        child: AppBar(
          automaticallyImplyLeading: true,
          elevation: 0,
          backgroundColor: bg,
          surfaceTintColor: Colors.transparent,
          titleSpacing: 0,
          title: Row(
            children: [
              const SizedBox(width: 4),
              // You can swap this for PeerAvatar if you added it:
              // PeerAvatar(userId: _peerUserId, online: _peerOnline, size: 44)
              Stack(
                children: [
                  ClipOval(
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: _peerAvatar.isEmpty
                          ? const ColoredBox(color: Color(0xFF23242A))
                          : CachedNetworkImage(
                              imageUrl: _peerAvatar,
                              fit: BoxFit.cover,
                              fadeInDuration: const Duration(milliseconds: 120),
                              errorWidget: (_, __, ___) => const ColoredBox(color: Color(0xFF23242A)),
                            ),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: _peerOnline ? const Color(0xFF2ECC71) : const Color(0xFF50535B),
                        shape: BoxShape.circle,
                        border: Border.all(color: bg, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _peerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: Text(
                        _statusLine(),
                        key: ValueKey('${_peerOnline}_${_peerTyping}_${_peerLastSeenUtc?.toIso8601String()}'),
                        style: const TextStyle(fontSize: 13, color: Colors.white70),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _HeaderIcon(
                icon: Icons.call_outlined,
                onTap: () {},
                tooltip: 'Call',
              ),
              const SizedBox(width: 6),
              _HeaderIcon(
                icon: Icons.info_outline,
                onTap: () {
                  // Navigate to peer profile if you have a route
                },
                tooltip: 'Profile',
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          // Messages
          Expanded(
            child: ListView.separated(
              controller: _scrollCtrl,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              itemCount: _messages.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final m = _messages[index];
                final mine = m.senderId == _currentUserId;

                final bubble = Container(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.78,
                  ),
                  decoration: BoxDecoration(
                    color: mine ? null : bubbleOther,
                    gradient: mine ? bubbleMe : null,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(18),
                      topRight: const Radius.circular(18),
                      bottomLeft: mine ? const Radius.circular(18) : const Radius.circular(6),
                      bottomRight: mine ? const Radius.circular(6) : const Radius.circular(18),
                    ),
                    boxShadow: const [
                      BoxShadow(blurRadius: 14, color: Colors.black54, offset: Offset(0, 6)),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Column(
                      crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                      children: [
                        Text(
                          m.message,
                          style: TextStyle(
                            color: mine ? Colors.white : Colors.white,
                            fontSize: 15.5,
                            height: 1.25,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          DateFormat('HH:mm').format(m.createdAt.toLocal()),
                          style: TextStyle(
                            fontSize: 11,
                            color: mine
                                ? Colors.white.withValues(alpha: 0.8)
                                : Colors.white.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                );

                return Align(
                  alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: bubble,
                );
              },
            ),
          ),

          // typing strip (peer only)
          if (_peerTyping)
            Padding(
              padding: const EdgeInsets.only(left: 18, right: 18, bottom: 6),
              child: Row(
                children: const [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('typing…', style: TextStyle(color: Colors.white70)),
                ],
              ),
            ),

          // Composer
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _RoundIconButton(
                    icon: Icons.add,
                    onTap: () {},
                    tooltip: 'Attach',
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF121319),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: const Color(0xFF24262E)),
                      ),
                      child: TextField(
                        controller: _textCtrl,
                        minLines: 1,
                        maxLines: 5,
                        onChanged: _onChangedInput,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Message ${_peerName.split(' ').first}…',
                          hintStyle: const TextStyle(color: Colors.white54),
                          border: InputBorder.none,
                        ),
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _SendButton(onTap: _sendMessage),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// Header action icon
class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({required this.icon, required this.onTap, this.tooltip});
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: const Color(0x141FFFFF),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0x22FFFFFF)),
          ),
          child: Icon(icon, size: 20),
        ),
      ), 
    );
  }
}

// Rounded small icon button (composer left)
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({required this.icon, required this.onTap, this.tooltip});
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 42,
          height: 42,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFF121319),
          ),
          child: Icon(icon, size: 22),
        ),
      ),
    );
  }
}

// Send button with gradient pill
class _SendButton extends StatelessWidget {
  const _SendButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Ink(
        width: 46,
        height: 46,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [Color(0xFFFF0F7B), Color(0xFF6759FF)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(blurRadius: 14, color: Colors.black54, offset: Offset(0, 6)),
          ],
        ),
        child: const Icon(Icons.send, color: Colors.white),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// Message model (unchanged)
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.message,
    required this.createdAt,
  });

  final int id;
  final int chatId;
  final String senderId;
  final String message;
  final DateTime createdAt;

  static ChatMessage fromMap(Map<String, dynamic> map) {
    DateTime parseTs(dynamic v) {
      if (v is DateTime) return v.toUtc();
      if (v is String) return DateTime.parse(v).toUtc();
      return DateTime.now().toUtc();
    }

    return ChatMessage(
      id: (map['id'] as num).toInt(),
      chatId: (map['chat_id'] as num).toInt(),
      senderId: map['sender_id'] as String,
      message: map['message'] as String? ?? '',
      createdAt: parseTs(map['created_at']),
    );
  }
}
