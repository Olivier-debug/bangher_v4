import 'package:supabase_flutter/supabase_flutter.dart';

class PresenceService {
  PresenceService._();
  static final PresenceService instance = PresenceService._();

  RealtimeChannel? _ch;

  RealtimeChannel channel() {
    _ch ??= Supabase.instance.client.channel(
      'Online',
      opts: const RealtimeChannelConfig(self: true),
    )..subscribe();
    return _ch!;
  }

  void dispose() {
    _ch?.unsubscribe();
    _ch = null;
  }
}
