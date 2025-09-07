
import '../config/profile_schema.dart';

class UserProfile {
  // --- Canonical fields (match DB columns) ---
  final String userId;                 // profiles.user_id
  final String? name;                  // profiles.name
  final String? bio;                   // profiles.bio
  final String? gender;                // profiles.gender (M/F/O or label)
  final String? currentCity;           // profiles.current_city
  final DateTime? dateOfBirth;         // profiles.date_of_birth (DATE)
  final int? age;                      // profiles.age (nullable; computed if absent)
  final List<String> profilePictures;  // profiles.profile_pictures (text[])
  final List<String> interests;        // profiles.interests (text[])
  final List<String> relationshipGoals;// profiles.relationship_goals (text[])
  final List<String> languages;        // profiles.my_languages (text[])
  final String? loveLanguage;          // profiles.love_language (optional)
  final String? education;             // optional/extra if present
  final String? communicationStyle;    // optional/extra if present
  final String? drinking;              // optional/extra if present
  final String? smoking;               // optional/extra if present
  final String? pets;                  // optional/extra if present
  final List<num>? location2;          // profiles.location2 (numeric[] [lat,lng])

  const UserProfile({
    required this.userId,
    this.name,
    this.bio,
    this.gender,
    this.currentCity,
    this.dateOfBirth,
    this.age,
    this.profilePictures = const <String>[],
    this.interests = const <String>[],
    this.relationshipGoals = const <String>[],
    this.languages = const <String>[],
    this.loveLanguage,
    this.education,
    this.communicationStyle,
    this.drinking,
    this.smoking,
    this.pets,
    this.location2,
  });

  // ---------- Derived ----------
  /// Prefer first photo; no avatar_url column exists in your schema.
  String? get avatarUrl =>
      profilePictures.isNotEmpty ? profilePictures.first : null;

  /// Simple 0..1 completion used by UI rings (parity with Create flow).
  double get completion {
    int satisfied = 0;
    const total = 9;
    final hasName = (name ?? '').trim().isNotEmpty;
    final hasGender = (gender ?? '').trim().isNotEmpty;
    final dobOk = (dateOfBirth != null) && (_computeAge(dateOfBirth) >= 18);
    final hasPhoto = profilePictures.isNotEmpty;
    final hasCityOrLoc =
        (currentCity ?? '').trim().isNotEmpty || (location2 != null);
    final bioGood = (bio ?? '').trim().length >= 20;
    final interestsOk = interests.length >= 3;
    final languagesOk = languages.isNotEmpty;
    final goalsOk = relationshipGoals.isNotEmpty;

    if (hasName) satisfied++;
    if (hasGender) satisfied++;
    if (dobOk) satisfied++;
    if (hasPhoto) satisfied++;
    if (hasCityOrLoc) satisfied++;
    if (bioGood) satisfied++;
    if (interestsOk) satisfied++;
    if (languagesOk) satisfied++;
    if (goalsOk) satisfied++;

    return satisfied / total;
  }

  /// Gate-keeper used by `UserProfileGate`.
  bool isCompleteWith(ProfileSchema s) {
    final hasName = (name ?? '').trim().isNotEmpty;
    final dobOk = (dateOfBirth != null) && (_computeAge(dateOfBirth) >= 18);
    final ageOk = (age ?? 0) >= 18;

    bool ok(String key) {
      switch (key) {
        case 'name':
          return hasName;
        case 'date_of_birth':
          return dobOk;
        case 'age':
          return ageOk;
        case 'bio':
          return (bio ?? '').trim().isNotEmpty;
        case 'current_city':
          return (currentCity ?? '').trim().isNotEmpty;
        case 'profile_pictures':
          return profilePictures.isNotEmpty;
        default:
          return true;
      }
    }

    return s.required.every(ok);
  }

  // ---------- Mapping ----------
  factory UserProfile.fromMap(Map<String, dynamic> m, ProfileSchema s) {
    final pics = _asStringList(m[s.photosCol] ?? m['profile_pictures']);
    final dob = _parseDate(m[s.dobCol] ?? m['date_of_birth']);
    final rawAge = m[s.ageCol];
    final computedAge = rawAge is num && rawAge > 0 ? rawAge.toInt() : _computeAge(dob);

    return UserProfile(
      userId: _asString(m[s.idCol] ?? m['user_id']),
      name: _asStringN(m[s.displayNameCol] ?? m['name']),
      bio: _asStringN(m[s.bioCol] ?? m['bio']),
      gender: _asStringN(m[s.genderCol] ?? m['gender']),
      currentCity: _asStringN(m[s.cityCol] ?? m['current_city']),
      dateOfBirth: dob,
      age: computedAge == 0 ? null : computedAge,
      profilePictures: pics,
      interests: _asStringList(m[s.interestsCol] ?? m['interests']),
      relationshipGoals: _asStringList(m[s.goalsCol] ?? m['relationship_goals']),
      languages: _asStringList(m[s.languagesCol] ?? m['my_languages']),
      loveLanguage: _asStringN(m['love_language']),
      education: _asStringN(m['education']),
      communicationStyle: _asStringN(m['communication_style']),
      drinking: _asStringN(m['drinking']),
      smoking: _asStringN(m['smoking']),
      pets: _asStringN(m['pets']),
      location2: _asNumList(m[s.location2Col] ?? m['location2']),
    );
  }

  Map<String, dynamic> toMap(ProfileSchema s) {
    final map = <String, dynamic>{
      s.idCol: userId,
      s.displayNameCol: name,
      s.bioCol: bio,
      s.cityCol: currentCity,
      if (s.photosCol != null) s.photosCol!: profilePictures,
      if (s.ageCol != null && age != null) s.ageCol!: age,
      if (s.languagesCol != null) s.languagesCol!: languages,
      if (s.interestsCol != null) s.interestsCol!: interests,
      if (s.goalsCol != null) s.goalsCol!: relationshipGoals,
      if (s.genderCol != null) s.genderCol!: gender,
      if (s.location2Col != null && location2 != null) s.location2Col!: location2,
      if (dateOfBirth != null)
        (s.dobCol ?? 'date_of_birth'): _yyyyMmDd(dateOfBirth!),
      if (loveLanguage != null) 'love_language': loveLanguage,
      if (education != null) 'education': education,
      if (communicationStyle != null) 'communication_style': communicationStyle,
      if (drinking != null) 'drinking': drinking,
      if (smoking != null) 'smoking': smoking,
      if (pets != null) 'pets': pets,
    };

    // Never write a non-existent avatar_url
    // (avatar derived from first profile picture)

    return map;
  }

  UserProfile copyWith({
    String? userId,
    String? name,
    String? bio,
    String? gender,
    String? currentCity,
    DateTime? dateOfBirth,
    int? age,
    List<String>? profilePictures,
    List<String>? interests,
    List<String>? relationshipGoals,
    List<String>? languages,
    String? loveLanguage,
    String? education,
    String? communicationStyle,
    String? drinking,
    String? smoking,
    String? pets,
    List<num>? location2,
  }) {
    return UserProfile(
      userId: userId ?? this.userId,
      name: name ?? this.name,
      bio: bio ?? this.bio,
      gender: gender ?? this.gender,
      currentCity: currentCity ?? this.currentCity,
      dateOfBirth: dateOfBirth ?? this.dateOfBirth,
      age: age ?? this.age,
      profilePictures: profilePictures ?? this.profilePictures,
      interests: interests ?? this.interests,
      relationshipGoals: relationshipGoals ?? this.relationshipGoals,
      languages: languages ?? this.languages,
      loveLanguage: loveLanguage ?? this.loveLanguage,
      education: education ?? this.education,
      communicationStyle: communicationStyle ?? this.communicationStyle,
      drinking: drinking ?? this.drinking,
      smoking: smoking ?? this.smoking,
      pets: pets ?? this.pets,
      location2: location2 ?? this.location2,
    );
  }

  // ---------- Back-compat aliases (legacy code safety) ----------
  String get id => userId;                         // legacy
  String? get displayName => name;                 // legacy
  String? get city => currentCity;                 // legacy
  List<String> get photos => profilePictures;      // legacy
}

// ===== helpers =====
String _asString(dynamic v) => v?.toString() ?? '';
String? _asStringN(dynamic v) => v?.toString();

List<String> _asStringList(dynamic v) {
  if (v is List) return v.map((e) => e.toString()).toList();
  return const <String>[];
}

List<num>? _asNumList(dynamic v) {
  if (v is List) {
    final out = <num>[];
    for (final e in v) {
      if (e is num) out.add(e);
      if (e is String) {
        final n = num.tryParse(e);
        if (n != null) out.add(n);
      }
    }
    return out;
  }
  return null;
}

DateTime? _parseDate(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
  return null;
}

int _computeAge(DateTime? dob) {
  if (dob == null) return 0;
  final now = DateTime.now();
  var years = now.year - dob.year;
  final hadBirthday =
      now.month > dob.month || (now.month == dob.month && now.day >= dob.day);
  if (!hadBirthday) years -= 1;
  return years;
}

String _yyyyMmDd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
