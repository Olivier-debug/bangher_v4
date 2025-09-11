// FILE: lib/features/profile/pages/edit_profile_page.dart
// Visual refresh to match UserProfilePage + media/auth hardening:
// - Full-width matte cards with white outline (radius 12)
// - Pink section icons, unified outline color, radius-10 pills/chips
// - Increased side-to-side fill (outer padding 10, like UserProfilePage)
// - Lifestyle subheadings show icon; radio rows don't repeat labels
// - AUTH-SAFE: early return if signed out (no provider/network work)
// - MEDIA-SAFE + MOBILE-OPTIMIZED: thumbnails & viewer resolve private
//   storage paths to short-lived signed URLs with a tiny in-memory TTL
//   cache, and request images at display size (cacheWidth) to save
//   bandwidth and memory on mobile.
// - Logic (save/upload/providers) otherwise unchanged.

import 'package:flutter/foundation.dart'; // compute, kIsWeb, Uint8List
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Haptics for cropper actions
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:extended_image/extended_image.dart'; // Cropper
import 'package:image/image.dart' as img; // Cropping backend

// Platform helper: writes a temp file on mobile/desktop; stub on web.
import '../../../utils/write_temp_file_io.dart'
    if (dart.library.html) '../../../utils/write_temp_file_web.dart' as tempfs;

import '../../../theme/app_theme.dart';
import '../profile_repository.dart';
import '../edit_profile_repository.dart';
import 'user_profile_gate.dart';

// ──────────────────────────────────────────────────────────────
// Signed URL resolver (public URLs return immediately) with tiny TTL cache.

class _SignedUrlCache {
  static const Duration _ttl = Duration(minutes: 30);
  static final Map<String, _SignedUrlEntry> _map = {};

  static Future<String> resolve(String urlOrPath) async {
    // If it's already a public HTTP(s) URL, return as-is.
    if (urlOrPath.startsWith('http')) return urlOrPath;

    final now = DateTime.now();
    final hit = _map[urlOrPath];
    if (hit != null && now.isBefore(hit.expires)) return hit.url;

    // Accept "bucket/path/to/file.jpg" or "storage://bucket/path..."
    final cleaned = urlOrPath.replaceFirst(RegExp(r'^storage://'), '');
    final slash = cleaned.indexOf('/');
    if (slash <= 0) throw StateError('Invalid storage path: $urlOrPath');
    final bucket = cleaned.substring(0, slash);
    final path = cleaned.substring(slash + 1);

    final signed = await Supabase.instance.client.storage
        .from(bucket)
        .createSignedUrl(path, _ttl.inSeconds);

    // Renew slightly early to avoid edge-expiry misses
    _map[urlOrPath] = _SignedUrlEntry(
      signed,
      now.add(_ttl - const Duration(minutes: 2)),
    );
    return signed;
  }
}

class _SignedUrlEntry {
  _SignedUrlEntry(this.url, this.expires);
  final String url;
  final DateTime expires;
}

// ── Shared design tokens (file-wide)
const double _screenHPad = 10; // was 24 → fills more of the screen like UserProfilePage
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

  // Text/controllers
  final _name = TextEditingController();
  final _city = TextEditingController();
  final _bio = TextEditingController();
  final _loveLanguage = TextEditingController();
  final _communicationStyle = TextEditingController(); // persisted
  final _education = TextEditingController(); // persisted
  final _familyPlans = TextEditingController(); // persisted

  // Extra details (persisted)
  final _socialMedia = TextEditingController(); // persisted
  final _personalityType = TextEditingController(); // persisted

  String? _gender; // UI label: Male/Female/Other
  String? _sexualOrientation; // persisted
  DateTime? _dob;
  int? _heightCm; // persisted
  String? _zodiac; // persisted

  String? _workout; // persisted
  String? _dietary; // persisted
  String? _sleeping; // persisted

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

  // One-time prefill guard
  bool _prefilled = false;

  // Photo busy HUD (used for upload/delete outside the cropper dialog)
  bool _photoBusy = false;
  String _photoBusyMsg = 'Processing photo…';

  // Choices
  static const genders = ['Male', 'Female', 'Other'];
  static const sexualOrientationOptions = [
    'Straight',
    'Gay',
    'Lesbian',
    'Bisexual',
    'Asexual',
    'Queer',
    'Prefer not to say'
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
    'Gaming'
  ];
  static const goalOptions = [
    'Long-term',
    'Short-term',
    'Open to explore',
    'Marriage',
    'Friendship'
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
    'Portuguese'
  ];

  // Lifestyle
  static const petsOptions = [
    'No pets',
    'Cat person',
    'Dog person',
    'All the pets'
  ];
  static const drinkingOptions = [
    'Never',
    'On special occasions',
    'Socially',
    'Often'
  ];
  static const smokingOptions = [
    'Never',
    'Occasionally',
    'Smoker when drinking',
    'Regularly'
  ];

  // Extra info
  static const workoutOptions = ['Never', 'Sometimes', 'Often'];
  static const dietaryOptions = [
    'Omnivore',
    'Vegetarian',
    'Vegan',
    'Pescatarian',
    'Halal',
    'Kosher'
  ];
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
    'Pisces'
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

  @override
  void dispose() {
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
    // ── AUTH GUARD: if not logged in, don't watch providers or hit the network.
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

    // Now it's safe to read providers.
    final profileAsync = ref.watch(myProfileProvider);
    final p = profileAsync.value;

    // One-time prefill from existing profile
    if (!_prefilled && p != null) {
      _prefilled = true;
      _name.text = p.name ?? '';
      _city.text = p.currentCity ?? '';
      _bio.text = p.bio ?? '';
      _loveLanguage.text = p.loveLanguage ?? '';
      _communicationStyle.text = p.communicationStyle ?? '';
      _education.text = p.education ?? '';
      _familyPlans.text = p.familyPlans ?? '';
      _gender = _fromDbGender(p.gender);
      _dob = p.dateOfBirth;
      _pictures..clear()..addAll(p.profilePictures);
      _interests..clear()..addAll(p.interests);
      _relationshipGoals..clear()..addAll(p.relationshipGoals);
      _languages..clear()..addAll(p.languages);

      _drinking = p.drinking;
      _smoking = p.smoking;
      _pets = p.pets;

      _heightCm = p.heightCm;
      _zodiac = p.zodiacSign;
      _workout = p.workout;
      _dietary = p.dietaryPreference;
      _sleeping = p.sleepingHabits;
      _sexualOrientation = p.sexualOrientation;
      _socialMedia.text = p.socialMedia ?? '';
      _personalityType.text = p.personalityType ?? '';
    }

    return Scaffold(
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
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Failed to load profile: $e',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              ),
              data: (_) => Form(
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
                          _LabeledText('Name', _name, required: true),
                          const SizedBox(height: 12),
                          _Dropdown<String>(
                            label: 'Gender',
                            value: _gender,
                            items: genders,
                            onChanged: (v) => setState(() => _gender = v),
                          ),
                          const SizedBox(height: 12),
                          _Dropdown<String>(
                            label: 'Sexual orientation (optional)',
                            value: _sexualOrientation,
                            items: sexualOrientationOptions,
                            onChanged: (v) => setState(() => _sexualOrientation = v),
                          ),
                          const SizedBox(height: 12),
                          _DatePickerRow(
                            label: 'Date of birth',
                            value: _dob,
                            onPick: (d) => setState(() => _dob = d),
                          ),
                          const SizedBox(height: 12),
                          _LabeledText('Current city', _city),
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
                          _LabeledText('Short bio', _bio, maxLines: 4),
                          const SizedBox(height: 12),
                          _LabeledText('Love style (love language)', _loveLanguage),
                          const SizedBox(height: 12),
                          _LabeledText('Communication style', _communicationStyle),
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
                            onChanged: (v) => setState(() => _pets = v),
                            showLabel: false,
                          ),
                          const SizedBox(height: 10),

                          const _Subheading(icon: Icons.local_bar_rounded, text: 'Drinking'),
                          const SizedBox(height: 6),
                          _RadioRow(
                            label: '',
                            value: _drinking,
                            options: drinkingOptions,
                            onChanged: (v) => setState(() => _drinking = v),
                            showLabel: false,
                          ),
                          const SizedBox(height: 10),

                          const _Subheading(icon: Icons.smoke_free, text: 'Smoking'),
                          const SizedBox(height: 6),
                          _RadioRow(
                            label: '',
                            value: _smoking,
                            options: smokingOptions,
                            onChanged: (v) => setState(() => _smoking = v),
                            showLabel: false,
                          ),
                          const SizedBox(height: 10),

                          const _Subheading(icon: Icons.fitness_center, text: 'Workout'),
                          const SizedBox(height: 6),
                          _RadioRow(
                            label: '',
                            value: _workout,
                            options: workoutOptions,
                            onChanged: (v) => setState(() => _workout = v),
                            showLabel: false,
                          ),
                          const SizedBox(height: 10),

                          const _Subheading(icon: Icons.restaurant_menu, text: 'Dietary preference'),
                          const SizedBox(height: 6),
                          _RadioRow(
                            label: '',
                            value: _dietary,
                            options: dietaryOptions,
                            onChanged: (v) => setState(() => _dietary = v),
                            showLabel: false,
                          ),
                          const SizedBox(height: 10),

                          const _Subheading(icon: Icons.nightlight_round, text: 'Sleeping habits'),
                          const SizedBox(height: 6),
                          _RadioRow(
                            label: '',
                            value: _sleeping,
                            options: sleepingOptions,
                            onChanged: (v) => setState(() => _sleeping = v),
                            showLabel: false,
                          ),
                          const SizedBox(height: 12),

                          _LabeledText('Social media (handle / link)', _socialMedia),
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
                            onChanged: (v) => setState(() => _interests..clear()..addAll(v)),
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
                            onChanged: (v) => setState(() => _relationshipGoals..clear()..addAll(v)),
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
                            onChanged: (v) => setState(() => _languages..clear()..addAll(v)),
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
                          _LabeledText('Education', _education),
                          const SizedBox(height: 12),
                          _LabeledText('Family plans', _familyPlans),
                          const SizedBox(height: 12),
                          _NumberPickerRow(
                            label: 'Height (cm)',
                            value: _heightCm,
                            min: 120,
                            max: 220,
                            onChanged: (v) => setState(() => _heightCm = v),
                          ),
                          const SizedBox(height: 12),
                          _Dropdown<String>(
                            label: 'Zodiac (optional)',
                            value: _zodiac,
                            items: zodiacOptions,
                            onChanged: (v) => setState(() => _zodiac = v),
                          ),
                          const SizedBox(height: 12),
                          _LabeledText('Personality type (e.g., ENFJ)', _personalityType),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _saving ? null : _onSave,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.ffPrimary,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: _saving
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Save Changes', style: TextStyle(color: Colors.white, fontSize: 16)),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Busy HUD overlay (outside the cropper; used for upload/delete)
          if (_photoBusy)
            Positioned.fill(
              child: IgnorePointer(
                ignoring: false,
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
                            const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
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
    );
  }

  Future<void> _captureLocation() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever || perm == LocationPermission.denied) {
        _snack('Location permission denied', isError: true);
        return;
      }
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      setState(() => _location2 = [pos.latitude, pos.longitude]);
    } catch (e) {
      _snack('Failed to get location: $e', isError: true);
    }
  }

  // ---- Crop dialog (shows in-dialog progress + disabled buttons while cropping) ----
  Future<Uint8List?> _cropWithDialogPro(Uint8List srcBytes) async {
    final editorKey = GlobalKey<ExtendedImageEditorState>();
    final imgController = ImageEditorController();
    final canConfirm = ValueNotifier<bool>(false); // enabled after image loads
    Uint8List? result;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        const double aspect = 4 / 5; // enforce 4:5
        bool busy = false;

        return StatefulBuilder(
          builder: (ctx, setStateDialog) {
            Future<void> startCrop() async {
              final state = editorKey.currentState;
              if (state == null) return;
              setStateDialog(() => busy = true);
              try {
                final data = await _cropImageDataWithDartLibrary(state: state, quality: 92);
                result = data;
                await Future.delayed(const Duration(milliseconds: 120));
                if (ctx.mounted) Navigator.of(ctx).pop(); // close cropper dialog
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text('Crop failed: $e'), backgroundColor: Colors.red),
                  );
                }
                setStateDialog(() => busy = false);
              }
            }

            return Dialog(
              backgroundColor: AppTheme.ffPrimaryBg,
              insetPadding: const EdgeInsets.all(16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560, maxHeight: 780),
                child: Stack(
                  children: [
                    // Content
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              const Text('Edit photo',
                                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                              const Spacer(),
                              IconButton(
                                tooltip: 'Reset',
                                onPressed: busy
                                    ? null
                                    : () {
                                        imgController.reset();
                                        imgController.updateCropAspectRatio(aspect);
                                        HapticFeedback.lightImpact();
                                      },
                                icon: const Icon(Icons.restore, color: Colors.white70),
                              ),
                              IconButton(
                                tooltip: 'Rotate 90°',
                                onPressed: busy
                                    ? null
                                    : () {
                                        imgController.rotate();
                                        HapticFeedback.selectionClick();
                                      },
                                icon: const Icon(Icons.rotate_90_degrees_ccw, color: Colors.white70),
                              ),
                              IconButton(
                                tooltip: 'Flip',
                                onPressed: busy
                                    ? null
                                    : () {
                                        imgController.flip();
                                        HapticFeedback.selectionClick();
                                      },
                                icon: const Icon(Icons.flip, color: Colors.white70),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                color: Colors.black,
                                child: ExtendedImage.memory(
                                  srcBytes,
                                  fit: BoxFit.contain,
                                  mode: ExtendedImageMode.editor,
                                  filterQuality: FilterQuality.high,
                                  extendedImageEditorKey: editorKey,
                                  cacheRawData: true,
                                  // When the image is ready, enable the "Use photo" button.
                                  loadStateChanged: (state) {
                                    if (state.extendedImageLoadState == LoadState.completed) {
                                      if (!canConfirm.value) {
                                        WidgetsBinding.instance.addPostFrameCallback((_) {
                                          if (ctx.mounted) canConfirm.value = true;
                                        });
                                      }
                                    }
                                    return null;
                                  },
                                  initEditorConfigHandler: (state) {
                                    return EditorConfig(
                                      maxScale: 8.0,
                                      cropRectPadding: const EdgeInsets.all(16),
                                      hitTestSize: 24,
                                      lineColor: Colors.white70,
                                      editorMaskColorHandler: (context, down) =>
                                          Colors.black.withValues(alpha: down ? 0.45 : 0.6),
                                      cropAspectRatio: aspect,
                                      initCropRectType: InitCropRectType.imageRect,
                                      cropLayerPainter: const EditorCropLayerPainter(),
                                      controller: imgController,
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              const Spacer(),
                              TextButton(
                                onPressed: busy ? null : () => Navigator.of(ctx).pop(),
                                child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
                              ),
                              const SizedBox(width: 8),
                              ValueListenableBuilder<bool>(
                                valueListenable: canConfirm,
                                builder: (_, canUse, __) {
                                  final disabled = busy || !canUse;
                                  return FilledButton(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: disabled ? AppTheme.ffAlt : AppTheme.ffPrimary,
                                    ),
                                    onPressed: disabled ? null : () async => await startCrop(),
                                    child: disabled && busy
                                        ? const SizedBox(
                                            width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                        : const Text('Use photo', style: TextStyle(color: Colors.white)),
                                  );
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    // In-dialog blocking overlay during cropping
                    if (busy)
                      Positioned.fill(
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.45),
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              decoration: BoxDecoration(
                                color: AppTheme.ffPrimaryBg,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: AppTheme.ffAlt),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: const [
                                  SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                                  SizedBox(width: 10),
                                  Text('Cropping…', style: TextStyle(color: Colors.white)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    return result;
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
                    explicitLogicalWidth: mq.size.width, // helps compute cacheWidth
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
                            await ref.read(editProfileRepositoryProvider).setProfilePictures(
                                  userId: _meId(),
                                  urls: List<String>.from(_pictures),
                                );
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
    final xfile = await picker.pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (xfile == null) return;

    final originalBytes = await xfile.readAsBytes();
    final croppedBytes = await _cropWithDialogPro(originalBytes);
    if (croppedBytes == null) return;

    setState(() {
      _photoBusy = true;
      _photoBusyMsg = 'Uploading photo…';
    });

    final repo = ref.read(editProfileRepositoryProvider);
    try {
      String url;
      if (kIsWeb) {
        url = await repo.uploadProfileImage(userId: _meId(), filePath: xfile.name, bytes: croppedBytes);
      } else {
        var safeName = xfile.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
        if (safeName.length > 64) safeName = safeName.substring(safeName.length - 64);
        final fileName = 'p_${DateTime.now().millisecondsSinceEpoch}_$safeName';
        final tmpPath = await tempfs.saveBytesToTempFile(croppedBytes, fileName);
        url = await repo.uploadProfileImage(userId: _meId(), filePath: tmpPath);
      }
      setState(() {
        if (index >= 0 && index < _pictures.length) {
          _pictures[index] = url;
        } else if (_pictures.length < 6) {
          _pictures.add(url);
        }
      });
      await repo.setProfilePictures(userId: _meId(), urls: List<String>.from(_pictures));
    } catch (e) {
      _snack('Failed to upload photo: $e', isError: true);
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
    final xfile = await picker.pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (xfile == null) return;

    final originalBytes = await xfile.readAsBytes();
    final croppedBytes = await _cropWithDialogPro(originalBytes);
    if (croppedBytes == null) return; // canceled

    setState(() {
      _photoBusy = true;
      _photoBusyMsg = 'Uploading photo…';
    });

    final repo = ref.read(editProfileRepositoryProvider);
    try {
      String url;
      if (kIsWeb) {
        url = await repo.uploadProfileImage(
          userId: _meId(),
          filePath: xfile.name,
          bytes: croppedBytes,
        );
      } else {
        var safeName = xfile.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
        if (safeName.length > 64) safeName = safeName.substring(safeName.length - 64);
        final fileName = 'p_${DateTime.now().millisecondsSinceEpoch}_$safeName';
        final tmpPath = await tempfs.saveBytesToTempFile(croppedBytes, fileName);
        url = await repo.uploadProfileImage(
          userId: _meId(),
          filePath: tmpPath,
        );
      }
      setState(() => _pictures.add(url));
      await repo.setProfilePictures(userId: _meId(), urls: List<String>.from(_pictures));
    } catch (e) {
      _snack('Failed to upload photo: $e', isError: true);
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
        int a = now.year - d.year;
        if (now.month < d.month || (now.month == d.month && now.day < d.day)) {
          a--;
        }
        return a;
      }

      final map = <String, dynamic>{
        'user_id': me,
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

        // NEW FIELDS (persisted)
        'sexual_orientation': (_sexualOrientation?.isNotEmpty ?? false) ? _sexualOrientation : null,
        'height_cm': _heightCm,
        'zodiac_sign': _zodiac,
        'workout': _workout,
        'dietary_preference': _dietary,
        'sleeping_habits': _sleeping,
        'social_media': _socialMedia.text.trim().isEmpty ? null : _socialMedia.text.trim(),
        'personality_type': _personalityType.text.trim().isEmpty ? null : _personalityType.text.trim(),
      };

      final editRepo = ref.read(editProfileRepositoryProvider);
      final existing = await editRepo.fetchByUserId(me);
      if (existing == null) {
        await Supabase.instance.client.from('profiles').insert(map).select();
      } else {
        await Supabase.instance.client.from('profiles').update(map).eq('user_id', me).select();
      }

      ref.invalidate(myProfileProvider);
      if (mounted) context.go(UserProfileGate.routePath);
    } catch (e) {
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

  void _snack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.red : Colors.green,
    ));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Building blocks (styled to match the profile page)

class _Card extends StatelessWidget {
  const _Card({required this.child, required this.radius, required this.outline});
  final Widget child;
  final double radius;
  final Color outline;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color.fromARGB(255, 0, 0, 0), // match UserProfilePage card color
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
  const _LabeledText(this.label, this.controller, {this.maxLines = 1, this.required = false});
  final String label;
  final TextEditingController controller;
  final int maxLines;
  final bool required;

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
        fillColor: const Color(0xFF141414), // charcoal like UserProfilePage
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
          borderRadius: BorderRadius.circular(_radiusPill),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: AppTheme.ffPrimary), // pink unchanged
          borderRadius: BorderRadius.circular(_radiusPill),
        ),
      ),
      validator: required ? (v) => (v == null || v.trim().isEmpty) ? '$label is required' : null : null,
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
          dropdownColor: const Color(0xFF000000), // same black as cards
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
          selectedColor: AppTheme.ffPrimary.withValues(alpha: .55), // pink kept
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
              activeColor: AppTheme.ffPrimary, // pink kept
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
              selectedColor: AppTheme.ffPrimary.withValues(alpha: .6), // pink kept
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
              child: Text(
                value?.toString() ?? '—',
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
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
      crossAxisCount: 3,        // keep 3 columns
      childAspectRatio: 4 / 5,  // taller → visually larger tiles
      mainAxisSpacing: 6,       // a touch tighter than 8 to gain size
      crossAxisSpacing: 6,
      children: cells,
    );
  }
}

/// Optimized image that (1) resolves private storage paths to signed URLs,
/// (2) requests approximately display-sized bytes using cacheWidth.
class _SignedImage extends StatelessWidget {
  const _SignedImage({
    required this.rawUrlOrPath,
    required this.fit,
    this.explicitLogicalWidth,
    this.explicitCacheWidth,
  });

  final String rawUrlOrPath;
  final BoxFit fit;
  final double? explicitLogicalWidth; // optional logical width hint
  final int? explicitCacheWidth; // optional exact cacheWidth in device pixels

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final logicalW = explicitLogicalWidth ?? constraints.maxWidth;
      final cacheW = explicitCacheWidth ?? (logicalW.isFinite ? (logicalW * dpr).round() : null);

      return FutureBuilder<String>(
        future: _SignedUrlCache.resolve(rawUrlOrPath),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const _GridShimmer();
          }
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
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 1.8),
        ),
      ),
    );
    // (kept intentionally minimal to avoid extra animation cost in grids)
  }
}

// ----------------- Image crop helpers (dart library) -----------------
Future<Uint8List> _cropImageDataWithDartLibrary({
  required ExtendedImageEditorState state,
  int quality = 92,
}) async {
  final Rect? cropRect = state.getCropRect();
  final EditActionDetails action = state.editAction!;
  final Uint8List data = state.rawImageData;

  final map = <String, dynamic>{
    'bytes': data,
    'crop': cropRect == null
        ? null
        : {
            'x': cropRect.left.round(),
            'y': cropRect.top.round(),
            'w': cropRect.width.round(),
            'h': cropRect.height.round(),
          },
    // Use rotateDegrees for compatibility with your ExtendedImage version
    'rotate': action.rotateDegrees,
    'flipY': action.flipY,
    'quality': quality,
  };

  // Offload heavy work to an isolate for smoother UI
  return compute(_cropEncodeIsolate, map);
}

// Top-level isolate entry (must be top-level for `compute`)
Future<Uint8List> _cropEncodeIsolate(Map<String, dynamic> m) async {
  final Uint8List bytes = m['bytes'] as Uint8List;
  final Map<String, Object?>? crop = m['crop'] as Map<String, Object?>?;
  final double rotateDeg = (m['rotate'] as num?)?.toDouble() ?? 0.0;
  final bool flipY = (m['flipY'] as bool?) ?? false;
  final int qualityIn = (m['quality'] as int?) ?? 92;

  final img.Image? decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw Exception('Unsupported image format');
  }

  img.Image image = img.bakeOrientation(decoded);

  if (rotateDeg != 0) {
    image = img.copyRotate(image, angle: rotateDeg);
  }
  if (flipY) {
    image = img.flipHorizontal(image);
  }

  if (crop != null) {
    final int x = (crop['x'] as num).toInt().clamp(0, image.width - 1);
    final int y = (crop['y'] as num).toInt().clamp(0, image.height - 1);
    final int w = (crop['w'] as num).toInt().clamp(1, image.width - x);
    final int h = (crop['h'] as num).toInt().clamp(1, image.height - y);
    image = img.copyCrop(image, x: x, y: y, width: w, height: h);
  }

  final int q = qualityIn.clamp(1, 100);
  final List<int> jpg = img.encodeJpg(image, quality: q);
  return Uint8List.fromList(jpg);
}
