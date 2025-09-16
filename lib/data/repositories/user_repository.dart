// FILE: lib/data/repositories/user_repository.dart
// Typed user repo (used by legacy code) now backed by the same schema.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:bangher/core/models/user_profile.dart' as models;
import 'package:bangher/core/config/profile_schema.dart' as cfg;

abstract class UserRepository {
  Future<models.UserProfile?> fetchById(String userId);
  Future<void> save(models.UserProfile user);
}

class SupabaseUserRepository implements UserRepository {
  SupabaseUserRepository(this._client, this._schema);

  final SupabaseClient _client;
  final cfg.ProfileSchema _schema;

  @override
  Future<models.UserProfile?> fetchById(String userId) async {
    final data = await _client
        .from(_schema.table)
        .select(_schema.selectRich())
        .eq(_schema.idCol, userId)
        .maybeSingle();

    if (data == null) return null;

    // Ensure strongly typed map for the model factory.
    final Map<String, dynamic> map = Map<String, dynamic>.from(data as Map);
    return models.UserProfile.fromMap(map, _schema);
  }

  @override
  Future<void> save(models.UserProfile user) async {
    await _client.from(_schema.table).upsert(
          user.toMap(_schema),
          onConflict: _schema.idCol, // e.g., 'user_id'
        );
  }
}

/// Simple in-memory fallback used by tests / previews.
class InMemoryUserRepository implements UserRepository {
  final _store = <String, models.UserProfile>{};

  @override
  Future<models.UserProfile?> fetchById(String userId) async => _store[userId];

  @override
  Future<void> save(models.UserProfile user) async {
    _store[user.id] = user;
  }
}

final userRepositoryProvider = Provider<UserRepository>((ref) {
  final client = Supabase.instance.client;

  // Use the shared default schema directly. No provider dependency here.
  const schema = cfg.defaultProfileSchema;

  return SupabaseUserRepository(client, schema);
});
