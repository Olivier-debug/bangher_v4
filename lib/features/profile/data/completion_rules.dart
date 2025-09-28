// lib/features/profile/completion_rules.dart
// Pure completeness rules used by tests (and optional local checks).
// Matches server-side RPC: requires bio + love_language, >=1 language (my_languages),
// >=1 goal, >=3 interests, >=1 photo, valid prefs, and city OR GPS (location2).

enum StepId {
  nameGender,
  interestedIn,
  dob,
  city,
  about,
  interests,
  goals,
  languages,
  photosAndPrefs,
}

class ProfileCompletion {
  const ProfileCompletion({required this.complete, required this.missing});
  final bool complete;
  final Set<StepId> missing;
}

bool _isNonEmptyCity(String? city) {
  if (city == null) return false;
  final t = city.trim();
  if (t.isEmpty) return false;
  if (t.toLowerCase() == 'unknown') return false;
  return true;
}

bool _hasLocation2(dynamic v) {
  if (v is List && v.length == 2) {
    final a = v[0];
    final b = v[1];
    return (a is num) && (b is num);
  }
  return false;
}

/// Pure function – no IO. Keep in sync with the SQL RPC.
ProfileCompletion evaluateProfileCompletion({
  required Map<String, dynamic>? profile,
  required Map<String, dynamic>? prefs,
  DateTime? now,
}) {
  final missing = <StepId>{};
  final now0 = now ?? DateTime.now();

  String? str(dynamic v) => v is String ? v : v?.toString();
  List<String> strList(dynamic v) =>
      (v is List ? v.map((e) => e?.toString() ?? '').where((s) => s.isNotEmpty).toList() : const <String>[]);

  // name + gender (M/F/O)
  final name = str(profile?['name'])?.trim();
  final gender = str(profile?['gender'])?.toUpperCase();
  final genderOk = gender == 'M' || gender == 'F' || gender == 'O';
  if (name == null || name.isEmpty || !genderOk) missing.add(StepId.nameGender);

  // interested in (M/F/O)
  final interested = str(prefs?['interested_in_gender'])?.toUpperCase();
  final interestedOk = interested == 'M' || interested == 'F' || interested == 'O';
  if (!interestedOk) missing.add(StepId.interestedIn);

  // dob >= 18 (profiles.date_of_birth is DATE)
  final dobStr = str(profile?['date_of_birth']);
  DateTime? dob;
  if (dobStr != null && dobStr.isNotEmpty) {
    try {
      dob = DateTime.parse(dobStr);
    } catch (_) {
      dob = null;
    }
  }
  bool over18 = false;
  if (dob != null) {
    var years = now0.year - dob.year;
    final hadBirthday = (now0.month > dob.month) ||
        (now0.month == dob.month && now0.day >= dob.day);
    if (!hadBirthday) years -= 1;
    over18 = years >= 18;
  }
  if (!over18) missing.add(StepId.dob);

  // city OR GPS (location2 [lat, lon])
  final cityOk = _isNonEmptyCity(str(profile?['current_city'])) ||
      _hasLocation2(profile?['location2']);
  if (!cityOk) missing.add(StepId.city);

  // about: bio + love_language BOTH required
  final bio = str(profile?['bio'])?.trim();
  final love = str(profile?['love_language'])?.trim();
  if (bio == null || bio.isEmpty || love == null || love.isEmpty) {
    missing.add(StepId.about);
  }

  // interests >= 3
  if (strList(profile?['interests']).length < 3) {
    missing.add(StepId.interests);
  }

  // goals >= 1
  if (strList(profile?['relationship_goals']).isEmpty) {
    missing.add(StepId.goals);
  }

  // languages (my_languages) >= 1
  if (strList(profile?['my_languages']).isEmpty) {
    missing.add(StepId.languages);
  }

  // >=1 photo + prefs sanity (age_min/max/dist)
  final photos = strList(profile?['profile_pictures']);
  final aMin = (prefs?['age_min'] as int?) ?? 0;
  final aMax = (prefs?['age_max'] as int?) ?? 0;
  final dist = (prefs?['distance_radius'] as int?) ?? 0;
  final prefsOk = aMin >= 18 && aMax >= aMin && dist >= 1;
  if (photos.isEmpty || !prefsOk) {
    missing.add(StepId.photosAndPrefs);
  }

  return ProfileCompletion(complete: missing.isEmpty, missing: missing);
}
