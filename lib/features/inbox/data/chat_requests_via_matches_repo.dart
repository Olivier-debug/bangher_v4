// FILE: lib/features/inbox/data/chat_requests_via_matches_repo.dart
import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';

class RequestItem {
  RequestItem({
    required this.matchId,
    required this.senderId,
    required this.receiverId,
    required this.firstMessage,
    required this.firstMessageAt,
  });

  final int matchId;
  final String senderId;
  final String receiverId;
  final String firstMessage;
  final DateTime firstMessageAt;
}

class ChatRequestsViaMatchesRepo {
  ChatRequestsViaMatchesRepo({SupabaseClient? client})
      : _c = client ?? Supabase.instance.client;

  final SupabaseClient _c;

  Stream<List<RequestItem>> streamInboundRequests() async* {
    final me = _c.auth.currentUser?.id;
    if (me == null) {
      yield const <RequestItem>[];
      return;
    }

    // NOTE: stream() → filter in Dart (compatible with older SDKs)
    final matchesStream =
        _c.from('matches').stream(primaryKey: ['id']); // no .eq/.contains here

    await for (final allRows in matchesStream) {
      // 1) Filter to (a) I'm a participant, (b) status == 'request'
      final rows = allRows.where((r) {
        final st = (r['status'] ?? 'active').toString();
        final users =
            ((r['user_ids'] as List?) ?? const []).map((e) => e.toString());
        return st == 'request' && users.contains(me);
      }).toList();

      if (rows.isEmpty) {
        yield const <RequestItem>[];
        continue;
      }

      // Order by updated_at asc (oldest first)
      rows.sort((a, b) {
        final atA = DateTime.tryParse('${a['updated_at']}') ?? DateTime.now();
        final atB = DateTime.tryParse('${b['updated_at']}') ?? DateTime.now();
        return atA.compareTo(atB);
      });

      // 2) Fetch earliest message per chat (the request text)
      final ids = <int>[];
      final matchUsers = <int, List<String>>{};
      for (final r in rows) {
        final id = (r['id'] as num).toInt();
        final users = ((r['user_ids'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList();
        ids.add(id);
        matchUsers[id] = users;
      }

      final msgRows = ids.isEmpty
          ? const <Map<String, dynamic>>[]
          : (await _c
                  .from('messages')
                  .select('chat_id, sender_id, message, created_at')
                  .inFilter('chat_id', ids)
                  .order('created_at', ascending: true))
              .cast<Map<String, dynamic>>();

      final firstByChat = <int, Map<String, dynamic>>{};
      for (final m in msgRows) {
        final cid = (m['chat_id'] as num?)?.toInt();
        if (cid == null) continue;
        firstByChat.putIfAbsent(cid, () => m); // first = earliest
      }

      final items = <RequestItem>[];
      for (final id in ids) {
        final first = firstByChat[id];
        final users = matchUsers[id] ?? const <String>[];
        if (first == null || users.length != 2) continue;

        final sender = first['sender_id']?.toString() ?? '';
        if (sender.isEmpty || sender == me) continue; // inbound only

        final other = users.firstWhere((u) => u != sender, orElse: () => '');
        if (other.isEmpty) continue;

        final createdAt =
            _parseUtc(first['created_at']) ?? DateTime.now().toUtc();
        final text = (first['message'] ?? '').toString();

        items.add(RequestItem(
          matchId: id,
          senderId: sender,
          receiverId: other,
          firstMessage: text,
          firstMessageAt: createdAt,
        ));
      }

      yield items;
    }
  }

  Future<int> sendRequest({
    required String toUserId,
    required String message,
  }) async {
    final me = _c.auth.currentUser?.id;
    if (me == null) throw StateError('Not signed in');
    final text = message.trim();
    if (text.isEmpty) throw ArgumentError('Message required');

    final existing = await _c
        .from('matches')
        .select('id, user_ids, status')
        .contains('user_ids', [me, toUserId])
        .order('updated_at', ascending: false)
        .maybeSingle();

    int matchId;
    if (existing != null &&
        (existing['status'] == 'request' || existing['status'] == 'active')) {
      matchId = (existing['id'] as num).toInt();
    } else {
      final insert = await _c
          .from('matches')
          .insert({
            'user_ids': [me, toUserId],
            'status': 'request',
            'initiator_id': me,
          })
          .select('id')
          .single();
      matchId = (insert['id'] as num).toInt();
    }

    await _c.from('messages').insert({
      'chat_id': matchId,
      'sender_id': me,
      'message': text,
    });

    return matchId;
  }

  Future<int?> accept(int matchId) async {
    final me = _c.auth.currentUser?.id;
    if (me == null) return null;

    final m = await _c
        .from('matches')
        .select('id, user_ids, status')
        .eq('id', matchId)
        .maybeSingle();
    if (m == null) return null;

    final users =
        ((m['user_ids'] as List?) ?? const []).map((e) => '$e').toList();
    if (!users.contains(me)) return null;

    if (m['status'] == 'active') return (m['id'] as num).toInt();

    await _c.from('matches').update({'status': 'active'}).eq('id', matchId);
    return matchId;
  }

  Future<void> decline(int matchId) async {
    final me = _c.auth.currentUser?.id;
    if (me == null) return;

    final m = await _c
        .from('matches')
        .select('id, user_ids, status')
        .eq('id', matchId)
        .maybeSingle();
    if (m == null) return;

    final users =
        ((m['user_ids'] as List?) ?? const []).map((e) => '$e').toList();
    if (!users.contains(me)) return;

    await _c.from('matches').update({'status': 'rejected'}).eq('id', matchId);
  }

  DateTime? _parseUtc(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v.toUtc();
    try {
      return DateTime.parse(v.toString()).toUtc();
    } catch (_) {
      return null;
    }
  }
}
