// lib/features/profile/pages/create_or_complete_profile_page.dart
// Drop-in page with completeness gate, missing-only flow, and fast-redirect.
// This version REQUIRES at least one language and a relationship goal.

import 'dart:async';
import 'dart:convert';
// ← needed for Uint8List

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:percent_indicator/percent_indicator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geocoding/geocoding.dart' as geocoding;
import 'package:http/http.dart' as http;
import 'package:flutter/painting.dart' as painting show PaintingBinding;
import 'package:extended_image/extended_image.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

import '../../../utils/write_temp_file_io.dart'
  if (dart.library.html) '../../../utils/write_temp_file_web.dart' as tempfs;

import '../../../theme/app_theme.dart';
import '../profile_repository.dart';
import '../edit_profile_repository.dart';
import '../../swipe/pages/test_swipe_stack_page.dart';

// -----------------------------------------------------------------------------
// PRIVATE (scoped to this file) completeness model + provider
// -----------------------------------------------------------------------------

enum _StepId {
  nameGender,       // name + gender
  interestedIn,     // preferences.interested_in_gender
  dob,              // date of birth (>=18)
  city,             // city or GPS location
  about,            // bio + love language
  interests,        // >=3
  goals,            // >=1
  languages,        // >=1
  photosAndPrefs,   // >=1 photo (+ prefs sanity)
}

class _ProfileCompletion {
  const _ProfileCompletion({required this.complete, required this.missing});
  final bool complete;
  final Set<_StepId> missing;
}

// Map RPC "missing" keys -> UI steps
const Map<String, _StepId> _rpcKeyToStep = {
  'nameGender': _StepId.nameGender,
  'interestedIn': _StepId.interestedIn,
  'dob': _StepId.dob,
  'city': _StepId.city,
  'about': _StepId.about,
  'interests': _StepId.interests,
  'goals': _StepId.goals,
  'languages': _StepId.languages,
  'photosAndPrefs': _StepId.photosAndPrefs,
};

final _completionProvider = FutureProvider<_ProfileCompletion>((ref) async {
  final client = Supabase.instance.client;
  final uid = client.auth.currentUser?.id;
  if (uid == null) throw Exception('Not authenticated');

  // FAST-PATH: check profiles.complete first (very cheap)
  final row = await client
      .from('profiles')
      .select('complete')
      .eq('user_id', uid)
      .maybeSingle();

  final isComplete = (row?['complete'] as bool?) ?? false;
  if (isComplete) {
    return const _ProfileCompletion(complete: true, missing: {});
  }

  // Not complete: ask DB to evaluate precisely (single RPC)
  final rpc = await client.rpc('evaluate_profile_completion', params: {'p_user_id': uid});

  // Supabase Dart can return either a List (rows) or a Map (single row)
  dynamic r;
  if (rpc is List && rpc.isNotEmpty) {
    r = rpc.first;
  } else if (rpc is Map) {
    r = rpc;
  } else {
    r = null;
  }

  final done = (r?['complete'] as bool?) ?? false;
  final rawMissing = (r?['missing'] as List?)?.whereType<String>().toList() ?? const <String>[];

  final mapped = <_StepId>{};
  for (final key in rawMissing) {
    final id = _rpcKeyToStep[key];
    if (id != null) mapped.add(id);
  }

  return _ProfileCompletion(complete: done, missing: mapped);
});

// -----------------------------------------------------------------------------
// Page
// -----------------------------------------------------------------------------
class CreateOrCompleteProfilePage extends ConsumerStatefulWidget {
  const CreateOrCompleteProfilePage({super.key});

  static const String routeName = 'createOrCompleteProfile';
  static const String routePath = '/create-or-complete-profile';

  @override
  ConsumerState<CreateOrCompleteProfilePage> createState() => _CreateOrCompleteProfilePageState();
}

class _CreateOrCompleteProfilePageState extends ConsumerState<CreateOrCompleteProfilePage> {
  // All possible steps
  late final List<_StepSpec> _allSteps;
  // Active steps (all or missing-only)
  List<_StepSpec> _activeSteps = const [];
  final _page = PageController();
  int _index = 0;

  final _name = TextEditingController();
  final _city = TextEditingController();
  final _bio = TextEditingController();
  final _loveLanguage = TextEditingController();

  String? _gender;        // "Male" | "Female" | "Other"
  String? _interestedIn;  // "Males" | "Females" | "Both"
  DateTime? _dob;

  final List<String?> _pictures = List<String?>.filled(6, null, growable: false);

  final _interests = <String>{};
  final _relationshipGoals = <String>{};
  final _languages = <String>{};

  RangeValues _ageRange = const RangeValues(21, 35);
  int _maxDistanceKm = 50;

  List<num>? _location2; // [lat, lng]
  bool _saving = false;
  bool _prefilled = false;
  bool _prefilledPrefs = false;

  bool _photoBusy = false;
  String _photoBusyMsg = 'Processing photo…';

  bool _snackLocked = false;

  static const genders = ['Male', 'Female', 'Other'];
  static const interestedInOptions = ['Males', 'Females', 'Both'];

  static const interestOptions = [
    'Travel','Music','Foodie','Art','Outdoors','Fitness','Movies','Reading','Gaming','Photography','Hiking','Dancing','Yoga','Cooking','Tech','Pets','Fashion','Coffee','Rugby','Soccer','Cycling','Running','Road Trips','Self-Improvement','Startups'
  ];
  static const goalOptions = [
    'Long-term','Short-term','Open to explore','Marriage','Friendship'
  ];
  static const languageOptions = [
    'English','Afrikaans','Zulu','Xhosa','Sotho','Tswana','Venda','Tsonga','Swati','Ndebele','French','Spanish','German','Italian','Portuguese'
  ];

  // Entry choice
  FlowStartChoice? _choice; // null -> show gate screen
  bool _redirectedToSwipe = false; // guard against repeat go()

  @override
  void initState() {
    super.initState();

    final cache = painting.PaintingBinding.instance.imageCache;
    cache.maximumSize = 300;
    cache.maximumSizeBytes = 120 << 20;

    _name.addListener(_onFieldChanged);

    _allSteps = [
      _StepSpec(_StepId.nameGender, "What's your first name?", _PlaceholderBuilder._name),
      _StepSpec(_StepId.interestedIn, 'I am interested in:', _PlaceholderBuilder._gender),
      _StepSpec(_StepId.dob, "When's your birthday?", _PlaceholderBuilder._dob),
      _StepSpec(_StepId.city, 'Where are you based?', _PlaceholderBuilder._city),
      _StepSpec(_StepId.about, 'About you', _PlaceholderBuilder._about),
      _StepSpec(_StepId.interests, 'Pick your interests', _PlaceholderBuilder._interests),
      _StepSpec(_StepId.goals, 'Relationship goals', _PlaceholderBuilder._goals),
      _StepSpec(_StepId.languages, 'Languages I can speak and understand:', _PlaceholderBuilder._languages),
      _StepSpec(_StepId.photosAndPrefs, 'Photos & preferences', _PlaceholderBuilder._photosAndPrefs),
    ];

    _activeSteps = List.of(_allSteps);
  }

  @override
  void dispose() {
    _name.removeListener(_onFieldChanged);
    _page.dispose();
    _name.dispose();
    _city.dispose();
    _bio.dispose();
    _loveLanguage.dispose();
    super.dispose();
  }

  String _meId() {
    final me = Supabase.instance.client.auth.currentUser?.id;
    if (me == null) throw Exception('Not authenticated');
    return me;
  }

  void _snack(String msg, {bool isError = false}) {
    if (!mounted || _snackLocked) return;
    _snackLocked = true;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          backgroundColor: isError ? Colors.red : Colors.green,
          duration: const Duration(seconds: 3),
        ),
      ).closed.whenComplete(() {
        if (mounted) _snackLocked = false;
      });
  }

  String? _mapDbGenderToUi(String? g) {
    switch ((g ?? '').toUpperCase()) {
      case 'M': return 'Male';
      case 'F': return 'Female';
      case 'O': return 'Other';
      default:  return g?.isEmpty ?? true ? null : g;
    }
  }
  String? _mapUiGenderToDb(String? g) {
    switch (g) {
      case 'Male': return 'M';
      case 'Female': return 'F';
      case 'Other': return 'O';
      default: return g;
    }
  }
  String? _mapInterestedInToDb(String? ui) {
    switch ((ui ?? '').toLowerCase()) {
      case 'males': return 'M';
      case 'females': return 'F';
      case 'both': return 'O';
      default: return ui?.isEmpty ?? true ? null : ui;
    }
  }
  String? _mapInterestedInFromDb(String? db) {
    switch ((db ?? '').toUpperCase()) {
      case 'M': return 'Males';
      case 'F': return 'Females';
      case 'O': return 'Both';
      default: return (db == null || db.isEmpty) ? null : db;
    }
  }

  void _prefillOnce(UserProfile? p) {
    if (_prefilled || p == null) return;
    _prefilled = true;
    _name.text = p.name ?? '';
    _city.text = p.currentCity ?? '';
    _bio.text = p.bio ?? '';
    _loveLanguage.text = p.loveLanguage ?? '';
    _gender = _mapDbGenderToUi(p.gender);
    _dob = p.dateOfBirth;

    final list = p.profilePictures;
    for (int i = 0; i < _pictures.length; i++) {
      _pictures[i] = i < list.length ? list[i] : null;
    }

    _interests..clear()..addAll(p.interests);
    _relationshipGoals..clear()..addAll(p.relationshipGoals);
    _languages..clear()..addAll(p.languages);
  }

  Future<void> _prefillInterestedIn() async {
    if (_prefilledPrefs) return;
    try {
      final me = _meId();
      final res = await Supabase.instance.client
          .from('preferences')
          .select('interested_in_gender, age_min, age_max, distance_radius')
          .eq('user_id', me)
          .maybeSingle();

      if (!mounted) return;
      if (res != null) {
        setState(() {
          _interestedIn = _mapInterestedInFromDb((res['interested_in_gender'] as String?)?.trim());
          final aMin = res['age_min'];
          final aMax = res['age_max'];
          if (aMin is int && aMax is int && aMin >= 18 && aMax >= aMin) {
            _ageRange = RangeValues(aMin.toDouble(), aMax.toDouble());
          }
          final dist = res['distance_radius'];
          if (dist is int && dist >= 1) _maxDistanceKm = dist;
          _prefilledPrefs = true;
        });
      } else {
        _prefilledPrefs = true;
      }
    } catch (_) {
      _prefilledPrefs = true;
    }
  }

  void _onFieldChanged() => setState(() {});

  static int ageFromDate(DateTime dob, {DateTime? now}) {
    final n = now ?? DateTime.now();
    var years = n.year - dob.year;
    final hadBirthday = (n.month > dob.month) || (n.month == dob.month && n.day >= dob.day);
    if (!hadBirthday) years -= 1;
    return years;
  }

  int _ageFrom(DateTime dob) => ageFromDate(dob);

  int? _firstOpenSlot() {
    for (int i = 0; i < _pictures.length; i++) {
      if (_pictures[i] == null) return i;
    }
    return null;
  }

  List<String> _nonNullPictures() => _pictures.whereType<String>().toList(growable: false);

  bool _canProceedForStep(_StepId id) {
    switch (id) {
      case _StepId.nameGender:
        return _name.text.trim().isNotEmpty && _gender != null;
      case _StepId.interestedIn:
        return _interestedIn != null;
      case _StepId.dob:
        return _dob != null && _ageFrom(_dob!) >= 18;
      case _StepId.city:
        return _city.text.trim().isNotEmpty || (_location2 != null && _location2!.length >= 2);
      case _StepId.about:
        return _bio.text.trim().isNotEmpty && _loveLanguage.text.trim().isNotEmpty;
      case _StepId.interests:
        return _interests.length >= 3;
      case _StepId.languages:
        return _languages.isNotEmpty;
      case _StepId.goals:
        return _relationshipGoals.isNotEmpty;
      case _StepId.photosAndPrefs:
        return _nonNullPictures().isNotEmpty;
    }
  }

  String? _blockReason(_StepId id) {
    switch (id) {
      case _StepId.nameGender: return 'Enter your name and select your gender to continue.';
      case _StepId.interestedIn: return 'Select who you’re interested in to continue.';
      case _StepId.dob: return 'Pick a valid date of birth (18+) to continue.';
      case _StepId.city: return 'Set your city or use your location to continue.';
      case _StepId.about: return 'Add a short bio and love language to continue.';
      case _StepId.interests: return 'Pick at least 3 interests to continue.';
      case _StepId.languages: return 'Select at least one language you speak to continue.';
      case _StepId.goals: return 'Select at least one relationship goal to continue.';
      case _StepId.photosAndPrefs: return 'Add at least 1 photo to continue.';
    }
  }

  bool _guardIndex(int i) {
    final id = _activeSteps[i].id;
    final ok = _canProceedForStep(id);
    if (!ok) {
      final reason = _blockReason(id);
      if (reason != null) _snack(reason, isError: true);
    }
    return ok;
  }

  Future<void> _putRowByUserId({required String table, required Map<String, dynamic> payloadWithUserId}) async {
    try {
      await Supabase.instance.client.from(table).upsert(payloadWithUserId, onConflict: 'user_id');
      return;
    } on PostgrestException catch (e) {
      if (e.code != '42P10') rethrow;
      final userId = payloadWithUserId['user_id'];
      final List updated = await Supabase.instance.client
          .from(table)
          .update(payloadWithUserId)
          .eq('user_id', userId)
          .select('user_id');
      if (updated.isEmpty) {
        await Supabase.instance.client.from(table).insert(payloadWithUserId);
      }
    }
  }

  Future<bool> _ensureGalleryPermission() async {
    if (kIsWeb) return true;

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final status = await Permission.photos.status;
      if (status.isGranted || status.isLimited) return true;
      final res = await Permission.photos.request();
      if (res.isGranted || res.isLimited) return true;
      if (res.isPermanentlyDenied || res.isRestricted) {
        _snack('Photo access is disabled. Enable it in Settings.', isError: true);
        await openAppSettings();
      } else {
        _snack('Photo access denied', isError: true);
      }
      return false;
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      final android = await DeviceInfoPlugin().androidInfo;
      final sdk = android.version.sdkInt;
      if (sdk >= 33) {
        return true;
      } else {
        final res = await Permission.storage.request();
        if (res.isGranted) return true;
        if (res.isPermanentlyDenied) {
          _snack('Storage permission disabled. Enable it in Settings.', isError: true);
          await openAppSettings();
        } else {
          _snack('Storage permission denied', isError: true);
        }
        return false;
      }
    }

    return true;
  }

  Future<bool> _ensureCameraPermission() async {
    if (kIsWeb) return true;
    final res = await Permission.camera.request();
    if (res.isGranted) return true;
    if (res.isPermanentlyDenied || res.isRestricted) {
      _snack('Camera permission disabled. Enable it in Settings.', isError: true);
      await openAppSettings();
    } else {
      _snack('Camera permission denied', isError: true);
    }
    return false;
  }

  Future<bool> _ensureLocationPermission() async {
    if (kIsWeb) return true;
    final serviceOn = await Geolocator.isLocationServiceEnabled();
    if (!serviceOn) {
      _snack('Please enable Location', isError: true);
      await Geolocator.openLocationSettings();
      return false;
    }

    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }

    if (perm == LocationPermission.deniedForever) {
      _snack('Location permission disabled. Enable it in Settings.', isError: true);
      await Geolocator.openAppSettings();
      return false;
    }
    if (perm == LocationPermission.denied) {
      _snack('Location permission denied', isError: true);
      return false;
    }

    return true;
  }

  Future<void> _captureLocation() async {
    try {
      final settings = const LocationSettings(
        accuracy: LocationAccuracy.low,
        timeLimit: Duration(seconds: 10),
      );
      final pos = await Geolocator.getCurrentPosition(locationSettings: settings);
      if (!mounted) return;
      setState(() => _location2 = [pos.latitude, pos.longitude]);

      bool setOk = false;
      try {
        final placemarks = await geocoding.placemarkFromCoordinates(pos.latitude, pos.longitude);
        String pick(List<String?> xs) {
          for (final s in xs) {
            if (s != null && s.trim().isNotEmpty) return s.trim();
          }
          return '';
        }
        if (placemarks.isNotEmpty) {
          final pm = placemarks.first;
          final city = pick([pm.locality, pm.subAdministrativeArea, pm.administrativeArea, pm.subLocality]);
          final country = pick([pm.country]);
          final parts = <String>[if (city.isNotEmpty) city, if (country.isNotEmpty) country];
          if (parts.isNotEmpty) {
            if (!mounted) return; setState(() => _city.text = parts.join(', '));
            setOk = true;
          }
        }
      } catch (_) {}

      if (!setOk) {
        final label = await _reverseGeocodeWeb(pos.latitude, pos.longitude);
        if (!mounted) return; setState(() => _city.text = label ?? 'Unknown');
      }
    } on TimeoutException {
      _snack('Location timed out. Try again near a window.', isError: true);
    } catch (e) {
      _snack('Failed to get location: $e', isError: true);
    }
  }

  Future<String?> _reverseGeocodeWeb(double lat, double lon) async {
    try {
      final uri = Uri.parse('https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=$lat&lon=$lon');
      final res = await http
          .get(
            uri,
            headers: const {
              'User-Agent': 'meetup-app/1.0 (reverse-geocode)',
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final data = json.decode(res.body) as Map<String, dynamic>;
        final addr = (data['address'] ?? {}) as Map<String, dynamic>;
        String pick(List<String?> xs) {
          for (final s in xs) {
            if (s != null && s.trim().isNotEmpty) return s.trim();
          }
          return '';
        }
        final city = pick([
          addr['city'] as String?,
          addr['town'] as String?,
          addr['village'] as String?,
          addr['municipality'] as String?,
          addr['county'] as String?,
          addr['state'] as String?,
        ]);
        final country = addr['country'] as String? ?? '';
        final parts = <String>[if (city.isNotEmpty) city, if (country.isNotEmpty) country];
        return parts.isEmpty ? null : parts.join(', ');
      }
    } catch (_) {}
    return null;
  }

  Future<Uint8List?> _cropWithDialogPro(Uint8List srcBytes) async {
    final editorKey = GlobalKey<ExtendedImageEditorState>();
    final imgController = ImageEditorController();
    final canConfirm = ValueNotifier<bool>(false);
    Uint8List? result;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        const double aspect = 4 / 5;
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
                if (ctx.mounted) Navigator.of(ctx).pop();
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
                                    onPressed: disabled ? null : () async => startCrop(),
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

  Future<ImageSource?> _choosePhotoSource() async {
    return showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: AppTheme.ffPrimaryBg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_camera),
                title: const Text('Take photo', style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Choose from gallery', style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<XFile?> _pickWithPermissions(ImageSource source) async {
    try {
      if (source == ImageSource.camera) {
        final ok = await _ensureCameraPermission();
        if (!ok) return null;
      } else {
        final ok = await _ensureGalleryPermission();
        if (!ok) return null;
      }

      final picker = ImagePicker();
      return await picker.pickImage(
        source: source,
        imageQuality: 96,
        maxWidth: 2048,
        maxHeight: 2048,
      );
    } on PlatformException catch (e) {
      _snack('Unable to open ${source == ImageSource.camera ? 'camera' : 'gallery'}: ${e.message ?? e.code}', isError: true);
      return null;
    } catch (e) {
      _snack('Failed to pick image: $e', isError: true);
      return null;
    }
  }

  Future<void> _onAddPhotoNextOpen() async {
    if (_nonNullPictures().length >= 6) {
      _snack('You can add up to 6 photos.');
      return;
    }

    final source = await _choosePhotoSource();
    if (source == null) return;

    final xfile = await _pickWithPermissions(source);
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
      final uid = _meId();

      String url;
      if (kIsWeb) {
        url = await repo.uploadProfileImage(userId: uid, filePath: xfile.name, bytes: croppedBytes);
      } else {
        var safeName = xfile.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
        if (safeName.length > 64) safeName = safeName.substring(safeName.length - 64);
        final fileName = 'p_${DateTime.now().millisecondsSinceEpoch}_$safeName';
        final tmpPath = await tempfs.saveBytesToTempFile(croppedBytes, fileName);
        url = await repo.uploadProfileImage(userId: uid, filePath: tmpPath);
      }

      final slot = _firstOpenSlot();
      if (slot == null) {
        _snack('You can add up to 6 photos.');
      } else {
        setState(() => _pictures[slot] = url);
        await repo.setProfilePictures(userId: uid, urls: _nonNullPictures());
      }
    } catch (e) {
      _snack('Failed to upload photo: $e', isError: true);
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  Future<void> _replacePhotoAtNonNullIndex(int nnIndex) async {
    final shown = _nonNullPictures();
    if (nnIndex < 0 || nnIndex >= shown.length) return;
    final oldUrl = shown[nnIndex];

    final source = await _choosePhotoSource();
    if (source == null) return;
    final xfile = await _pickWithPermissions(source);
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
      final uid = _meId();

      String url;
      if (kIsWeb) {
        url = await repo.uploadProfileImage(userId: uid, filePath: xfile.name, bytes: croppedBytes);
      } else {
        var safeName = xfile.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
        if (safeName.length > 64) safeName = safeName.substring(safeName.length - 64);
        final fileName = 'p_${DateTime.now().millisecondsSinceEpoch}_$safeName';
        final tmpPath = await tempfs.saveBytesToTempFile(croppedBytes, fileName);
        url = await repo.uploadProfileImage(userId: uid, filePath: tmpPath);
      }

      final slot = _pictures.indexOf(oldUrl);
      if (slot != -1) {
        setState(() => _pictures[slot] = url);
        await repo.setProfilePictures(userId: uid, urls: _nonNullPictures());
      }
    } catch (e) {
      _snack('Failed to upload photo: $e', isError: true);
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  Future<void> _deletePhotoAtNonNullIndex(int nnIndex) async {
    final shown = _nonNullPictures();
    if (nnIndex < 0 || nnIndex >= shown.length) return;
    final url = shown[nnIndex];

    await _withPhotoBusy('Deleting photo…', () async {
      final slot = _pictures.indexOf(url);
      if (slot != -1) {
        setState(() => _pictures[slot] = null);
        await ref.read(editProfileRepositoryProvider).setProfilePictures(
              userId: _meId(),
              urls: _nonNullPictures(),
            );
      }
    });
  }

  Future<void> _onSave() async {
    if (_name.text.trim().isEmpty) return _snack('Please enter your name', isError: true);
    if (_gender == null) return _snack('Please select your gender', isError: true);
    if (_dob == null || _ageFrom(_dob!) < 18) return _snack('You must be 18+ years old', isError: true);
    if (_city.text.trim().isEmpty && (_location2 == null || _location2!.length < 2)) {
      return _snack('Add your city or use your location', isError: true);
    }
    if (_bio.text.trim().isEmpty || _loveLanguage.text.trim().isEmpty) {
      return _snack('Please fill in your bio and love language', isError: true);
    }
    if (_interestedIn == null) return _snack('Select who you’re interested in', isError: true);
    if (_interests.length < 3) return _snack('Pick at least 3 interests', isError: true);
    if (_languages.isEmpty) return _snack('Select at least one language', isError: true);
    if (_relationshipGoals.isEmpty) return _snack('Select at least one relationship goal', isError: true);
    if (_nonNullPictures().isEmpty) return _snack('Please add at least one photo', isError: true);

    setState(() => _saving = true);
    HapticFeedback.lightImpact();
    try {
      final me = _meId();

      final update = ProfileUpdate(
        name: _name.text.trim(),
        gender: _mapUiGenderToDb(_gender),
        currentCity: _city.text.trim().isEmpty ? null : _city.text.trim(),
        bio: _bio.text.trim().isEmpty ? null : _bio.text.trim(),
        loveLanguage: _loveLanguage.text.trim().isEmpty ? null : _loveLanguage.text.trim(),
        dateOfBirth: _dob,
        profilePictures: _nonNullPictures(),
        interests: List<String>.from(_interests),
        relationshipGoals: List<String>.from(_relationshipGoals),
        myLanguages: List<String>.from(_languages),
      );

      final map = update.toMap();
      map['user_id'] = me;
      if (_location2 != null) map['location2'] = _location2;
      if (_dob != null) {
        map['age'] = _ageFrom(_dob!);
        final d = _dob!;
        map['date_of_birth'] = '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';
      }
      if (_city.text.trim().isNotEmpty) map['current_city'] = _city.text.trim();

      await _putRowByUserId(table: 'profiles', payloadWithUserId: map);

      final prefsPayload = {
        'user_id': me,
        'age_min': _ageRange.start.round(),
        'age_max': _ageRange.end.round(),
        'distance_radius': _maxDistanceKm,
        'interested_in_gender': _mapInterestedInToDb(_interestedIn),
      };

      await _putRowByUserId(table: 'preferences', payloadWithUserId: prefsPayload);

      ref.invalidate(myProfileProvider);
      ref.invalidate(_completionProvider);
      if (mounted) context.go(TestSwipeStackPage.routePath);
    } on AuthException catch (e) {
      _snack(e.message, isError: true);
    } catch (e) {
      _snack('Failed to save: $e', isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ----------------------------- BUILD --------------------------------------
  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;

    final profileAsync = ref.watch(myProfileProvider);
    final profile = profileAsync.valueOrNull;
    if (user != null) _prefillOnce(profile);
    if (user != null && !_prefilledPrefs) _prefillInterestedIn();

    final completionAsync = ref.watch(_completionProvider);

    if (completionAsync.isLoading) {
      return _GateScaffold(
        title: 'Checking your profile…',
        subtitle: 'We’re making sure everything’s ready.',
        child: const Padding(
          padding: EdgeInsets.only(top: 24),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (completionAsync.hasError) {
      return _GateScaffold(
        title: 'Couldn’t load your profile',
        subtitle: 'Please try again.',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => ref.refresh(_completionProvider),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final completion = completionAsync.value!;

    if (completion.complete) {
      if (!_redirectedToSwipe) {
        _redirectedToSwipe = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) context.go(TestSwipeStackPage.routePath);
        });
      }
      return _GateScaffold(
        title: 'All set! ✅',
        subtitle: 'Taking you to Discover…',
        child: const Padding(
          padding: EdgeInsets.only(top: 16),
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_choice == null) {
      return _GateScaffold(
        title: 'Your profile is not complete',
        subtitle: 'Complete your profile to start swiping.',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            _ChoiceButton(
              icon: Icons.playlist_add_check,
              label: 'Enter missing information',
              onTap: () {
                final missing = completion.missing;
                setState(() {
                  _choice = FlowStartChoice.missingOnly;
                  _activeSteps = _allSteps.where((s) => missing.contains(s.id)).toList(growable: false);
                  if (_activeSteps.isEmpty) {
                    _activeSteps = List.of(_allSteps);
                  }
                  _index = 0;
                });
                // Defer until PageView is in the tree
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  if (_page.hasClients) {
                    _page.jumpToPage(0);
                  }
                });
              },
            ),
            const SizedBox(height: 12),
            _ChoiceButton(
              icon: Icons.replay,
              label: 'Re-enter all information',
              onTap: () {
                setState(() {
                  _choice = FlowStartChoice.all;
                  _activeSteps = List.of(_allSteps);
                  _index = 0;
                });
                // Defer until PageView is in the tree
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  if (_page.hasClients) {
                    _page.jumpToPage(0);
                  }
                });
              },
            ),
          ],
        ),
      );
    }

    final media = MediaQuery.of(context);
    final total = _activeSteps.length.clamp(1, 999);
    final stepPercent = ((_index + 1) / total).clamp(0.0, 1.0);
    final showPrimary = _canProceedForStep(_activeSteps[_index].id);

    return GestureDetector(
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: Scaffold(
        backgroundColor: AppTheme.ffSecondaryBg,
        appBar: AppBar(
          backgroundColor: AppTheme.ffPrimaryBg,
          title: Text(_choice == FlowStartChoice.missingOnly ? 'Complete missing info' : 'Create your profile'),
          centerTitle: true,
        ),
        body: Stack(
          children: [
            SafeArea(
              bottom: true,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: LinearPercentIndicator(
                            lineHeight: 8,
                            barRadius: const Radius.circular(8),
                            animation: !media.accessibleNavigation,
                            percent: stepPercent,
                            animateFromLastPercent: true,
                            restartAnimation: false,
                            progressColor: AppTheme.ffPrimary,
                            backgroundColor: Colors.white10,
                            padding: EdgeInsets.zero,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text('${_index + 1}/$total', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppTheme.ffPrimaryBg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppTheme.ffAlt),
                        ),
                        child: PageView.builder(
                          controller: _page,
                          physics: const ClampingScrollPhysics(),
                          itemCount: _activeSteps.length,
                          onPageChanged: (i) {
                            final goingForward = i > _index;
                            if (goingForward && !_canProceedForStep(_activeSteps[_index].id)) {
                              _guardIndex(_index);
                              _page.animateToPage(
                                _index,
                                duration: const Duration(milliseconds: 180),
                                curve: Curves.easeOut,
                              );
                              return;
                            }
                            if (mounted) ScaffoldMessenger.of(context).clearSnackBars();
                            setState(() => _index = i);
                          },
                          itemBuilder: (context, i) => _activeSteps[i].builder(context, this),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _index == 0
                                ? null
                                : () async {
                                    await _page.previousPage(
                                      duration: const Duration(milliseconds: 220),
                                      curve: Curves.easeOut,
                                    );
                                    if (mounted) ScaffoldMessenger.of(context).clearSnackBars();
                                  },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.white24),
                              minimumSize: const Size.fromHeight(52),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              backgroundColor: Colors.transparent,
                            ),
                            child: const Text('Back'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 150),
                            child: showPrimary
                                ? ElevatedButton(
                                    key: const ValueKey('primary-visible'),
                                    onPressed: _saving
                                        ? null
                                        : () async {
                                            if (!_guardIndex(_index)) return;
                                            if (_index == _activeSteps.length - 1) {
                                              await _onSave();
                                            } else {
                                              await _page.nextPage(
                                                duration: const Duration(milliseconds: 220),
                                                curve: Curves.easeOut,
                                              );
                                              if (mounted) ScaffoldMessenger.of(context).clearSnackBars();
                                            }
                                          },
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppTheme.ffPrimary,
                                      minimumSize: const Size.fromHeight(52),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    ),
                                    child: _saving
                                        ? const SizedBox(
                                            height: 22,
                                            width: 22,
                                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                          )
                                        : const Text('Save & Continue',
                                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                                  )
                                : const SizedBox(
                                    key: ValueKey('primary-hidden'),
                                    height: 52,
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

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

  // ---------- Step builders ----------
  Widget _buildPadding({required Widget child}) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
        child: ScrollConfiguration(
          behavior: const _NoGlowScrollBehavior(),
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [child],
          ),
        ),
      );

  Widget _buildNameStep(BuildContext context) => _buildPadding(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _StepTitle("What's your first name?"),
            _LabeledText(label: 'First name', controller: _name, hint: 'Enter your first name', required: true),
            const SizedBox(height: 16),
            const _StepTitle('I am a:'),
            const SizedBox(height: 6),
            _ChoiceChips(
              options: genders,
              value: _gender,
              onChanged: (v) {
                HapticFeedback.selectionClick();
                setState(() => _gender = v);
              },
            ),
          ],
        ),
      );

  Widget _buildGenderStep(BuildContext context) => _buildPadding(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _StepTitle('I am interested in:'),
            _ChoiceChips(
              options: interestedInOptions,
              value: _interestedIn,
              onChanged: (v) {
                HapticFeedback.selectionClick();
                setState(() => _interestedIn = v);
              },
            ),
          ],
        ),
      );

  Widget _buildDobStep(BuildContext context) => _buildPadding(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _StepTitle("When's your birthday?"),
            _DatePickerRow(
              label: 'Date of birth',
              value: _dob,
              onPick: (d) => setState(() => _dob = d),
            ),
            const SizedBox(height: 8),
            const Text('You must be at least 18 years old.', style: TextStyle(color: Colors.white70)),
          ],
        ),
      );

  Widget _buildCityStep(BuildContext context) => _buildPadding(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _StepTitle('Where are you based?'),
            _LabeledText(label: 'City', controller: _city, hint: 'Type your city'),
            const SizedBox(height: 8),
            Wrap(spacing: 10, runSpacing: 8, children: [
              ElevatedButton.icon(
                onPressed: () async {
                  final ok = await _ensureLocationPermission();
                  if (!ok) return;
                  await _captureLocation();
                },
                icon: const Icon(Icons.my_location, size: 18, color: Colors.white),
                label: const Text('Use my location', style: TextStyle(color: Colors.white)),
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.ffPrimary, shape: const StadiumBorder()),
              ),
              if (_location2 != null) const Text('Location set ✓', style: TextStyle(color: Colors.white70)),
            ]),
          ],
        ),
      );

  Widget _buildAboutStep(BuildContext context) => _buildPadding(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _StepTitle('About you'),
            _LabeledText(label: 'Short bio', controller: _bio, hint: 'Tell people a little about you', maxLines: 4),
            const SizedBox(height: 12),
            _LabeledText(label: 'Love language', controller: _loveLanguage, hint: 'e.g. Quality Time'),
          ],
        ),
      );

  Widget _buildInterestsStep(BuildContext context) => _buildPadding(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _StepTitle('Pick your interests'),
            _ChipsSelector(
              options: interestOptions,
              values: _interests,
              onChanged: (next) => setState(() {
                _interests..clear()..addAll(next);
              }),
            ),
            const SizedBox(height: 10),
            const Text('Pick at least 3', style: TextStyle(color: Colors.white70)),
          ],
        ),
      );

  Widget _buildGoalsStep(BuildContext context) => _buildPadding(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _StepTitle('Relationship goals'),
            _ChipsSelector(
              options: goalOptions,
              values: _relationshipGoals,
              onChanged: (next) => setState(() {
                _relationshipGoals..clear()..addAll(next);
              }),
            ),
            const SizedBox(height: 8),
            const Text('Pick at least 1', style: TextStyle(color: Colors.white70)),
          ],
        ),
      );

  Widget _buildLanguagesStep(BuildContext context) => _buildPadding(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _StepTitle('I want to see matches who can speak:'),
            _CheckboxGroup(
              options: languageOptions,
              values: _languages,
              onChanged: (next) => setState(() {
                _languages..clear()..addAll(next);
              }),
            ),
            const SizedBox(height: 8),
            const Text('Pick at least 1', style: TextStyle(color: Colors.white70)),
          ],
        ),
      );

  Widget _buildPhotosAndPrefsStep(BuildContext context) => _buildPadding(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _StepTitle('Add your photos'),
            _EditStylePhotosGrid(
              pictures: _nonNullPictures(),
              onAdd: _onAddPhotoNextOpen,
              onTapImage: (i) => _openPhotoViewer(i),
            ),
            const SizedBox(height: 12),
            const Text('Tip: Add 3–6 clear photos for the best results.', style: TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 16),
            const _StepTitle('Preferences'),
            const SizedBox(height: 8),
            Text('Age range: ${_ageRange.start.round()} - ${_ageRange.end.round()}', style: const TextStyle(color: Colors.white)),
            RangeSlider(
              values: _ageRange,
              min: 18,
              max: 100,
              divisions: 82,
              labels: RangeLabels('${_ageRange.start.round()}', '${_ageRange.end.round()}'),
              activeColor: AppTheme.ffPrimary,
              onChanged: (v) => setState(() => _ageRange = v),
            ),
            const SizedBox(height: 8),
            Text('Max distance: $_maxDistanceKm km', style: const TextStyle(color: Colors.white)),
            Slider(
              value: _maxDistanceKm.toDouble(),
              min: 5,
              max: 200,
              divisions: 39,
              activeColor: AppTheme.ffPrimary,
              label: '$_maxDistanceKm km',
              onChanged: (v) => setState(() => _maxDistanceKm = v.round()),
            ),
          ],
        ),
      );

  Future<void> _openPhotoViewer(int indexInShown) async {
    final shown = _nonNullPictures();
    if (indexInShown < 0 || indexInShown >= shown.length) return;
    final url = shown[indexInShown];

    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'photo',
      barrierColor: Colors.black.withValues(alpha: 0.9),
      pageBuilder: (_, __, ___) {
        return Material(
          color: Colors.transparent,
          child: Stack(
            children: [
              Center(
                child: InteractiveViewer(
                  child: Image.network(
                    url,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.white70, size: 48),
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
                          await _replacePhotoAtNonNullIndex(indexInShown);
                        },
                      ),
                      const SizedBox(width: 8),
                      _pillButton(
                        icon: Icons.delete_outline,
                        label: 'Delete',
                        onTap: () async {
                          final nav = Navigator.of(context);
                          nav.pop();
                          await _deletePhotoAtNonNullIndex(indexInShown);
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

  @visibleForTesting
  Widget buildPhotosGridForTest({
    required List<String?> pictures,
    required ValueChanged<int> onAddAt,
    required VoidCallback onAddNextOpen,
    required ValueChanged<int> onRemoveAt,
  }) {
    return _EditStylePhotosGrid(
      pictures: pictures.whereType<String>().toList(),
      onAdd: onAddNextOpen,
      onTapImage: (_) {},
    );
  }
}

// ----------------- Small UI widgets -----------------
class _StepSpec {
  const _StepSpec(this.id, this.title, this.builder);
  final _StepId id;
  final String title;
  final Widget Function(BuildContext, _CreateOrCompleteProfilePageState) builder;
}

class _PlaceholderBuilder {
  const _PlaceholderBuilder._();
  static Widget _name(BuildContext c, _CreateOrCompleteProfilePageState s) => s._buildNameStep(c);
  static Widget _gender(BuildContext c, _CreateOrCompleteProfilePageState s) => s._buildGenderStep(c);
  static Widget _dob(BuildContext c, _CreateOrCompleteProfilePageState s) => s._buildDobStep(c);
  static Widget _city(BuildContext c, _CreateOrCompleteProfilePageState s) => s._buildCityStep(c);
  static Widget _about(BuildContext c, _CreateOrCompleteProfilePageState s) => s._buildAboutStep(c);
  static Widget _interests(BuildContext c, _CreateOrCompleteProfilePageState s) => s._buildInterestsStep(c);
  static Widget _goals(BuildContext c, _CreateOrCompleteProfilePageState s) => s._buildGoalsStep(c);
  static Widget _languages(BuildContext c, _CreateOrCompleteProfilePageState s) => s._buildLanguagesStep(c);
  static Widget _photosAndPrefs(BuildContext c, _CreateOrCompleteProfilePageState s) => s._buildPhotosAndPrefsStep(c);
}

class _StepTitle extends StatelessWidget {
  const _StepTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
      );
}

class _LabeledText extends StatelessWidget {
  const _LabeledText({
    required this.label,
    required this.controller,
    this.hint,
    this.maxLines = 1,
    this.required = false,
  });
  final String label;
  final String? hint;
  final TextEditingController controller;
  final int maxLines;
  final bool required;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      style: const TextStyle(color: Colors.white),
      textInputAction: maxLines == 1 ? TextInputAction.next : TextInputAction.newline,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: Colors.white70),
        hintStyle: const TextStyle(color: Colors.white54),
        filled: true,
        fillColor: AppTheme.ffPrimaryBg,
        enabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: Colors.white24),
          borderRadius: BorderRadius.circular(12),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: AppTheme.ffPrimary),
          borderRadius: BorderRadius.circular(12),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      validator: required ? (v) => (v == null || v.trim().isEmpty) ? '$label is required' : null : null,
    );
  }
}

class _ChoiceChips extends StatelessWidget {
  const _ChoiceChips({required this.options, required this.value, required this.onChanged});
  final List<String> options;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 10,
      children: options.map((opt) {
        final selected = value == opt;
        return ChoiceChip(
          label: Text(opt),
          selected: selected,
          onSelected: (_) => onChanged(selected ? null : opt),
          labelStyle: TextStyle(color: selected ? Colors.white : Colors.white70),
          selectedColor: AppTheme.ffPrimary.withValues(alpha: 0.6),
          backgroundColor: AppTheme.ffPrimaryBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          side: const BorderSide(color: Colors.white24),
        );
      }).toList(),
    );
  }
}

class _ChipsSelector extends StatelessWidget {
  const _ChipsSelector({required this.options, required this.values, required this.onChanged});
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
          selectedColor: AppTheme.ffPrimary.withValues(alpha: 0.6),
          backgroundColor: AppTheme.ffPrimaryBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          side: const BorderSide(color: Colors.white24),
        );
      }).toList(),
    );
  }
}

class _CheckboxGroup extends StatelessWidget {
  const _CheckboxGroup({required this.options, required this.values, required this.onChanged});
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
            Flexible(child: Text(opt, style: const TextStyle(color: Colors.white70), overflow: TextOverflow.ellipsis)),
          ]),
        );
      }).toList(),
    );
  }
}

class _EditStylePhotosGrid extends StatelessWidget {
  const _EditStylePhotosGrid({required this.pictures, required this.onAdd, required this.onTapImage});
  final List<String> pictures;
  final VoidCallback onAdd;
  final ValueChanged<int> onTapImage;

  @override
  Widget build(BuildContext context) {
    final shown = pictures.take(6).toList();

    final width = MediaQuery.of(context).size.width;
    final cols = width < 480 ? 2 : 3;

    final cells = <Widget>[
      for (int i = 0; i < shown.length; i++)
        InkWell(
          onTap: () => onTapImage(i),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(
              shown[i],
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const ColoredBox(
                color: Colors.black26,
                child: Center(child: Icon(Icons.broken_image)),
              ),
            ),
          ),
        ),
      if (shown.length < 6)
        InkWell(
          onTap: onAdd,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppTheme.ffPrimaryBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.ffAlt.withValues(alpha: .9)),
            ),
            child: const Center(child: Icon(Icons.add_a_photo_outlined, color: Colors.white70)),
          ),
        ),
    ];

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: cols,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: cells,
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
                  surface: AppTheme.ffSecondaryBg,
                  onSurface: Colors.white,
                ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(foregroundColor: AppTheme.ffPrimary),
            ),
            dialogTheme: DialogThemeData(backgroundColor: AppTheme.ffPrimaryBg),
          ),
          child: child!,
        ),
      );
      onPick(picked);
    }

    return InkWell(
      onTap: pick,
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white70),
          filled: true,
          fillColor: AppTheme.ffPrimaryBg,
          enabledBorder: OutlineInputBorder(
            borderSide: const BorderSide(color: Colors.white24),
            borderRadius: BorderRadius.circular(12),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: const BorderSide(color: AppTheme.ffPrimary),
            borderRadius: BorderRadius.circular(12),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
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

class _NoGlowScrollBehavior extends ScrollBehavior {
  const _NoGlowScrollBehavior();
  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) => child;
}

// ----------------- Image crop helpers -----------------
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
    'rotate': action.rotateDegrees,
    'flipY': action.flipY,
    'quality': quality,
  };

  return compute(_cropEncodeIsolate, map);
}

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

// ----------------- Gate UI bits -----------------
class _GateScaffold extends StatelessWidget {
  const _GateScaffold({required this.title, this.subtitle, required this.child});
  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.ffSecondaryBg,
      appBar: AppBar(
        backgroundColor: AppTheme.ffPrimaryBg,
        title: const Text('Profile'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.ffPrimaryBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.ffAlt),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                    if (subtitle != null) ...[
                      const SizedBox(height: 6),
                      Text(subtitle!, style: const TextStyle(color: Colors.white70)),
                    ],
                    const SizedBox(height: 14),
                    child,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChoiceButton extends StatelessWidget {
  const _ChoiceButton({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        icon: Icon(icon, color: Colors.white),
        label: Text(label, style: const TextStyle(color: Colors.white)),
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.ffPrimary,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }
}

enum FlowStartChoice { missingOnly, all }
