// lib/features/profile/my_profile_store.dart
// Persistent, optimistic, offline-tolerant store for the signed-in user's profile.
// - SWR: serve cache instantly, refresh from Supabase in background
// - Optimistic updates: UI updates immediately; remote write queued if offline
// - Outbox: queued mutations retried on connectivity changes
// - Live sync: subscribes to profiles table via Postgrest .stream()
// - Sign-out cleanup: clears local cache and outbox on auth sign-out
// - Optional strict-online mode: revert optimistic change and throw when offline
//
// Deps: shared_preferences, connectivity_plus, flutter_riverpod, supabase_flutter

import 'dart:async' show StreamSubscription, unawaited;
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Uses *your* model & repo file (same folder as this store)
import 'profile_repository.dart' show UserProfile;

// Router helper so the router forgets stale completion state
import '../../routing/router.dart' show invalidateProfileStatusCache;

/// Local storage keys
const _kMyProfileKey = 'my_profile_v1_raw';
const _kMyProfileUpdatedAtKey = 'my_profile_updated_at';
const _kOutboxKey = 'my_profile_outbox_v1';

/// Error thrown when a write is requested with `requireOnline: true` but no connectivity.
class OfflineUpdateException implements Exception {
  const OfflineUpdateException([this.message = 'No internet connection']);
  final String message;
  @override
  String toString() => message;
}

/// Lightweight queued action for the outbox.
class _PendingAction {
  _PendingAction(this.type, this.payload, this.createdAt);
  final String type; // e.g. 'update_profile'
  final Map<String, dynamic> payload;
  final int createdAt; // epoch ms

  Map<String, dynamic> toJson() => {
        'type': type,
        'payload': payload,
        'createdAt': createdAt,
      };

  static _PendingAction fromJson(Map<String, dynamic> j) => _PendingAction(
        (j['type'] ?? '') as String,
        Map<String, dynamic>.from(j['payload'] as Map),
        (j['createdAt'] as num).toInt(),
      );
}

/// Read with:
///   final me = ref.watch(myProfileStoreProvider).valueOrNull;
/// Update optimistic:
///   await ref.read(myProfileStoreProvider.notifier).updateProfile({'name':'Alex'});
/// Require online write (reverts if offline):
///   await ref.read(myProfileStoreProvider.notifier).updateProfile({'name':'Alex'}, requireOnline: true);
/// Set photos:
///   await ref.read(myProfileStoreProvider.notifier).setPhotos(urls);
final myProfileStoreProvider =
    AsyncNotifierProvider<MyProfileStore, UserProfile?>(MyProfileStore.new);

class MyProfileStore extends AsyncNotifier<UserProfile?> {
  late final SupabaseClient _db;
  SharedPreferences? _prefs;

  // connectivity watcher (retry outbox)
  StreamSubscription<List<ConnectivityResult>>? _connSub;

  // auth watcher (sign-out cleanup)
  StreamSubscription<AuthState>? _authSub;

  // live sync from Postgrest stream
  StreamSubscription<List<Map<String, dynamic>>>? _profileStream;

  bool _bootstrapped = false;

  /// Last raw server map we have cached (kept in sync with disk).
  Map<String, dynamic>? _raw;

  @override
  Future<UserProfile?> build() async {
    _db = Supabase.instance.client;
    _prefs = await SharedPreferences.getInstance();

    // Warm start: serve cached immediately
    final cached = _readFromDisk();
    state = AsyncData(cached);

    // Start listeners once
    if (!_bootstrapped) {
      _bootstrapped = true;
      _startConnectivityListener();
      _startAuthListener();
      _startProfileStream();
    }

    // SWR refresh in background
    unawaited(_refreshFromServer());

    return cached;
  }

  // ----------------- Public API -----------------

  /// Force background refresh from server (keeps stale-while-revalidate UX).
  Future<void> refresh() => _refreshFromServer();

  /// Optimistic patch.
  ///
  /// If [requireOnline] is true and the action cannot be flushed immediately,
  /// the optimistic change is reverted and [OfflineUpdateException] is thrown.
  Future<void> updateProfile(
    Map<String, dynamic> patch, {
    bool requireOnline = false,
  }) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;

    final prevRaw = _raw == null ? null : Map<String, dynamic>.from(_raw!);

    // Apply locally (optimistic). Shallow merge is enough for our fields.
    final nextRaw = <String, dynamic>{...?_raw, ...patch};
    // LWW bump; server will assign real timestamp
    nextRaw['updated_at'] = DateTime.now().toUtc().toIso8601String();

    _writeRawToDisk(nextRaw);
    _raw = nextRaw;
    state = AsyncData(_userProfileFromMap(nextRaw));

    // Queue the remote update
    final action = _PendingAction('update_profile', patch, DateTime.now().millisecondsSinceEpoch);
    await _enqueue(action);

    // Try sending now
    await _flushOutbox();

    // Strict-online: if still pending, revert and error
    if (requireOnline && _outboxContains(action.createdAt)) {
      if (prevRaw == null) {
        _prefs?.remove(_kMyProfileKey);
        _prefs?.remove(_kMyProfileUpdatedAtKey);
        _raw = null;
        state = const AsyncData(null);
      } else {
        _writeRawToDisk(prevRaw);
        _raw = prevRaw;
        state = AsyncData(_userProfileFromMap(prevRaw));
      }
      throw const OfflineUpdateException();
    }

    // If they marked complete, nudge the router's cache now
    if ((patch['complete'] as bool?) == true) {
      invalidateProfileStatusCache();
    }
  }

  /// Replace photos list.
  ///
  /// Set [requireOnline] if you want the call to fail (and revert) when offline.
  Future<void> setPhotos(List<String> urls, {bool requireOnline = false}) =>
      updateProfile({'profile_pictures': urls}, requireOnline: requireOnline);

  /// Clears all locally stored profile state and queued actions.
  Future<void> clearLocal() async {
    _raw = null;
    state = const AsyncData(null);
    await _prefs?.remove(_kMyProfileKey);
    await _prefs?.remove(_kMyProfileUpdatedAtKey);
    await _prefs?.remove(_kOutboxKey);
  }

  // ----------------- Internals -----------------

  bool _outboxContains(int createdAt) => _readOutbox().any((e) => e.createdAt == createdAt);

  UserProfile? _readFromDisk() {
    final rawStr = _prefs?.getString(_kMyProfileKey);
    if (rawStr == null) return null;
    try {
      final map = jsonDecode(rawStr) as Map<String, dynamic>;
      _raw = map;
      return _userProfileFromMap(map);
    } catch (_) {
      return null;
    }
  }

  void _writeRawToDisk(Map<String, dynamic> raw) {
    _prefs?.setString(_kMyProfileKey, jsonEncode(raw));
    final updatedAt = (raw['updated_at'] ?? DateTime.now().toUtc().toIso8601String()).toString();
    _prefs?.setString(_kMyProfileUpdatedAtKey, updatedAt);
  }

  Future<void> _refreshFromServer() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;

    try {
      final row = await _db
          .from('profiles')
          .select() // no generic type args → analyzer-safe
          .eq('user_id', uid)
          .maybeSingle();

      if (row == null) return;

      final serverUpdated = DateTime.tryParse((row['updated_at'] as String?) ?? '');
      final localUpdated = DateTime.tryParse(_prefs?.getString(_kMyProfileUpdatedAtKey) ?? '');

      final acceptServer = serverUpdated == null ||
          localUpdated == null ||
          serverUpdated.isAfter(localUpdated);

      if (acceptServer) {
        final raw = Map<String, dynamic>.from(row);
        _writeRawToDisk(raw);
        _raw = raw;
        state = AsyncData(_userProfileFromMap(raw));
      }
    } catch (_) {
      // ignore network errors for SWR refresh
    }
  }

  void _startProfileStream() {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;

    _profileStream?.cancel();
    _profileStream = _db
        .from('profiles')
        .stream(primaryKey: ['user_id'])
        .eq('user_id', uid)
        .listen((rows) {
      if (rows.isEmpty) return;
      final row = rows.first;

      final serverUpdated = DateTime.tryParse((row['updated_at'] as String?) ?? '');
      final localUpdated = DateTime.tryParse(_prefs?.getString(_kMyProfileUpdatedAtKey) ?? '');

      final acceptServer = serverUpdated == null ||
          localUpdated == null ||
          serverUpdated.isAfter(localUpdated);

      if (acceptServer) {
        final raw = Map<String, dynamic>.from(row);
        _writeRawToDisk(raw);
        _raw = raw;
        state = AsyncData(_userProfileFromMap(raw));
      }
    });

    ref.onDispose(() => _profileStream?.cancel());
  }

  void _startConnectivityListener() {
    _connSub?.cancel();
    _connSub = Connectivity().onConnectivityChanged.listen((_) => _flushOutbox());
    ref.onDispose(() => _connSub?.cancel());
  }

  void _startAuthListener() {
    _authSub?.cancel();
    _authSub = _db.auth.onAuthStateChange.listen((s) async {
      final e = s.event;
      if (e == AuthChangeEvent.signedOut) {
        // Clear local data on sign-out.
        _profileStream?.cancel();
        _connSub?.cancel();
        await clearLocal();
      } else if (e == AuthChangeEvent.signedIn) {
        // New session → refresh and reattach stream.
        unawaited(_refreshFromServer());
        _startProfileStream();
      }
    });
    ref.onDispose(() => _authSub?.cancel());
  }

  Future<void> _enqueue(_PendingAction a) async {
    final out = _readOutbox();
    out.add(a);
    await _writeOutbox(out);
  }

  List<_PendingAction> _readOutbox() {
    final raw = _prefs?.getString(_kOutboxKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => _PendingAction.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeOutbox(List<_PendingAction> xs) async {
    final serialized = xs.map((e) => e.toJson()).toList();
    await _prefs?.setString(_kOutboxKey, jsonEncode(serialized));
  }

  Future<void> _flushOutbox() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;

    final queue = _readOutbox();
    if (queue.isEmpty) return;

    final nextQueue = <_PendingAction>[];
    var anyFlushed = false;

    for (final a in queue) {
      final ok = await _trySend(a, uid);
      if (!ok) {
        nextQueue.add(a);
      } else {
        anyFlushed = true;
      }
    }

    await _writeOutbox(nextQueue);

    if (anyFlushed) {
      // ensure local reflects server after successful flush
      await _refreshFromServer();
    }
  }

  Future<bool> _trySend(_PendingAction a, String uid) async {
    try {
      switch (a.type) {
        case 'update_profile':
          final patch = Map<String, dynamic>.from(a.payload);
          patch.remove('user_id'); // update with filter
          await _db.from('profiles').update(patch).eq('user_id', uid);

          if ((a.payload['complete'] as bool?) == true) {
            invalidateProfileStatusCache();
          }
          return true;

        default:
          return true; // unknown action → drop it
      }
    } catch (_) {
      return false; // keep in outbox
    }
  }

  // Adapt raw map to your model
  UserProfile? _userProfileFromMap(Map<String, dynamic> m) {
    try {
      return UserProfile.fromMap(m);
    } catch (_) {
      return null;
    }
  }
}
