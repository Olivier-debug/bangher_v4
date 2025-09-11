// FILE: lib/features/chat/chat_page.dart
// Minimal, provider-free chat screen wired to ChatRepository (v2 Realtime)

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_repository.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.matchId});

  final int matchId; // The match/chat room id

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late final ChatRepository _repo;
  final _client = Supabase.instance.client;

  late final TextEditingController _textCtrl;
  late final ScrollController _scrollCtrl;

  StreamSubscription<List<Map<String, dynamic>>>? _messagesSub;
  RealtimeChannel? _presenceChannel; // used in dispose to unsubscribe

  final List<ChatMessage> _messages = <ChatMessage>[];
  final Set<String> _onlineUserIds = <String>{};
  final Set<String> _typingUserIds = <String>{};

  String? _currentUserId;
  Timer? _typingDebounce;

  @override
  void initState() {
    super.initState();
    _repo = ChatRepository();
    _textCtrl = TextEditingController();
    _scrollCtrl = ScrollController();

    _currentUserId = _client.auth.currentUser?.id;

    // Guard: require auth
    if (_currentUserId == null) return;

    // 1) Start streaming messages (ordered asc)
    _messagesSub = _repo.streamMessages(widget.matchId).listen((rows) {
      setState(() {
        _messages
          ..clear()
          ..addAll(rows.map(ChatMessage.fromMap));
      });
      _scrollToBottom();
    });

    // 2) Subscribe to inserts mainly so the repository creates the broadcast channel
    _repo.subscribeToMessageInserts(
      chatId: widget.matchId,
      onInsert: (_) {},
    );

    // 3) Typing indicator via broadcast
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
      // Auto-clear typing after 5s
      Future.delayed(const Duration(seconds: 5), () {
        if (!mounted) return;
        setState(() => _typingUserIds.remove(uid));
      });
    });

    // 4) Presence (online users in this chat)
    _presenceChannel = _repo.joinPresence(
      chatId: widget.matchId,
      userId: _currentUserId!,
      onSync: (ids) => setState(() => _onlineUserIds
        ..clear()
        ..addAll(ids)),
      onJoin: (uid) => setState(() => _onlineUserIds.add(uid)),
      onLeave: (uid) => setState(() => _onlineUserIds.remove(uid)),
    );
  }

  @override
  void dispose() {
    _messagesSub?.cancel();
    _typingDebounce?.cancel();

    // Properly unsubscribe and remove the presence channel
    if (_presenceChannel != null) {
      _presenceChannel!.unsubscribe();
      _client.removeChannel(_presenceChannel!);
    }

    _repo.dispose();
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

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
    // Debounce typing broadcast
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

  @override
  Widget build(BuildContext context) {
    // If not signed in, show a simple notice
    if (_currentUserId == null) {
      return const Scaffold(
        body: Center(child: Text('Sign in required to chat.')),
      );
    }

    final othersTyping = _typingUserIds
        .where((id) => id != _currentUserId)
        .toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Chat'),
            const SizedBox(width: 8),
            if (_onlineUserIds.isNotEmpty)
              const Icon(Icons.circle, size: 10, color: Colors.green),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.separated(
              controller: _scrollCtrl,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              itemCount: _messages.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final m = _messages[index];
                final mine = m.senderId == _currentUserId;
                final bubbleColor = mine
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.secondaryContainer;
                final textColor = mine
                    ? Theme.of(context).colorScheme.onPrimary
                    : Theme.of(context).colorScheme.onSecondaryContainer;

                return Align(
                  alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: bubbleColor,
                      borderRadius: const BorderRadius.all(Radius.circular(16)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Column(
                        crossAxisAlignment:
                            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                        children: [
                          Text(
                            m.message,
                            style: TextStyle(color: textColor),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            DateFormat('HH:mm').format(m.createdAt),
                            style: TextStyle(
                              fontSize: 11,
                              color: textColor.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (othersTyping.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 6),
              child: Row(
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Someone is typing…',
                    style: TextStyle(
                      color: Theme.of(context).textTheme.bodyMedium?.color,
                    ),
                  ),
                ],
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textCtrl,
                      minLines: 1,
                      maxLines: 4,
                      onChanged: _onChangedInput,
                      decoration: const InputDecoration(
                        hintText: 'Start typing…',
                        border: OutlineInputBorder(),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: _sendMessage,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
