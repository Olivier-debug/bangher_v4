// -----------------------------------------------------------------------------
// file: lib/features/profile/my_profile_store.dart
// Persistent, optimistic, offline-tolerant store for the signed-in user's
// profile with pinned photo caching for full offline image display.
// - Hydrates cached JSON from SharedPreferences immediately
// - Streams server changes (Supabase) and reconciles by updated_at
// - Queues mutations in an outbox and flushes when online
// - Pins profile photos to disk for offline viewing
// - Cache persists across app restarts and is ONLY cleared on logout
// -----------------------------------------------------------------------------

import 'dart:async' show StreamSubscription, unawaited;
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'profile_repository.dart' show UserProfile;
import '../../routing/router.dart' show invalidateProfileStatusCache;
import '../../core/cache/pinned_image_cache.dart';

const _kMyProfileKey = 'my_profile_v1_raw';
const _kMyProfileUpdatedAtKey = 'my_profile_updated_at';
const _kOutboxKey = 'my_profile_outbox_v1';
const _kLastUidKey = 'my_profile_last_uid';

class OfflineUpdateException implements Exception {
  const OfflineUpdateException([this.message = 'No internet connection']);
  final String message;
  @override
  String toString() => message;
}

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

final myProfileStoreProvider =
    AsyncNotifierProvider<MyProfileStore, UserProfile?>(MyProfileStore.new);

class MyProfileStore extends AsyncNotifier<UserProfile?> {
  late final SupabaseClient _db;
  SharedPreferences? _prefs;

  // connectivity_plus v6 emits Stream<List<ConnectivityResult>>
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  StreamSubscription<AuthState>? _authSub;
  StreamSubscription<List<Map<String, dynamic>>>? _profileStream;

  bool _bootstrapped = false;
  Map<String, dynamic>? _raw;

  bool _refreshing = false;
  DateTime? _lastRefreshAt;
  static const Duration _refreshMinGap = Duration(seconds: 2);

  bool _flushing = false;
  DateTime? _lastFlushAt;
  static const Duration _flushMinGap = Duration(seconds: 2);

  @override
  Future<UserProfile?> build() async {
    _db = Supabase.instance.client;
    _prefs = await SharedPreferences.getInstance();

    final uid = _uid();
    final lastUid = _prefs?.getString(_kLastUidKey);

    // 1) Hydrate from disk ASAP so UI can render offline
    if (lastUid != null) {
      if (uid == null || uid == lastUid) {
        state = AsyncData(_readFromDisk());
      } else {
        await clearLocal();
        state = const AsyncData(null);
      }
    } else {
      state = const AsyncData(null);
    }

    // 2) One-time bootstrap of listeners/streams
    if (!_bootstrapped) {
      _bootstrapped = true;
      _startAuthListener();
      _startConnectivityListener();
      if (uid != null) {
        _startProfileStream();
        unawaited(_refreshFromServer());
        unawaited(_prefetchPhotosIfAny(uid));
      }
    }

    return state.valueOrNull;
  }

  // Public API ----------------------------------------------------------------

  Future<void> refresh() => _refreshFromServer();

  Future<void> updateProfile(
    Map<String, dynamic> patch, {
    bool requireOnline = false,
  }) async {
    final uid = _uid();
    if (uid == null) return;

    // Optimistic local write
    final prevRaw = _raw == null ? null : Map<String, dynamic>.from(_raw!);
    final nextRaw = <String, dynamic>{...?_raw, ...patch};
    nextRaw['updated_at'] = DateTime.now().toUtc().toIso8601String();

    await _writeRawToDisk(nextRaw, uid: uid);
    _raw = nextRaw;
    state = AsyncData(_userProfileFromMap(nextRaw));

    // Pin photos offline if changed
    if (patch.containsKey('profile_pictures')) {
      final urls = (patch['profile_pictures'] as List?)?.cast<String>() ?? const [];
      unawaited(PinnedImageCache.instance.prefetchAll(urls, uid: uid));
    }

    // Queue and try to flush
    final action =
        _PendingAction('update_profile', patch, DateTime.now().millisecondsSinceEpoch);
    await _enqueue(action);
    await _flushOutbox();

    // If a caller requires online, roll back the optimistic write when still queued
    if (requireOnline && _outboxContains(action.createdAt)) {
      if (prevRaw == null) {
        await _prefs?.remove(_kMyProfileKey);
        await _prefs?.remove(_kMyProfileUpdatedAtKey);
        _raw = null;
        state = const AsyncData(null);
      } else {
        await _writeRawToDisk(prevRaw, uid: uid);
        _raw = prevRaw;
        state = AsyncData(_userProfileFromMap(prevRaw));
      }
      await _removeFromOutbox(action.createdAt);
      throw const OfflineUpdateException();
    }

    if ((patch['complete'] as bool?) == true) {
      invalidateProfileStatusCache();
    }
  }

  Future<void> setPhotos(List<String> urls, {bool requireOnline = false}) =>
      updateProfile({'profile_pictures': urls}, requireOnline: requireOnline);

  /// Local file paths for current profile photos (if pinned).
  /// If [ensurePrefetch] is true, missing photos are downloaded.
  Future<List<String>> localPhotoPaths({bool ensurePrefetch = false}) async {
    final uid = _uid() ?? _prefs?.getString(_kLastUidKey);
    if (uid == null) return const [];
    final urls = ((_raw?['profile_pictures'] as List?)?.cast<String>()) ?? const [];
    if (urls.isEmpty) return const [];

    if (ensurePrefetch) {
      final m = await PinnedImageCache.instance.prefetchAll(urls, uid: uid);
      return urls.map((u) => m[u]).whereType<String>().toList(growable: false);
    } else {
      final m = await PinnedImageCache.instance.localPaths(urls, uid: uid);
      return urls.map((u) => m[u]).whereType<String>().toList(growable: false);
    }
  }

  /// Clears everything for the **last signed-in user**. Called on logout.
  Future<void> clearLocal() async {
    final lastUid = _prefs?.getString(_kLastUidKey);
    _raw = null;
    state = const AsyncData(null);
    await _prefs?.remove(_kMyProfileKey);
    await _prefs?.remove(_kMyProfileUpdatedAtKey);
    await _prefs?.remove(_kOutboxKey);
    await _prefs?.remove(_kLastUidKey);
    if (lastUid != null) {
      unawaited(PinnedImageCache.instance.clearForUser(lastUid));
    }
  }

  // Internals -----------------------------------------------------------------

  String? _uid() => _db.auth.currentUser?.id;

  bool _outboxContains(int createdAt) =>
      _readOutbox().any((e) => e.createdAt == createdAt);

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

  Future<void> _writeRawToDisk(Map<String, dynamic> raw, {String? uid}) async {
    await _prefs?.setString(_kMyProfileKey, jsonEncode(raw));
    final updatedAt =
        (raw['updated_at'] ?? DateTime.now().toUtc().toIso8601String()).toString();
    await _prefs?.setString(_kMyProfileUpdatedAtKey, updatedAt);
    if (uid != null) {
      await _prefs?.setString(_kLastUidKey, uid);
    }
  }

  Future<void> _refreshFromServer() async {
    final uid = _uid();
    if (uid == null) return;

    final now = DateTime.now();
    if (_refreshing) return;
    if (_lastRefreshAt != null && now.difference(_lastRefreshAt!) < _refreshMinGap) {
      return;
    }

    _refreshing = true;
    try {
      final row = await _db
          .from('profiles')
          .select()
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
        await _writeRawToDisk(raw, uid: uid);
        _raw = raw;
        state = AsyncData(_userProfileFromMap(raw));
        unawaited(_prefetchPhotosIfAny(uid));
      }
    } catch (_) {
      // swallow – UI should still show cached state
    } finally {
      _lastRefreshAt = DateTime.now();
      _refreshing = false;
    }
  }

  Future<void> _prefetchPhotosIfAny(String uid) async {
    final urls = ((_raw?['profile_pictures'] as List?)?.cast<String>()) ?? const [];
    if (urls.isEmpty) return;
    await PinnedImageCache.instance.prefetchAll(urls, uid: uid);
  }

  void _startProfileStream() {
    final uid = _uid();
    if (uid == null) return;

    _profileStream?.cancel();
    _profileStream = _db
        .from('profiles')
        .stream(primaryKey: ['user_id'])
        .eq('user_id', uid)
        .listen((rows) async {
      if (rows.isEmpty) return;
      final row = rows.first;

      final serverUpdated = DateTime.tryParse((row['updated_at'] as String?) ?? '');
      final localUpdated = DateTime.tryParse(_prefs?.getString(_kMyProfileUpdatedAtKey) ?? '');

      final acceptServer = serverUpdated == null ||
          localUpdated == null ||
          serverUpdated.isAfter(localUpdated);

      if (acceptServer) {
        final raw = Map<String, dynamic>.from(row);
        await _writeRawToDisk(raw, uid: uid);
        _raw = raw;
        state = AsyncData(_userProfileFromMap(raw));
        unawaited(_prefetchPhotosIfAny(uid));
      }
    });

    ref.onDispose(() => _profileStream?.cancel());
  }

  void _stopProfileStream() {
    _profileStream?.cancel();
    _profileStream = null;
  }

  void _startConnectivityListener() {
    _connSub?.cancel();
    _connSub = Connectivity().onConnectivityChanged.listen((_) async {
      final uid = _uid();
      if (uid == null) return;
      await _flushOutbox();
    });
    ref.onDispose(() => _connSub?.cancel());
  }

  void _startAuthListener() {
    _authSub?.cancel();
    _authSub = _db.auth.onAuthStateChange.listen((s) async {
      final e = s.event;
      if (e == AuthChangeEvent.signedOut) {
        _stopProfileStream();
        await clearLocal();
      } else if (e == AuthChangeEvent.signedIn) {
        final uid = _uid();
        final lastUid = _prefs?.getString(_kLastUidKey);
        if (uid != null && lastUid != uid) {
          await clearLocal();
        }
        _startProfileStream();
        unawaited(_refreshFromServer());
        unawaited(_flushOutbox());
      }
    });
    ref.onDispose(() => _authSub?.cancel());
  }

  Future<void> _enqueue(_PendingAction a) async {
    final out = _readOutbox()..add(a);
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

  Future<void> _removeFromOutbox(int createdAt) async {
    final xs = _readOutbox()..removeWhere((e) => e.createdAt == createdAt);
    await _writeOutbox(xs);
  }

  Future<void> _flushOutbox() async {
    final uid = _uid();
    if (uid == null) return;

    final now = DateTime.now();
    if (_flushing) return;
    if (_lastFlushAt != null && now.difference(_lastFlushAt!) < _flushMinGap) {
      return;
    }

    final queue = _readOutbox();
    if (queue.isEmpty) return;

    _flushing = true;
    try {
      final nextQueue = <_PendingAction>[];
      var anyFlushed = false;

      for (final a in queue) {
        final ok = await _trySend(a, uid);
        if (ok) {
          anyFlushed = true;
        } else {
          nextQueue.add(a);
        }
      }

      await _writeOutbox(nextQueue);

      if (anyFlushed) {
        await _refreshFromServer();
      }
    } finally {
      _lastFlushAt = DateTime.now();
      _flushing = false;
    }
  }

  Future<bool> _trySend(_PendingAction a, String uid) async {
    try {
      switch (a.type) {
        case 'update_profile':
          final patch = Map<String, dynamic>.from(a.payload)..remove('user_id');
          await _db.from('profiles').update(patch).eq('user_id', uid);
          if ((a.payload['complete'] as bool?) == true) {
            invalidateProfileStatusCache();
          }
          return true;
        default:
          // Unknown actions are considered flushed to avoid blocking
          return true;
      }
    } catch (_) {
      return false;
    }
  }

  UserProfile? _userProfileFromMap(Map<String, dynamic> m) {
    try {
      return UserProfile.fromMap(m);
    } catch (_) {
      return null;
    }
  }
}
