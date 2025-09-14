// FILE: lib/features/profile/providers.dart
// Public provider aliases + tiny helpers so UI can depend on a stable name.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'my_profile_store.dart';
import 'preferences_store.dart';

/// Keep UI imports stable: `ref.watch(myProfileProvider)`
final myProfileProvider = myProfileStoreProvider;
final myPreferencesProvider = myPreferencesStoreProvider;

extension MyStoresX on WidgetRef {
  // Profile
  Future<void> refreshProfile() => read(myProfileStoreProvider.notifier).refresh();
  Future<void> updateProfile(Map<String, dynamic> patch, {bool requireOnline = false})
    => read(myProfileStoreProvider.notifier).updateProfile(patch, requireOnline: requireOnline);
  Future<void> setPhotos(List<String> urls, {bool requireOnline = false})
    => read(myProfileStoreProvider.notifier).setPhotos(urls, requireOnline: requireOnline);

  // Preferences
  Future<void> refreshPreferences() => read(myPreferencesStoreProvider.notifier).refresh();
  Future<void> updatePreferences(Map<String, dynamic> patch)
    => read(myPreferencesStoreProvider.notifier).updatePreferences(patch);
}
