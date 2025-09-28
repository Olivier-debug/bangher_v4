// lib/services/presence_service.dart
class PresenceService {
  PresenceService._();
  static final PresenceService instance = PresenceService._();

  final _PresenceChannel _channel = _PresenceChannel();

  _PresenceChannel channel() => _channel;
}

class _PresenceChannel {
  Future<void> track(Map<String, dynamic> payload) async {
    // no-op stub; replace with Supabase Realtime presence as needed
  }

  List<_PresenceRoomState> presenceState() => const <_PresenceRoomState>[];
}

class _PresenceRoomState {
  final List<_Presence> presences;
  const _PresenceRoomState(this.presences);
}

class _Presence {
  final Map<String, dynamic> payload;
  const _Presence(this.payload);
}
