// FILE: lib/core/config/profile_schema.dart
// Central descriptor for the `profiles` table so queries don’t reference
// non‑existent columns.
// Matches your SQL schema (no display_name/avatar_url columns).

class ProfileSchema {
  const ProfileSchema({
    this.table = 'profiles',

    // Identity
    this.idCol = 'user_id', // eq(user_id, <uid>)

    // Core profile fields
    this.displayNameCol = 'name',
    this.bioCol = 'bio',
    this.cityCol = 'current_city',

    // Optional columns present in your table
    this.ageCol = 'age', // nullable in DB
    this.dobCol = 'date_of_birth',
    this.photosCol = 'profile_pictures',
    this.avatarUrlCol, // keep null: no avatar_url column in DB

    // Additional optional columns that other screens may use
    this.genderCol = 'gender',
    this.languagesCol = 'my_languages',
    this.interestsCol = 'interests',
    this.goalsCol = 'relationship_goals',
    this.location2Col = 'location2',

    // Minimal logical requirements for a usable profile
    this.required = const ['name', 'profile_pictures', 'date_of_birth'],
  });

  // Table name
  final String table;

  // Identity / filtering
  final String idCol;

  // Basic columns
  final String displayNameCol;
  final String bioCol;
  final String cityCol;

  // Optional (nullable) columns
  final String? ageCol;
  final String? dobCol;
  final String? photosCol;
  final String? avatarUrlCol; // purposefully null by default

  // Extras used elsewhere
  final String? genderCol;
  final String? languagesCol;
  final String? interestsCol;
  final String? goalsCol;
  final String? location2Col;

  // Required logical fields (canonical names used in code)
  final List<String> required;

  /// Safe minimal select list – includes only existing, non-null column names.
  String selectMinimal() {
    final cols = <String>{idCol, displayNameCol, bioCol, cityCol};
    if (photosCol != null) cols.add(photosCol!);
    if (dobCol != null) cols.add(dobCol!);
    if (ageCol != null) cols.add(ageCol!);
    return cols.join(', ');
  }

  /// Rich select for edit wizards / profile detail screens.
  String selectRich() {
    final cols = <String>{
      idCol,
      displayNameCol,
      bioCol,
      cityCol,
      if (photosCol != null) photosCol!,
      if (dobCol != null) dobCol!,
      if (ageCol != null) ageCol!,
      if (genderCol != null) genderCol!,
      if (languagesCol != null) languagesCol!,
      if (interestsCol != null) interestsCol!,
      if (goalsCol != null) goalsCol!,
      if (location2Col != null) location2Col!,
    };
    return cols.join(', ');
  }
}

/// Use this everywhere unless you really need to override.
const defaultProfileSchema = ProfileSchema();
