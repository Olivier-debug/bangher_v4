// lib/services/presence_service.dart
/// Minimal presence service stub.
/// Replace with Supabase Realtime Presence (or your backend) when ready.
class PresenceService {
  PresenceService._();
  static final PresenceService instance = PresenceService._();

  final PresenceChannel _channel = PresenceChannel();

  /// Public accessor so UI/feature layers can call presence APIs.
  PresenceChannel channel() => _channel;
}

/// Public channel type to avoid private-type-in-public-API warnings.
class PresenceChannel {
  /// Track/announce current user's presence payload (no-op stub).
  Future<void> track(Map<String, dynamic> payload) async {
    // TODO: integrate with Supabase Realtime presence.
  }

  /// Return current presence state snapshot (no-op stub).
  List<PresenceRoomState> presenceState() => const <PresenceRoomState>[];
}

/// Public container for a room's presence state.
class PresenceRoomState {
  final List<Presence> presences;
  const PresenceRoomState(this.presences);
}

/// Public presence entry with arbitrary payload.
class Presence {
  final Map<String, dynamic> payload;
  const Presence(this.payload);
}
