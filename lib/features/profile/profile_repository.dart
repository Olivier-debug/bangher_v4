// FILE: lib/features/profile/profile_repository.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return ProfileRepository(Supabase.instance.client);
});

final myProfileProvider = FutureProvider<UserProfile?>((ref) async {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) return null;
  return ref.read(profileRepositoryProvider).fetchByUserId(user.id);
});

class UserProfile {
  final String userId;
  final String? name;
  final String? gender;
  final String? currentCity;
  final String? bio;
  final DateTime? dateOfBirth;
  final List<String> profilePictures;
  final List<String> interests;
  final List<String> relationshipGoals;
  final List<String> languages;
  final String? familyPlans;
  final String? loveLanguage;
  final String? education;
  final String? communicationStyle;
  final String? drinking;
  final String? smoking;
  final String? pets;

  // ---- NEW OPTIONAL FIELDS (non-breaking) ----
  final int? heightCm;
  final String? zodiacSign;
  final String? workout;
  final String? dietaryPreference;
  final String? sleepingHabits;
  final String? sexualOrientation;
  final String? socialMedia;
  final String? personalityType;
  final List<num>? location2; // numeric[] (optional)

  const UserProfile({
    required this.userId,
    required this.name,
    required this.gender,
    required this.currentCity,
    required this.bio,
    required this.dateOfBirth,
    required this.profilePictures,
    required this.interests,
    required this.relationshipGoals,
    required this.languages,
    required this.familyPlans,
    required this.loveLanguage,
    required this.education,
    required this.communicationStyle,
    required this.drinking,
    required this.smoking,
    required this.pets,

    // NEW
    this.heightCm,
    this.zodiacSign,
    this.workout,
    this.dietaryPreference,
    this.sleepingHabits,
    this.sexualOrientation,
    this.socialMedia,
    this.personalityType,
    this.location2,
  });

  int? get age {
    if (dateOfBirth == null) return null;
    final now = DateTime.now();
    var years = now.year - dateOfBirth!.year;
    final hadBirthday = (now.month > dateOfBirth!.month) ||
        (now.month == dateOfBirth!.month && now.day >= dateOfBirth!.day);
    if (!hadBirthday) years -= 1;
    return years;
  }

  /// Simple, user-facing completion measure (kept exactly as before).
  double get completion {
    final checks = <bool>[
      (name?.trim().isNotEmpty ?? false),
      (bio?.trim().isNotEmpty ?? false),
      (age != null && age! >= 18),
      profilePictures.isNotEmpty,
      interests.length >= 3,
      languages.isNotEmpty,
      (currentCity?.trim().isNotEmpty ?? false),
      (education?.trim().isNotEmpty ?? false),
    ];
    final score = checks.where((c) => c).length;
    return score / checks.length;
  }

  factory UserProfile.fromMap(Map<String, dynamic> m) {
    DateTime? dob;
    final rawDob = m['date_of_birth'];
    if (rawDob != null) {
      if (rawDob is String) dob = DateTime.tryParse(rawDob);
      if (rawDob is DateTime) dob = rawDob;
    }

    List<String> stringList(dynamic v) =>
        (v as List? ?? const []).map((e) => e.toString()).toList();

    int? intOrNull(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v);
      return null;
    }

    // ignore: no_leading_underscores_for_local_identifiers
    List<num>? _numList(dynamic v) {
      final l = (v as List?)?.cast<num>();
      return l;
    }

    return UserProfile(
      userId: (m['user_id'] ?? '').toString(),
      name: (m['name'] as String?)?.trim(),
      gender: (m['gender'] as String?)?.trim(),
      currentCity: (m['current_city'] as String?)?.trim(),
      bio: (m['bio'] as String?)?.trim(),
      dateOfBirth: dob,
      profilePictures: stringList(m['profile_pictures']),
      interests: stringList(m['interests']),
      relationshipGoals: stringList(m['relationship_goals']),
      languages: stringList(m['my_languages']),
      familyPlans: (m['family_plans'] as String?)?.trim(),
      loveLanguage: (m['love_language'] as String?)?.trim(),
      education: (m['education'] as String?)?.trim(),
      communicationStyle: (m['communication_style'] as String?)?.trim(),
      drinking: (m['drinking'] as String?)?.trim(),
      smoking: (m['smoking'] as String?)?.trim(),
      pets: (m['pets'] as String?)?.trim(),

      // NEW mappings
      heightCm: intOrNull(m['height_cm']),
      zodiacSign: (m['zodiac_sign'] as String?)?.trim(),
      workout: (m['workout'] as String?)?.trim(),
      dietaryPreference: (m['dietary_preference'] as String?)?.trim(),
      sleepingHabits: (m['sleeping_habits'] as String?)?.trim(),
      sexualOrientation: (m['sexual_orientation'] as String?)?.trim(),
      socialMedia: (m['social_media'] as String?)?.trim(),
      personalityType: (m['personality_type'] as String?)?.trim(),
      location2: _numList(m['location2']),
    );
  }
}

class ProfileRepository {
  ProfileRepository(this._db);
  final SupabaseClient _db;

  Future<UserProfile?> fetchByUserId(String userId) async {
    final row = await _db
        .from('profiles')
        .select('''
          user_id, name, gender, current_city, bio, date_of_birth,
          profile_pictures, interests, relationship_goals, my_languages,
          family_plans, love_language, education, communication_style,
          drinking, smoking, pets,
          height_cm, zodiac_sign, workout, dietary_preference, sleeping_habits,
          sexual_orientation, social_media, personality_type, location2
        ''')
        .eq('user_id', userId)
        .maybeSingle();

    if (row == null) return null;
    return UserProfile.fromMap(row);
  }
}
