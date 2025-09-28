// FILE: lib/features/profile/pages/edit_profile_page.dart
// Offline-first: hydrates from PeerProfileCache, saves via MyProfileStore outbox,
// and persists a photo upload queue to resume after app restarts.

import 'dart:convert';
import 'dart:typed_data';
 // keep original Uint8List import below intact if present

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../theme/app_theme.dart';
import '../edit_profile_repository.dart';
import '../../../widgets/photo_cropper_dialog.dart';

// Local-first cache & store
import '../../../core/cache/peer_profile_cache.dart';
import '../../profile/providers.dart' as profile_facade;

// ⬇️ Added: global cache wiper integration
import '../../../core/cache_wiper.dart';

// ──────────────────────────────────────────────────────────────
// Top-level enums
enum _Hydration { none, local, remote }
enum _LeaveAction { discard, save, cancel }

// ──────────────────────────────────────────────────────────────
// Signed URL resolver (public URLs return immediately) with tiny TTL cache.
class _SignedUrlCache {
  static const Duration _ttl = Duration(minutes: 30);
  static final Map<String, _SignedUrlEntry> _map = {};
  static const String _defaultBucket = 'profile_pictures';

  static Future<String> resolve(String urlOrPath) async {
    if (urlOrPath.startsWith('http')) return urlOrPath;

    final now = DateTime.now();
    final hit = _map[urlOrPath];
    if (hit != null && now.isBefore(hit.expires)) return hit.url;

    var cleaned = urlOrPath
        .replaceFirst(RegExp(r'^storage://'), '')
        .replaceFirst(RegExp(r'^/+'), '');

    String bucket;
    String path;

    final slash = cleaned.indexOf('/');
    if (slash <= 0) {
      bucket = _defaultBucket;
      path = cleaned;
    } else {
      bucket = cleaned.substring(0, slash);
      path = cleaned.substring(slash + 1);
      if (bucket.isEmpty) bucket = _defaultBucket;
    }

    final signed = await Supabase.instance.client.storage
        .from(bucket)
        .createSignedUrl(path, _ttl.inSeconds);

    _map[urlOrPath] = _SignedUrlEntry(
      signed,
      now.add(_ttl - const Duration(minutes: 2)),
    );
    return signed;
  }

  // ⬇️ Added: allow global wiper to clear this TTL map
  static void clear() {
    _map.clear();
  }
}

// ⬇️ Added: public helper + hook so CacheWiper can nuke this file-local cache
void clearEditProfileSignedUrlCache() => _SignedUrlCache.clear();

void _registerEditProfileWipeHook() {
  CacheWiper.registerHook(() async {
    clearEditProfileSignedUrlCache();
  });
}

// ignore: unused_element
final bool _editProfileWipeHookRegistered =
    (() { _registerEditProfileWipeHook(); return true; })();

class _SignedUrlEntry {
  _SignedUrlEntry(this.url, this.expires);
  final String url;
  final DateTime expires;
}

// ── Shared design tokens
const double _screenHPad = 10;
const double _radiusCard = 12;
const double _radiusPill = 10;

class EditProfilePage extends ConsumerStatefulWidget {
  const EditProfilePage({super.key});

  static const String routeName = 'editProfile';
  static const String routePath = '/edit-profile';

  @override
  ConsumerState<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends ConsumerState<EditProfilePage> {
  final _formKey = GlobalKey<FormState>();
  Color get _outline => AppTheme.ffAlt;

  _Hydration _hydrated = _Hydration.none;

  // Text/controllers
  final _name = TextEditingController();
  final _city = TextEditingController();
  final _bio = TextEditingController();
  final _loveLanguage = TextEditingController();
  final _communicationStyle = TextEditingController();
  final _education = TextEditingController();
  final _familyPlans = TextEditingController();

  // Extra details (persisted)
  final _socialMedia = TextEditingController();
  final _personalityType = TextEditingController();

  String? _gender; // M/F/O (UI shows labels)
  String? _sexualOrientation;
  DateTime? _dob;
  int? _heightCm;
  String? _zodiac;

  String? _workout;
  String? _dietary;
  String? _sleeping;

  bool _saving = false;
  final _pictures = <String>[];

  // Sets
  final _interests = <String>{};
  final _relationshipGoals = <String>{};
  final _languages = <String>{};

  // Lifestyle (persisted)
  String? _drinking;
  String? _smoking;
  String? _pets;

  // Optional lat/lng
  List<num>? _location2;

  // Photo busy HUD
  bool _photoBusy = false;
  String _photoBusyMsg = 'Processing photo…';

  // Track unsaved changes
  bool _dirty = false;
  void _markDirty() {
    if (!_dirty && mounted) setState(() => _dirty = true);
  }

  // Choices (consistent with schema-enum semantics)
  static const genders = ['Male', 'Female', 'Other'];
  static const sexualOrientationOptions = [
    'Straight',
    'Gay',
    'Lesbian',
    'Bisexual',
    'Asexual',
    'Queer',
    'Prefer not to say',
  ];

  static const interestOptions = [
    'Travel',
    'Music',
    'Foodie',
    'Art',
    'Outdoors',
    'Fitness',
    'Movies',
    'Reading',
    'Gaming',
  ];
  static const goalOptions = [
    'Long-term',
    'Short-term',
    'Open to explore',
    'Marriage',
    'Friendship',
  ];
  static const languageOptions = [
    'English',
    'Afrikaans',
    'Zulu',
    'Xhosa',
    'Sotho',
    'French',
    'Spanish',
    'German',
    'Italian',
    'Portuguese',
  ];

  static const petsOptions = ['No pets', 'Cat person', 'Dog person', 'All the pets'];
  static const drinkingOptions = ['Never', 'On special occasions', 'Socially', 'Often'];
  static const smokingOptions = ['Never', 'Occasionally', 'Smoker when drinking', 'Regularly'];

  static const workoutOptions = ['Never', 'Sometimes', 'Often'];
  static const dietaryOptions = ['Omnivore', 'Vegetarian', 'Vegan', 'Pescatarian', 'Halal', 'Kosher'];
  static const sleepingOptions = ['Early bird', 'Night owl', 'Flexible'];
  static const zodiacOptions = [
    'Aries',
    'Taurus',
    'Gemini',
    'Cancer',
    'Leo',
    'Virgo',
    'Libra',
    'Scorpio',
    'Sagittarius',
    'Capricorn',
    'Aquarius',
    'Pisces',
  ];

  // ---- DB <-> UI mappers (gender) ----
  String? _fromDbGender(String? raw) {
    if (raw == null) return null;
    switch (raw.toUpperCase()) {
      case 'M':
        return 'Male';
      case 'F':
        return 'Female';
      case 'O':
        return 'Other';
      default:
        return raw;
    }
  }

  String? _toDbGender(String? label) {
    switch (label) {
      case 'Male':
        return 'M';
      case 'Female':
        return 'F';
      case 'Other':
        return 'O';
      default:
        return label;
    }
  }

  // NOTE: store the subscription and close it in dispose().
  ProviderSubscription<Map<String, dynamic>?>? _profileSub;

  @override
  void initState() {
    super.initState();

    // 1) local-first hydration
    _hydrateFromLocalFirst();

    // 2) prefill once from already-loaded remote value
    final first = ref.read(profile_facade.myProfileProvider).valueOrNull;
    if (first != null && _hydrated != _Hydration.remote) {
      _prefillFromRaw(first);
      _hydrated = _Hydration.remote;
    }

    // 3) listen for remote updates using listenManual (allowed in initState)
    _profileSub = ref.listenManual<Map<String, dynamic>?>(
      profile_facade.myProfileProvider.select((a) => a.valueOrNull),
      (prev, next) {
        if (next != null && _hydrated != _Hydration.remote && mounted) {
          setState(() {
            _hydrated = _Hydration.remote;
            _prefillFromRaw(next);
          });
        }
      },
    );

    // 4) resume the photo outbox after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) => _flushPhotoOutbox());
  }

  Future<void> _hydrateFromLocalFirst() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    final raw = await PeerProfileCache.instance.read(uid);
    if (raw == null) return;
    if (mounted && _hydrated == _Hydration.none) {
      _prefillFromRaw(raw);
      setState(() => _hydrated = _Hydration.local);
    }
  }

  void _prefillFromRaw(Map<String, dynamic> m) {
    String? str(dynamic v) =>
        (v?.toString().trim().isEmpty ?? true) ? null : v.toString().trim();
    List<String> listStr(dynamic v) => v is List
        ? v
            .map((e) => e?.toString() ?? '')
            .where((t) => t.trim().isNotEmpty)
            .cast<String>()
            .toList()
        : <String>[];

    _name.text = str(m['name']) ?? '';
    _city.text = str(m['current_city']) ?? '';
    _bio.text = str(m['bio']) ?? '';
    _loveLanguage.text = str(m['love_language']) ?? '';
    _communicationStyle.text = str(m['communication_style']) ?? '';
    _education.text = str(m['education']) ?? '';
    _familyPlans.text = str(m['family_plans']) ?? '';

    _gender = _fromDbGender(str(m['gender']));
    final dobDyn = m['date_of_birth'];
    if (dobDyn is DateTime) {
      _dob = dobDyn;
    } else if (dobDyn is String) {
      _dob = DateTime.tryParse(dobDyn);
    } else {
      _dob = null;
    }

    _pictures
      ..clear()
      ..addAll(listStr(m['profile_pictures']));

    _interests
      ..clear()
      ..addAll(listStr(m['interests']));

    _relationshipGoals
      ..clear()
      ..addAll(listStr(m['relationship_goals']));

    _languages
      ..clear()
      ..addAll(listStr(m['my_languages']));

    _drinking = str(m['drinking']);
    _smoking = str(m['smoking']);
    _pets = str(m['pets']);

    _heightCm = (m['height_cm'] as num?)?.toInt();
    _zodiac = str(m['zodiac_sign']);
    _workout = str(m['workout']);
    _dietary = str(m['dietary_preference']);
    _sleeping = str(m['sleeping_habits']);
    _sexualOrientation = str(m['sexual_orientation']);
    _socialMedia.text = str(m['social_media']) ?? '';
    _personalityType.text = str(m['personality_type']) ?? '';

    final loc = m['location2'];
    if (loc is List && loc.length == 2) {
      final lat = (loc[0] as num?)?.toDouble();
      final lng = (loc[1] as num?)?.toDouble();
      if (lat != null && lng != null) _location2 = [lat, lng];
    }
  }

  @override
  void dispose() {
    _profileSub?.close(); // <- important

    _name.dispose();
    _city.dispose();
    _bio.dispose();
    _loveLanguage.dispose();
    _communicationStyle.dispose();
    _education.dispose();
    _familyPlans.dispose();
    _socialMedia.dispose();
    _personalityType.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final me = Supabase.instance.client.auth.currentUser;
    if (me == null) {
      return Scaffold(
        backgroundColor: AppTheme.ffSecondaryBg,
        appBar: AppBar(
          backgroundColor: AppTheme.ffPrimaryBg,
          title: const Text('Edit Profile'),
        ),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_outline, color: Colors.white70, size: 48),
                  const SizedBox(height: 12),
                  const Text(
                    'Please sign in to edit your profile',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.ffPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => context.go('/auth'),
                    child: const Text('Sign in', style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final profileAsync = ref.watch(profile_facade.myProfileProvider);

    Widget form() => Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(_screenHPad, 16, _screenHPad, 24),
            children: [
              // PHOTOS
              _Card(
                radius: _radiusCard,
                outline: _outline,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _Heading(icon: Icons.photo_library_outlined, text: 'Photos'),
                    const SizedBox(height: 12),
                    _PhotosGrid(
                      pictures: _pictures,
                      onAdd: _onAddPhoto,
                      onTapImage: (i) => _openPhotoViewer(i),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Tip: Add 3–6 clear photos for the best results.',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // BASICS
              _Card(
                radius: _radiusCard,
                outline: _outline,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _Heading(icon: Icons.badge_outlined, text: 'Basics'),
                    const SizedBox(height: 12),
                    _LabeledText('Name', _name, required: true, onChanged: (_) => _markDirty()),
                    const SizedBox(height: 12),
                    _Dropdown<String>(
                      label: 'Gender',
                      value: _gender,
                      items: genders,
                      onChanged: (v) => setState(() {
                        _gender = v;
                        _dirty = true;
                      }),
                    ),
                    const SizedBox(height: 12),
                    _Dropdown<String>(
                      label: 'Sexual orientation (optional)',
                      value: _sexualOrientation,
                      items: sexualOrientationOptions,
                      onChanged: (v) => setState(() {
                        _sexualOrientation = v;
                        _dirty = true;
                      }),
                    ),
                    const SizedBox(height: 12),
                    _DatePickerRow(
                      label: 'Date of birth',
                      value: _dob,
                      onPick: (d) => setState(() {
                        _dob = d;
                        _dirty = true;
                      }),
                    ),
                    const SizedBox(height: 12),
                    _LabeledText('Current city', _city, onChanged: (_) => _markDirty()),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        ElevatedButton.icon(
                          onPressed: _captureLocation,
                          icon: const Icon(Icons.my_location, size: 18, color: Colors.white),
                          label: const Text('Use my location', style: TextStyle(color: Colors.white)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.ffPrimary,
                            shape: const StadiumBorder(),
                          ),
                        ),
                        const SizedBox(width: 10),
                        if (_location2 != null)
                          const Text('Location set ✓', style: TextStyle(color: Colors.white70)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // ABOUT ME
              _Card(
                radius: _radiusCard,
                outline: _outline,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _Heading(icon: Icons.info_outline, text: 'About me'),
                    const SizedBox(height: 12),
                    _LabeledText('Short bio', _bio, maxLines: 4, onChanged: (_) => _markDirty()),
                    const SizedBox(height: 12),
                    _LabeledText('Love style (love language)', _loveLanguage, onChanged: (_) => _markDirty()),
                    const SizedBox(height: 12),
                    _LabeledText('Communication style', _communicationStyle, onChanged: (_) => _markDirty()),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // LIFESTYLE
              _Card(
                radius: _radiusCard,
                outline: _outline,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _Heading(icon: Icons.style_outlined, text: 'Lifestyle'),
                    const SizedBox(height: 12),

                    const _Subheading(icon: Icons.pets_outlined, text: 'Pets'),
                    const SizedBox(height: 6),
                    _RadioRow(
                      label: '',
                      value: _pets,
                      options: petsOptions,
                      onChanged: (v) => setState(() {
                        _pets = v;
                        _dirty = true;
                      }),
                      showLabel: false,
                    ),
                    const SizedBox(height: 10),

                    const _Subheading(icon: Icons.local_bar_rounded, text: 'Drinking'),
                    const SizedBox(height: 6),
                    _RadioRow(
                      label: '',
                      value: _drinking,
                      options: drinkingOptions,
                      onChanged: (v) => setState(() {
                        _drinking = v;
                        _dirty = true;
                      }),
                      showLabel: false,
                    ),
                    const SizedBox(height: 10),

                    const _Subheading(icon: Icons.smoke_free, text: 'Smoking'),
                    const SizedBox(height: 6),
                    _RadioRow(
                      label: '',
                      value: _smoking,
                      options: smokingOptions,
                      onChanged: (v) => setState(() {
                        _smoking = v;
                        _dirty = true;
                      }),
                      showLabel: false,
                    ),
                    const SizedBox(height: 10),

                    const _Subheading(icon: Icons.fitness_center, text: 'Workout'),
                    const SizedBox(height: 6),
                    _RadioRow(
                      label: '',
                      value: _workout,
                      options: workoutOptions,
                      onChanged: (v) => setState(() {
                        _workout = v;
                        _dirty = true;
                      }),
                      showLabel: false,
                    ),
                    const SizedBox(height: 10),

                    const _Subheading(icon: Icons.restaurant_menu, text: 'Dietary preference'),
                    const SizedBox(height: 6),
                    _RadioRow(
                      label: '',
                      value: _dietary,
                      options: dietaryOptions,
                      onChanged: (v) => setState(() {
                        _dietary = v;
                        _dirty = true;
                      }),
                      showLabel: false,
                    ),
                    const SizedBox(height: 10),

                    const _Subheading(icon: Icons.nightlight_round, text: 'Sleeping habits'),
                    const SizedBox(height: 6),
                    _RadioRow(
                      label: '',
                      value: _sleeping,
                      options: sleepingOptions,
                      onChanged: (v) => setState(() {
                        _sleeping = v;
                        _dirty = true;
                      }),
                      showLabel: false,
                    ),
                    const SizedBox(height: 12),

                    _LabeledText('Social media (handle / link)', _socialMedia, onChanged: (_) => _markDirty()),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // INTERESTS
              _Card(
                radius: _radiusCard,
                outline: _outline,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _Heading(icon: Icons.interests_outlined, text: 'Interests'),
                    const SizedBox(height: 10),
                    _ChipsSelector(
                      options: interestOptions,
                      values: _interests,
                      onChanged: (v) => setState(() {
                        _interests
                          ..clear()
                          ..addAll(v);
                        _dirty = true;
                      }),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // RELATIONSHIP GOALS
              _Card(
                radius: _radiusCard,
                outline: _outline,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _Heading(icon: Icons.flag_outlined, text: 'Relationship goals'),
                    const SizedBox(height: 10),
                    _ChipsSelector(
                      options: goalOptions,
                      values: _relationshipGoals,
                      onChanged: (v) => setState(() {
                        _relationshipGoals
                          ..clear()
                          ..addAll(v);
                        _dirty = true;
                      }),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // LANGUAGES
              _Card(
                radius: _radiusCard,
                outline: _outline,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _Heading(icon: Icons.translate_outlined, text: 'Languages I know'),
                    const SizedBox(height: 10),
                    _CheckboxGroup(
                      options: languageOptions,
                      values: _languages,
                      onChanged: (v) => setState(() {
                        _languages
                          ..clear()
                          ..addAll(v);
                        _dirty = true;
                      }),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // MORE ABOUT ME
              _Card(
                radius: _radiusCard,
                outline: _outline,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _Heading(icon: Icons.more_horiz_rounded, text: 'More about me'),
                    const SizedBox(height: 12),
                    _LabeledText('Education', _education, onChanged: (_) => _markDirty()),
                    const SizedBox(height: 12),
                    _LabeledText('Family plans', _familyPlans, onChanged: (_) => _markDirty()),
                    const SizedBox(height: 12),
                    _NumberPickerRow(
                      label: 'Height (cm)',
                      value: _heightCm,
                      min: 120,
                      max: 220,
                      onChanged: (v) => setState(() {
                        _heightCm = v;
                        _dirty = true;
                      }),
                    ),
                    const SizedBox(height: 12),
                    _Dropdown<String>(
                      label: 'Zodiac (optional)',
                      value: _zodiac,
                      items: zodiacOptions,
                      onChanged: (v) => setState(() {
                        _zodiac = v;
                        _dirty = true;
                      }),
                    ),
                    const SizedBox(height: 12),
                    _LabeledText('Personality type (e.g., ENFJ)', _personalityType, onChanged: (_) => _markDirty()),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _saving ? null : _onSave,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.ffPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _saving
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Save Changes', style: TextStyle(color: Colors.white, fontSize: 16)),
              ),
            ],
          ),
        );

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldLeave = await _confirmLeaveDialog();
        if (!mounted) return;
        if (shouldLeave) Navigator.of(context).pop();
      },
      child: Scaffold(
        backgroundColor: AppTheme.ffSecondaryBg,
        appBar: AppBar(
          backgroundColor: AppTheme.ffPrimaryBg,
          title: const Text('Edit Profile'),
          actions: const [SizedBox(width: 8)],
        ),
        body: Stack(
          children: [
            SafeArea(
              child: profileAsync.when(
                loading: () => _hydrated != _Hydration.none
                    ? form()
                    : const Center(child: CircularProgressIndicator()),
                error: (e, _) => _hydrated != _Hydration.none
                    ? form()
                    : Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'Failed to load profile: $e',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ),
                      ),
                data: (_) => form(),
              ),
            ),

            if (_photoBusy)
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 120),
                    opacity: _photoBusy ? 1 : 0,
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.55),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: AppTheme.ffPrimaryBg,
                            border: Border.all(color: AppTheme.ffAlt),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                              const SizedBox(width: 10),
                              Text(_photoBusyMsg, style: const TextStyle(color: Colors.white)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirmLeaveDialog() async {
    if (!_dirty) return true;

    final action = await showDialog<_LeaveAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F0F10),
        title: const Text('Discard changes?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'You have unsaved changes. Do you want to save them before leaving?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_LeaveAction.cancel),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_LeaveAction.discard),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(_LeaveAction.save),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    // ⬇️ Added: fix `use_build_context_synchronously` by guarding BuildContext after await
    if (!context.mounted) return false;

    switch (action) {
      case _LeaveAction.discard:
        _dirty = false;
        return true;              // allow PopScope to pop
      case _LeaveAction.save:
        await _onSave();          // _onSave() already navigates
        return false;             // <- prevent PopScope from popping again
      case _LeaveAction.cancel:
      default:
        return false;             // stay on page
    }
  }

  Future<void> _flushPhotoOutbox() async {
    final uid = _meIdOptional();
    if (uid == null) return;

    try {
      await _PhotoUploadOutbox.instance.flush(
        userId: uid,
        ref: ref,
        onPicturesUpdated: (urls) async {
          if (!mounted) return;
          setState(() {
            _pictures
              ..clear()
              ..addAll(urls);
          });
          final raw = await PeerProfileCache.instance.read(uid) ?? <String, dynamic>{'user_id': uid};
          raw['profile_pictures'] = urls;
          await PeerProfileCache.instance.write(uid, raw);
        },
      );

      // ensure _pictures reflects store/cache on cold start
      final storeProfile = ref.read(profile_facade.myProfileProvider).valueOrNull;
      if (_pictures.isEmpty && storeProfile != null) {
        final current = _extractPictures(storeProfile);
        if (mounted && current.isNotEmpty) {
          setState(() {
            _pictures
              ..clear()
              ..addAll(current);
          });
        }
      }
    } catch (_) {
      // best-effort
    }
  }

  List<String> _extractPictures(Map<String, dynamic>? m) {
    if (m == null) return [];
    final v = m['profile_pictures'];
    return v is List ? v.map((e) => e?.toString() ?? '').where((s) => s.isNotEmpty).toList() : [];
  }

  Future<void> _captureLocation() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever || perm == LocationPermission.denied) {
        if (!mounted) return;
        _snack('Location permission denied', isError: true);
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      if (!mounted) return;
      setState(() {
        _location2 = [pos.latitude, pos.longitude];
        _dirty = true;
      });
    } catch (e) {
      if (!mounted) return;
      _snack('Failed to get location: $e', isError: true);
    }
  }

  // ---- Crop dialog ----
  Future<Uint8List?> _cropWithDialogPro(Uint8List srcBytes) async {
    return showProfilePhotoCropper(context, sourceBytes: srcBytes);
  }

  Future<void> _openPhotoViewer(int index) async {
    if (index < 0 || index >= _pictures.length) return;
    final raw = _pictures[index];

    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'photo',
      barrierColor: Colors.black.withValues(alpha: 0.9),
      pageBuilder: (_, __, ___) {
        final mq = MediaQuery.of(context);
        final targetW = (mq.size.width * mq.devicePixelRatio).round();

        return Material(
          color: Colors.transparent,
          child: Stack(
            children: [
              Center(
                child: InteractiveViewer(
                  child: _SignedImage(
                    rawUrlOrPath: raw,
                    fit: BoxFit.contain,
                    explicitLogicalWidth: mq.size.width,
                    explicitCacheWidth: targetW,
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      _pillButton(icon: Icons.close, label: 'Close', onTap: () => Navigator.of(context).pop()),
                      const Spacer(),
                      _pillButton(
                        icon: Icons.photo_library_outlined,
                        label: 'Replace',
                        onTap: () async {
                          final nav = Navigator.of(context);
                          nav.pop();
                          await _replacePhotoAt(index);
                        },
                      ),
                      const SizedBox(width: 8),
                      _pillButton(
                        icon: Icons.delete_outline,
                        label: 'Delete',
                        onTap: () async {
                          final nav = Navigator.of(context);
                          nav.pop();
                          await _withPhotoBusy('Deleting photo…', () async {
                            setState(() => _pictures.removeAt(index));
                            ref
                                .read(profile_facade.myProfileProvider.notifier)
                                .updateProfile({'profile_pictures': List<String>.from(_pictures)});
                            // keep cache in sync for offline
                            final uid = _meId();
                            final raw = await PeerProfileCache.instance.read(uid) ??
                                <String, dynamic>{'user_id': uid};
                            raw['profile_pictures'] = List<String>.from(_pictures);
                            await PeerProfileCache.instance.write(uid, raw);
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _pillButton({required IconData icon, required String label, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.ffPrimaryBg.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppTheme.ffAlt),
        ),
        child: Row(children: [
          Icon(icon, size: 18, color: Colors.white),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(color: Colors.white)),
        ]),
      ),
    );
  }

  Future<void> _replacePhotoAt(int index) async {
    final picker = ImagePicker();
    final xfile = await picker.pickImage(source: ImageSource.gallery);
    if (xfile == null) return;

    final originalBytes = await xfile.readAsBytes();
    final croppedBytes = await _cropWithDialogPro(originalBytes);
    if (croppedBytes == null) return;

    if (mounted) {
      setState(() {
        _photoBusy = true;
        _photoBusyMsg = 'Uploading photo…';
      });
    }

    try {
      final entryId = await _PhotoUploadOutbox.instance.enqueueReplace(
        userId: _meId(),
        index: index,
        fileName: xfile.name,
        bytes: croppedBytes,
        tempPath: null,
      );

      await _flushPhotoOutbox();
      if (!mounted) return;
      _snack('Photo update queued${entryId != null ? '' : ''}');
      _dirty = true;
    } catch (e) {
      if (!mounted) return;
      _snack('Failed to queue upload: $e', isError: true);
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  Future<void> _onAddPhoto() async {
    if (_pictures.length >= 6) {
      _snack('You can add up to 6 photos.');
      return;
    }

    final picker = ImagePicker();
    final xfile = await picker.pickImage(source: ImageSource.gallery);
    if (xfile == null) return;

    final originalBytes = await xfile.readAsBytes();
    final croppedBytes = await _cropWithDialogPro(originalBytes);
    if (croppedBytes == null) return;

    if (mounted) {
      setState(() {
        _photoBusy = true;
        _photoBusyMsg = 'Uploading photo…';
      });
    }

    try {
      final entryId = await _PhotoUploadOutbox.instance.enqueueAdd(
        userId: _meId(),
        fileName: xfile.name,
        bytes: croppedBytes,
        tempPath: null,
      );

      await _flushPhotoOutbox();
      if (!mounted) return;
      _snack('Photo queued${entryId != null ? '' : ''}');
      _dirty = true;
    } catch (e) {
      if (!mounted) return;
      _snack('Failed to queue upload: $e', isError: true);
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  Future<T> _withPhotoBusy<T>(String message, Future<T> Function() body) async {
    if (mounted) {
      setState(() {
        _photoBusy = true;
        _photoBusyMsg = message;
      });
    }
    try {
      return await body();
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  Future<void> _onSave() async {
    if (!_formKey.currentState!.validate()) return;
    if (_gender == null || _dob == null) {
      _snack('Please select gender and date of birth', isError: true);
      return;
    }
    if (_pictures.isEmpty) {
      _snack('Please keep at least one profile photo', isError: true);
      return;
    }

    setState(() => _saving = true);
    try {
      final me = _meId();

      int calcAge(DateTime d) {
        final now = DateTime.now();
        var a = now.year - d.year;
        if (now.month < d.month || (now.month == d.month && now.day < d.day)) a--;
        return a;
      }

      final patch = <String, dynamic>{
        'name': _name.text.trim(),
        'gender': _toDbGender(_gender!),
        'current_city': _city.text.trim().isEmpty ? null : _city.text.trim(),
        'bio': _bio.text.trim().isEmpty ? null : _bio.text.trim(),
        'love_language': _loveLanguage.text.trim().isEmpty ? null : _loveLanguage.text.trim(),
        'communication_style': _communicationStyle.text.trim().isEmpty ? null : _communicationStyle.text.trim(),
        'education': _education.text.trim().isEmpty ? null : _education.text.trim(),
        'family_plans': _familyPlans.text.trim().isEmpty ? null : _familyPlans.text.trim(),
        'date_of_birth': _dob!.toIso8601String().split('T').first,
        'age': calcAge(_dob!),
        'profile_pictures': List<String>.from(_pictures),
        'interests': List<String>.from(_interests),
        'relationship_goals': List<String>.from(_relationshipGoals),
        'my_languages': List<String>.from(_languages),
        'drinking': _drinking,
        'smoking': _smoking,
        'pets': _pets,
        if (_location2 != null) 'location2': _location2,
        'sexual_orientation': (_sexualOrientation?.isNotEmpty ?? false) ? _sexualOrientation : null,
        'height_cm': _heightCm,
        'zodiac_sign': _zodiac,
        'workout': _workout,
        'dietary_preference': _dietary,
        'sleeping_habits': _sleeping,
        'social_media': _socialMedia.text.trim().isEmpty ? null : _socialMedia.text.trim(),
        'personality_type': _personalityType.text.trim().isEmpty ? null : _personalityType.text.trim(),
        // updated_at handled by trigger
      };

      // Optimistic local write + queue remote via store (facade)
      ref.read(profile_facade.myProfileProvider.notifier).updateProfile(patch);

      // Keep PeerProfileCache in sync for other offline-first screens
      final raw = await PeerProfileCache.instance.read(me) ?? <String, dynamic>{'user_id': me};
      raw.addAll(patch);
      await PeerProfileCache.instance.write(me, raw);

      // Persist to Supabase (upsert on user_id)
      await Supabase.instance.client
          .from('profiles')
          .upsert({...patch, 'user_id': me}, onConflict: 'user_id');

      // Mark clean before navigation
      _dirty = false;

      // Nudge a background refresh
      ref.read(profile_facade.myProfileProvider.notifier).refresh();

      if (!mounted) return;
      // Prefer returning to the previous screen (Profile View). Fallback to a direct route.
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true); // return “saved”
      } else {
        context.go('/userProfile'); // <- your actual profile view route
      }
    } catch (e) {
      if (!mounted) return;
      _snack('Failed to save: $e', isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _meId() {
    final me = Supabase.instance.client.auth.currentUser?.id;
    if (me == null) throw Exception('Not authenticated');
    return me;
  }

  String? _meIdOptional() => Supabase.instance.client.auth.currentUser?.id;

  void _snack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.red : Colors.green,
    ));
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, required this.radius, required this.outline});
  final Widget child;
  final double radius;
  final Color outline;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color.fromARGB(255, 0, 0, 0),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: outline.withValues(alpha: .50), width: 1.2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: child,
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppTheme.ffPrimary, size: 18),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: .2,
          ),
        ),
      ],
    );
  }
}

class _Subheading extends StatelessWidget {
  const _Subheading({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppTheme.ffPrimary),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 14,
            letterSpacing: .2,
          ),
        ),
      ],
    );
  }
}

class _LabeledText extends StatelessWidget {
  const _LabeledText(this.label, this.controller, {this.maxLines = 1, this.required = false, this.onChanged});
  final String label;
  final TextEditingController controller;
  final int maxLines;
  final bool required;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        filled: true,
        fillColor: const Color(0xFF141414),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
          borderRadius: BorderRadius.circular(_radiusPill),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: AppTheme.ffPrimary),
          borderRadius: BorderRadius.circular(_radiusPill),
        ),
      ),
      validator: required ? (v) => (v == null || v.trim().isEmpty) ? '$label is required' : null : null,
      onChanged: onChanged,
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({required this.label, required this.value, required this.items, required this.onChanged});
  final String label;
  final T? value;
  final List<T> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    final T? safeValue = (value != null && items.contains(value)) ? value : null;

    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        filled: true,
        fillColor: const Color(0xFF141414),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
          borderRadius: BorderRadius.circular(_radiusPill),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: AppTheme.ffPrimary),
          borderRadius: BorderRadius.circular(_radiusPill),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: safeValue,
          isExpanded: true,
          dropdownColor: const Color(0xFF000000),
          items: items
              .map((e) => DropdownMenuItem<T>(
                    value: e,
                    child: Text(e.toString(), style: const TextStyle(color: Colors.white)),
                  ))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _DatePickerRow extends StatelessWidget {
  const _DatePickerRow({required this.label, required this.value, required this.onPick});
  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onPick;

  @override
  Widget build(BuildContext context) {
    Future<void> pick() async {
      final now = DateTime.now();
      final first = DateTime(now.year - 80, 1, 1);
      final last = DateTime(now.year - 18, now.month, now.day);
      final initial = value ?? DateTime(now.year - 25, 1, 1);
      final picked = await showDatePicker(
        context: context,
        firstDate: first,
        lastDate: last,
        initialDate: initial,
        helpText: 'Select your date of birth',
        builder: (context, child) => Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: AppTheme.ffPrimary,
                  onPrimary: Colors.white,
                  surface: const Color(0xFF000000),
                  onSurface: Colors.white,
                ),
          ),
          child: child!,
        ),
      );
      onPick(picked);
    }

    return InkWell(
      onTap: pick,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white70),
          filled: true,
          fillColor: const Color(0xFF141414),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
            borderRadius: BorderRadius.circular(_radiusPill),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: const BorderSide(color: AppTheme.ffPrimary),
            borderRadius: BorderRadius.circular(_radiusPill),
          ),
        ),
        child: Text(
          value == null
              ? 'Select...'
              : '${value!.year}-${value!.month.toString().padLeft(2, '0')}-${value!.day.toString().padLeft(2, '0')}',
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }
}

class _ChipsSelector extends StatelessWidget {
  const _ChipsSelector({
    required this.options,
    required this.values,
    required this.onChanged,
  });
  final List<String> options;
  final Set<String> values;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 10,
      children: options.map((opt) {
        final selected = values.contains(opt);
        return FilterChip(
          label: Text(opt),
          selected: selected,
          onSelected: (isSel) {
            final next = {...values};
            isSel ? next.add(opt) : next.remove(opt);
            onChanged(next);
          },
          labelStyle: TextStyle(color: selected ? Colors.white : Colors.white70),
          selectedColor: AppTheme.ffPrimary.withValues(alpha: .55),
          backgroundColor: const Color(0xFF141414),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radiusPill)),
          side: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
        );
      }).toList(),
    );
  }
}

class _CheckboxGroup extends StatelessWidget {
  const _CheckboxGroup({
    required this.options,
    required this.values,
    required this.onChanged,
  });
  final List<String> options;
  final Set<String> values;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      children: options.map((opt) {
        final sel = values.contains(opt);
        return InkWell(
          onTap: () {
            final next = {...values};
            sel ? next.remove(opt) : next.add(opt);
            onChanged(next);
          },
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Checkbox(
              value: sel,
              onChanged: (_) {
                final next = {...values};
                sel ? next.remove(opt) : next.add(opt);
                onChanged(next);
              },
              activeColor: AppTheme.ffPrimary,
            ),
            Text(opt, style: const TextStyle(color: Colors.white70)),
          ]),
        );
      }).toList(),
    );
  }
}

class _RadioRow extends StatelessWidget {
  const _RadioRow({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.showLabel = true,
  });

  final String label;
  final String? value;
  final List<String> options;
  final ValueChanged<String?> onChanged;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLabel && label.isNotEmpty)
          Text(label, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
        if (showLabel && label.isNotEmpty) const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: options.map((opt) {
            final sel = value == opt;
            return ChoiceChip(
              label: Text(opt),
              selected: sel,
              onSelected: (_) => onChanged(opt),
              labelStyle: TextStyle(color: sel ? Colors.white : Colors.white70),
              selectedColor: AppTheme.ffPrimary.withValues(alpha: .6),
              backgroundColor: const Color(0xFF141414),
              side: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radiusPill)),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _NumberPickerRow extends StatelessWidget {
  const _NumberPickerRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int? value;
  final int min;
  final int max;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        filled: true,
        fillColor: const Color(0xFF141414),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
          borderRadius: BorderRadius.circular(_radiusPill),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: AppTheme.ffPrimary),
          borderRadius: BorderRadius.circular(_radiusPill),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: (value ?? min) > min ? () => onChanged((value ?? min) - 1) : null,
            icon: const Icon(Icons.remove, color: Colors.white70),
          ),
          Expanded(
            child: Center(
              child: Text(value?.toString() ?? '—', style: const TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ),
          IconButton(
            onPressed: (value ?? min) < max ? () => onChanged((value ?? min) + 1) : null,
            icon: const Icon(Icons.add, color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

class _PhotosGrid extends StatelessWidget {
  const _PhotosGrid({required this.pictures, required this.onAdd, required this.onTapImage});
  final List<String> pictures;
  final VoidCallback onAdd;
  final ValueChanged<int> onTapImage; // index-based

  @override
  Widget build(BuildContext context) {
    final shown = pictures.take(6).toList();

    final cells = <Widget>[
      for (int i = 0; i < shown.length; i++)
        InkWell(
          onTap: () => onTapImage(i),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: _SignedImage(rawUrlOrPath: shown[i], fit: BoxFit.cover),
          ),
        ),
      if (shown.length < 6)
        InkWell(
          onTap: onAdd,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF141414),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.ffAlt.withValues(alpha: .60)),
            ),
            child: const Center(child: Icon(Icons.add_a_photo_outlined, color: Colors.white70)),
          ),
        ),
    ];

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 3,
      childAspectRatio: 4 / 5,
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      children: cells,
    );
  }
}

/// Optimized image that resolves private storage paths and uses cacheWidth.
class _SignedImage extends StatelessWidget {
  const _SignedImage({
    required this.rawUrlOrPath,
    required this.fit,
    this.explicitLogicalWidth,
    this.explicitCacheWidth,
  });

  final String rawUrlOrPath;
  final BoxFit fit;
  final double? explicitLogicalWidth; // hint
  final int? explicitCacheWidth; // exact cacheWidth in device pixels

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final logicalW = explicitLogicalWidth ?? constraints.maxWidth;
      final cacheW = explicitCacheWidth ?? (logicalW.isFinite ? (logicalW * dpr).round() : null);

      return FutureBuilder<String>(
        future: _SignedUrlCache.resolve(rawUrlOrPath),
        builder: (context, snap) {
          if (!snap.hasData) return const _GridShimmer();
          return Image.network(
            snap.data!,
            fit: fit,
            cacheWidth: cacheW,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const _GridShimmer();
            },
            errorBuilder: (_, __, ___) => const ColoredBox(
              color: Colors.black26,
              child: Center(child: Icon(Icons.broken_image, color: Colors.white70)),
            ),
          );
        },
      );
    });
  }
}

class _GridShimmer extends StatelessWidget {
  const _GridShimmer();
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF202227),
      child: const Center(
        child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 1.8)),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// Persistent photo upload outbox for profile pictures

class _PhotoUploadOutbox {
  _PhotoUploadOutbox._();
  static final _PhotoUploadOutbox instance = _PhotoUploadOutbox._();

  static const String _kPrefix = 'photo_outbox_v1_';
  bool _flushing = false;

  Future<String?> enqueueAdd({
    required String userId,
    required String fileName,
    Uint8List? bytes,
    String? tempPath,
  }) async {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final entry = {
      'id': id,
      'type': 'add',
      'index': null,
      'fileName': fileName,
      'tempPath': tempPath,
      'bytesB64': bytes != null ? base64Encode(bytes) : null,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    };
    await _write(userId, [...await _read(userId), entry]);
    return id;
  }

  Future<String?> enqueueReplace({
    required String userId,
    required int index,
    required String fileName,
    Uint8List? bytes,
    String? tempPath,
  }) async {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final entry = {
      'id': id,
      'type': 'replace',
      'index': index,
      'fileName': fileName,
      'tempPath': tempPath,
      'bytesB64': bytes != null ? base64Encode(bytes) : null,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    };
    await _write(userId, [...await _read(userId), entry]);
    return id;
  }

  Future<void> flush({
    required String userId,
    required WidgetRef ref,
    required Future<void> Function(List<String> urls) onPicturesUpdated,
  }) async {
    if (_flushing) return;
    final prefs = await SharedPreferences.getInstance();
    _flushing = true;
    try {
      final key = '$_kPrefix$userId';
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return;
      final List list = jsonDecode(raw) as List;
      final queue = List<Map<String, dynamic>>.from(list.cast<Map>());
      if (queue.isEmpty) return;

      final repo = EditProfileRepository(Supabase.instance.client);

      // derive current pictures from store map or cache (snake_case only)
      List<String> current = [];
      final storeMap = ref.read(profile_facade.myProfileProvider).valueOrNull;
      if (storeMap != null) {
        final v = storeMap['profile_pictures'];
        if (v is List) {
          current = v
              .map((e) => e?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .cast<String>()
              .toList();
        }
      } else {
        final cached = await PeerProfileCache.instance.read(userId);
        if (cached != null && cached['profile_pictures'] is List) {
          current = (cached['profile_pictures'] as List)
              .map((e) => e?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .cast<String>()
              .toList();
        }
      }

      final nextQueue = <Map<String, dynamic>>[];
      var anyChange = false;

      for (final e in queue) {
        try {
          final String? b64 = (e['bytesB64'] as String?);
          final String fileName = (e['fileName'] as String?) ?? 'photo.jpg';
          final bytes = b64 != null ? base64Decode(b64) : Uint8List(0);
          final url = await repo.uploadProfileImage(userId: userId, filePath: fileName, bytes: bytes);

          final type = e['type'] as String?;
          if (type == 'replace') {
            final idx = (e['index'] as num?)?.toInt() ?? -1;
            if (idx >= 0 && idx < current.length) {
              current[idx] = url;
            } else if (current.length < 6) {
              current.add(url);
            }
          } else {
            if (current.length < 6) current.add(url);
          }

          ref.read(profile_facade.myProfileProvider.notifier)
             .updateProfile({'profile_pictures': List<String>.from(current)});
          await repo.setProfilePictures(userId: userId, urls: List<String>.from(current));
          anyChange = true;
        } catch (_) {
          nextQueue.add(e);
        }
      }

      if (anyChange) await onPicturesUpdated(current);
      await prefs.setString(key, jsonEncode(nextQueue));
    } finally {
      _flushing = false;
    }
  }

  Future<List<Map<String, dynamic>>> _read(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_kPrefix$userId');
    if (raw == null || raw.isEmpty) return [];
    try {
      final List list = jsonDecode(raw) as List;
      return List<Map<String, dynamic>>.from(list.cast<Map>());
    } catch (_) {
      return [];
    }
  }

  Future<void> _write(String userId, List<Map<String, dynamic>> xs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_kPrefix$userId', jsonEncode(xs));
  }
}
