// test/completion_test.dart
// Unit tests for evaluateProfileCompletion (strict completeness rules)

import 'package:flutter_test/flutter_test.dart';
import 'package:bangher/features/profile/completion_rules.dart';

Map<String, dynamic> fullProfile({String city = 'Cape Town', List<num>? location2}) {
  return {
    'name': 'Sam',
    'gender': 'M',
    'date_of_birth': '1995-06-01',
    'current_city': city,
    'bio': 'hi',
    'love_language': 'Quality Time', // REQUIRED now
    'interests': ['Travel', 'Music', 'Foodie'],
    'relationship_goals': ['Long-term'],
    'my_languages': ['English'],
    'profile_pictures': ['https://x/y.jpg'],
    if (location2 != null) 'location2': location2,
  };
}

Map<String, dynamic> fullPrefs({int aMin = 21, int aMax = 35, int dist = 50}) => {
      'interested_in_gender': 'F',
      'age_min': aMin,
      'age_max': aMax,
      'distance_radius': dist,
    };

void main() {
  group('evaluateProfileCompletion', () {
    test('complete profile passes', () {
      final r = evaluateProfileCompletion(profile: fullProfile(), prefs: fullPrefs());
      expect(r.complete, isTrue);
      expect(r.missing, isEmpty);
    });

    test('under 18 fails dob', () {
      final p = fullProfile();
      p['date_of_birth'] = DateTime.now().subtract(const Duration(days: 17 * 365)).toIso8601String();
      final r = evaluateProfileCompletion(profile: p, prefs: fullPrefs(), now: DateTime.now());
      expect(r.missing, contains(StepId.dob));
    });

    test('no photos fails photosAndPrefs', () {
      final p = fullProfile();
      p['profile_pictures'] = [];
      final r = evaluateProfileCompletion(profile: p, prefs: fullPrefs());
      expect(r.missing, contains(StepId.photosAndPrefs));
    });

    test('too few interests fails interests', () {
      final p = fullProfile();
      p['interests'] = ['Travel', 'Music'];
      final r = evaluateProfileCompletion(profile: p, prefs: fullPrefs());
      expect(r.missing, contains(StepId.interests));
    });

    test('invalid prefs fails photosAndPrefs', () {
      final r = evaluateProfileCompletion(
        profile: fullProfile(),
        prefs: fullPrefs(aMin: 10, aMax: 8, dist: 0),
      );
      expect(r.missing, contains(StepId.photosAndPrefs));
    });

    test('missing city but valid GPS location passes city check', () {
      final p = fullProfile(city: '');
      p['location2'] = [-33.92, 18.42];
      final r = evaluateProfileCompletion(profile: p, prefs: fullPrefs());
      expect(r.missing.contains(StepId.city), isFalse);
    });

    test('city label "Unknown" but GPS exists passes', () {
      final p = fullProfile(city: 'Unknown', location2: [-33.92, 18.42]);
      final r = evaluateProfileCompletion(profile: p, prefs: fullPrefs());
      expect(r.missing.contains(StepId.city), isFalse);
    });

    test('gender missing fails nameGender', () {
      final p = fullProfile();
      p['gender'] = '';
      final r = evaluateProfileCompletion(profile: p, prefs: fullPrefs());
      expect(r.missing, contains(StepId.nameGender));
    });

    test('interested_in missing fails interestedIn', () {
      final r = evaluateProfileCompletion(profile: fullProfile(), prefs: {});
      expect(r.missing, contains(StepId.interestedIn));
    });

    test('languages empty fails languages', () {
      final p = fullProfile();
      p['my_languages'] = [];
      final r = evaluateProfileCompletion(profile: p, prefs: fullPrefs());
      expect(r.missing, contains(StepId.languages));
    });

    test('goals empty fails goals', () {
      final p = fullProfile();
      p['relationship_goals'] = [];
      final r = evaluateProfileCompletion(profile: p, prefs: fullPrefs());
      expect(r.missing, contains(StepId.goals));
    });

    test('love_language missing fails about', () {
      final p = fullProfile();
      p.remove('love_language');
      final r = evaluateProfileCompletion(profile: p, prefs: fullPrefs());
      expect(r.missing, contains(StepId.about));
    });
  });
}
