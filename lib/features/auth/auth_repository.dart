// FILE: lib/features/auth/auth_repository.dart
// Purpose: Single, passive auth accessors. No manual refresh/polling.

import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(Supabase.instance.client);
});

/// Emits a Session every time Supabase auth state changes.
/// Do NOT call getSession/refreshSession in widgets; just listen to this.
final authSessionStreamProvider = StreamProvider<Session?>((ref) {
  final repo = ref.watch(authRepositoryProvider);
  return repo.sessionStream;
});

class AuthRepository {
  AuthRepository(this._client);
  final SupabaseClient _client;

  Stream<Session?> get sessionStream =>
      _client.auth.onAuthStateChange.map((e) => e.session);

  Session? get currentSession => _client.auth.currentSession;
  User? get currentUser => _client.auth.currentUser;

  Future<void> signOut() => _client.auth.signOut();

  Future<void> signInWithGoogle() async {
    final redirectTo = kIsWeb ? null : _defaultRedirectUrl();
    await _client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: redirectTo,
      queryParams: const {'prompt': 'select_account'},
    );
  }

  Future<void> signInWithApple() async {
    final redirectTo = kIsWeb ? null : _defaultRedirectUrl();
    await _client.auth.signInWithOAuth(
      OAuthProvider.apple,
      redirectTo: redirectTo,
    );
  }

  String _defaultRedirectUrl() {
    if (Platform.isAndroid) return 'io.supabase.flutter://login-callback/';
    if (Platform.isIOS) return 'io.supabase.flutter://login-callback/';
    return 'io.supabase.flutter://login-callback/';
  }
}
