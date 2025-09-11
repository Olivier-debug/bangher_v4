
// -----------------------------------------------------------------------------
// file: lib/features/profile/preferences_store.dart
// Offline-first, optimistic store for the signed-in user's match preferences.
// Hydration-safe (serves last UID cache on cold start), clears only on sign-out
// or when a different user signs in. Server-wins on stream updates.

import 'dart:async' show StreamSubscription, unawaited;
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _kMyPrefsKey = 'my_prefs_v1_raw';
const _kMyPrefsUpdatedAtKey = 'my_prefs_updated_at';
const _kOutboxPrefsKey = 'my_prefs_outbox_v1';
const _kPrefsLastUidKey = 'my_prefs_last_uid';

class UserPreferences {
  final String? interestedInGender; // 'M' | 'F' | 'O' | null
  final int ageMin;
  final int ageMax;
  final int distanceRadius;

  const UserPreferences({
    required this.interestedInGender,
    required this.ageMin,
    required this.ageMax,
    required this.distanceRadius,
  });

  factory UserPreferences.fromMap(Map<String, dynamic> m) {
    return UserPreferences(
      interestedInGender: (m['interested_in_gender'] as String?)?.trim(),
      ageMin: (m['age_min'] as num?)?.toInt() ?? 18,
      ageMax: (m['age_max'] as num?)?.toInt() ?? 100,
      distanceRadius: (m['distance_radius'] as num?)?.toInt() ?? 50,
    );
  }

  Map<String, dynamic> toMap({required String userId}) => {
        'user_id': userId,
        'interested_in_gender': interestedInGender,
        'age_min': ageMin,
        'age_max': ageMax,
        'distance_radius': distanceRadius,
      };
}

class _PendingAction {
  _PendingAction(this.type, this.payload, this.createdAt);
  final String type; // 'update_prefs'
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

final myPreferencesStoreProvider =
    AsyncNotifierProvider<MyPreferencesStore, UserPreferences?>(
        MyPreferencesStore.new);

class MyPreferencesStore extends AsyncNotifier<UserPreferences?> {
  late final SupabaseClient _db;
  SharedPreferences? _prefs;

  StreamSubscription<List<ConnectivityResult>>? _connSub;
  StreamSubscription<AuthState>? _authSub;
  StreamSubscription<List<Map<String, dynamic>>>? _prefsStream;

  bool _bootstrapped = false;
  Map<String, dynamic>? _raw;

  bool _refreshing = false;
  DateTime? _lastRefreshAt;
  static const Duration _refreshMinGap = Duration(seconds: 2);

  bool _flushing = false;
  DateTime? _lastFlushAt;
  static const Duration _flushMinGap = Duration(seconds: 2);

  @override
  Future<UserPreferences?> build() async {
    _db = Supabase.instance.client;
    _prefs = await SharedPreferences.getInstance();

    final uid = _uid();
    final lastUid = _prefs?.getString(_kPrefsLastUidKey);

    if (lastUid != null) {
      if (uid == null || uid == lastUid) {
        final cached = _readFromDisk();
        state = AsyncData(cached);
      } else {
        await _clearLocal();
        state = const AsyncData(null);
      }
    } else {
      state = const AsyncData(null);
    }

    if (!_bootstrapped) {
      _bootstrapped = true;
      _startAuthListener();
      _startConnectivityListener();
      if (uid != null) {
        _startPrefsStream();
        unawaited(_refreshFromServer());
      }
    }

    return state.valueOrNull;
  }

  Future<void> refresh() => _refreshFromServer();

  Future<void> updatePreferences(Map<String, dynamic> patch) async {
    final uid = _uid();
    if (uid == null) return;

    final nextRaw = <String, dynamic>{...?_raw, ...patch};
    nextRaw['updated_at'] = DateTime.now().toUtc().toIso8601String();

    await _writeRawToDisk(nextRaw, uid: uid);
    _raw = nextRaw;
    state = AsyncData(_fromRaw(nextRaw));

    await _enqueue(
        _PendingAction('update_prefs', patch, DateTime.now().millisecondsSinceEpoch));
    await _flushOutbox();
  }

  // Internals ----------------------------------------------------------------

  String? _uid() => _db.auth.currentUser?.id;

  UserPreferences? _readFromDisk() {
    final rawStr = _prefs?.getString(_kMyPrefsKey);
    if (rawStr == null) return null;
    try {
      final map = jsonDecode(rawStr) as Map<String, dynamic>;
      _raw = map;
      return _fromRaw(map);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeRawToDisk(Map<String, dynamic> raw, {required String uid}) async {
    await _prefs?.setString(_kMyPrefsKey, jsonEncode(raw));
    final updatedAt =
        (raw['updated_at'] ?? DateTime.now().toUtc().toIso8601String()).toString();
    await _prefs?.setString(_kMyPrefsUpdatedAtKey, updatedAt);
    await _prefs?.setString(_kPrefsLastUidKey, uid);
  }

  UserPreferences? _fromRaw(Map<String, dynamic> m) {
    try { return UserPreferences.fromMap(m); } catch (_) { return null; }
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
          .from('preferences')
          .select()
          .eq('user_id', uid)
          .maybeSingle();
      if (row == null) return;

      final serverUpdated =
          DateTime.tryParse((row['updated_at'] as String?) ?? '');
      final localUpdated =
          DateTime.tryParse(_prefs?.getString(_kMyPrefsUpdatedAtKey) ?? '');
      final acceptServer = serverUpdated == null ||
          localUpdated == null ||
          serverUpdated.isAfter(localUpdated);

      if (acceptServer) {
        final raw = Map<String, dynamic>.from(row);
        await _writeRawToDisk(raw, uid: uid);
        _raw = raw;
        state = AsyncData(_fromRaw(raw));
      }
    } catch (_) {
      // ignore
    } finally {
      _lastRefreshAt = DateTime.now();
      _refreshing = false;
    }
  }

  void _startPrefsStream() {
    final uid = _uid();
    if (uid == null) return;

    _prefsStream?.cancel();
    _prefsStream = _db
        .from('preferences')
        .stream(primaryKey: ['user_id'])
        .eq('user_id', uid)
        .listen((rows) async {
      if (rows.isEmpty) return;
      final row = rows.first;

      // Server-wins: always mirror backend on live updates
      final raw = Map<String, dynamic>.from(row);
      await _writeRawToDisk(raw, uid: uid);
      _raw = raw;
      state = AsyncData(_fromRaw(raw));
    });

    ref.onDispose(() => _prefsStream?.cancel());
  }

  void _stopPrefsStream() {
    _prefsStream?.cancel();
    _prefsStream = null;
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
        _stopPrefsStream();
        await _clearLocal();
      } else if (e == AuthChangeEvent.signedIn) {
        final uid = _uid();
        final lastUid = _prefs?.getString(_kPrefsLastUidKey);
        if (uid != null && lastUid != uid) {
          await _clearLocal();
        }
        _startPrefsStream();
        unawaited(_refreshFromServer());
        unawaited(_flushOutbox());
      }
    });
    ref.onDispose(() => _authSub?.cancel());
  }

  Future<void> _clearLocal() async {
    state = const AsyncData(null);
    _raw = null;
    await _prefs?.remove(_kMyPrefsKey);
    await _prefs?.remove(_kMyPrefsUpdatedAtKey);
    await _prefs?.remove(_kOutboxPrefsKey);
    await _prefs?.remove(_kPrefsLastUidKey);
  }

  Future<void> _enqueue(_PendingAction a) async {
    final out = _readOutbox();
    out.add(a);
    await _writeOutbox(out);
  }

  List<_PendingAction> _readOutbox() {
    final raw = _prefs?.getString(_kOutboxPrefsKey);
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
    await _prefs?.setString(_kOutboxPrefsKey, jsonEncode(serialized));
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
        if (!ok) {
          nextQueue.add(a);
        } else {
          anyFlushed = true;
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
        case 'update_prefs':
          final patch = Map<String, dynamic>.from(a.payload);
          patch['user_id'] = uid; // allow insert path

          final updated = await _db
              .from('preferences')
              .update(patch)
              .eq('user_id', uid)
              .select('user_id');

          if (updated.isEmpty) {
            try {
              await _db.from('preferences').insert(patch);
            } on PostgrestException catch (e) {
              if (e.code != '23505') rethrow;
            }
          }
          return true;

        default:
          return true;
      }
    } catch (_) {
      return false;
    }
  }
}
