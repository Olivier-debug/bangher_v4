// FILE: lib/features/profile/pages/create_or_complete_profile_page.dart
// Drop-in page with completeness gate, missing-only flow, fast-redirect.
// ✅ AUTH-SAFE guard
// ✅ Supabase signed URL resolver w/ TTL cache
// ✅ ExtendedImage crop dialog using ImageEditorController
// ✅ UI components unified to AppTheme
// ✅ Compatible with myProfileProvider (public surface)
// ✅ Router extras: fresh/start
// ✅ Offline-first: draft cache + robust fallback when RPC/network fails
// ✅ No use_build_context_synchronously

import 'dart:async';
import 'dart:convert';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/painting.dart' as painting;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geocoding/geocoding.dart' as geocoding;
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:percent_indicator/percent_indicator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../profile_guard.dart'
    show profileStatusListenableProvider, ProfileStatus;
import '../../../theme/app_theme.dart';
import '../../../utils/write_temp_file_io.dart'
    if (dart.library.html) '../../../utils/write_temp_file_web.dart' as tempfs;
import '../../swipe/pages/swipe_stack_page.dart';
import '../../profile/providers.dart' as profile_facade;
import '../edit_profile_repository.dart';
import '../../../widgets/photo_cropper_dialog.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Signed URL resolver (public URLs return immediately) with tiny TTL cache.
class _SignedUrlCache {
  static const Duration _ttl = Duration(minutes: 30);
  static final Map<String, _SignedUrlEntry> _map = {};

  static Future<String> resolve(String urlOrPath) async {
    if (urlOrPath.startsWith('http')) return urlOrPath;

    final now = DateTime.now();
    final hit = _map[urlOrPath];
    if (hit != null && now.isBefore(hit.expires)) return hit.url;

    final cleaned = urlOrPath.replaceFirst(RegExp(r'^storage://'), '');
    final slash = cleaned.indexOf('/');
    if (slash <= 0) {
      throw StateError('Invalid storage path: $urlOrPath');
    }
    final bucket = cleaned.substring(0, slash);
    final path = cleaned.substring(slash + 1);

    final signed = await Supabase.instance.client.storage
        .from(bucket)
        .createSignedUrl(path, _ttl.inSeconds);

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

class _SignedImage extends StatelessWidget {
  const _SignedImage({
    required this.rawUrlOrPath,
    required this.fit,
    this.explicitLogicalWidth,
    this.explicitCacheWidth,
  });

  final String rawUrlOrPath;
  final BoxFit fit;
  final double? explicitLogicalWidth;
  final int? explicitCacheWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final logicalW = explicitLogicalWidth ?? constraints.maxWidth;
      final cacheW =
          explicitCacheWidth ?? (logicalW.isFinite ? (logicalW * dpr).round() : null);

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
  }
}

// -----------------------------------------------------------------------------
// PRIVATE completeness model + provider
// -----------------------------------------------------------------------------
enum _StepId {
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

class _ProfileCompletion {
  const _ProfileCompletion({required this.complete, required this.missing});
  final bool complete;
  final Set<_StepId> missing;
}

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

  try {
    final row = await client
        .from('profiles')
        .select('complete')
        .eq('user_id', uid)
        .maybeSingle();

    final isComplete = (row?['complete'] as bool?) ?? false;
    if (isComplete) {
      return const _ProfileCompletion(complete: true, missing: {});
    }
  } catch (_) {
    // ignore; fall back to RPC/heuristic
  }

  try {
    final rpc =
        await client.rpc('evaluate_profile_completion', params: {'p_user_id': uid});

    dynamic r;
    if (rpc is List && rpc.isNotEmpty) {
      r = rpc.first;
    } else if (rpc is Map) {
      r = rpc;
    }

    final done = (r?['complete'] as bool?) ?? false;
    final rawMissing =
        (r?['missing'] as List?)?.whereType<String>().toList() ?? const <String>[];

    final mapped = <_StepId>{};
    for (final key in rawMissing) {
      final id = _rpcKeyToStep[key];
      if (id != null) mapped.add(id);
    }
    return _ProfileCompletion(complete: done, missing: mapped);
  } catch (_) {
    // Offline/failed → conservative heuristic: treat as incomplete + unknown missing
    return const _ProfileCompletion(complete: false, missing: {});
  }
});

// -----------------------------------------------------------------------------
// Page
// -----------------------------------------------------------------------------
const double _radiusPill = 10;

enum FlowStartChoice { missingOnly, all }

class CreateOrCompleteProfilePage extends ConsumerStatefulWidget {
  const CreateOrCompleteProfilePage({super.key, this.fresh = false});

  static const String routeName = 'createOrCompleteProfile';
  static const String routePath = '/create-or-complete-profile';

  final bool fresh;

  @override
  ConsumerState<CreateOrCompleteProfilePage> createState() =>
      _CreateOrCompleteProfilePageState();
}

class _CreateOrCompleteProfilePageState
    extends ConsumerState<CreateOrCompleteProfilePage> {
  static const bool _showDebugStorePeek = true;

  late final List<_StepSpec> _allSteps;
  List<_StepSpec> _activeSteps = const [];
  final _page = PageController();
  int _index = 0;

  final _name = TextEditingController();
  final _city = TextEditingController();
  final _bio = TextEditingController();
  final _loveLanguage = TextEditingController();

  String? _gender;
  String? _interestedIn;
  DateTime? _dob;

  final List<String?> _pictures = List<String?>.filled(6, null, growable: false);

  final _interests = <String>{};
  final _relationshipGoals = <String>{};
  final _languages = <String>{};

  RangeValues _ageRange = const RangeValues(21, 35);
  int _maxDistanceKm = 50;

  List<num>? _location2;
  late bool _saving = false;
  bool _prefilled = false;
  bool _prefilledPrefs = false;

  bool _photoBusy = false;
  String _photoBusyMsg = 'Processing photo…';

  bool _snackLocked = false;

  static const genders = ['Male', 'Female', 'Other'];
  static const interestedInOptions = ['Males', 'Females', 'Both'];

  static const interestOptions = [
    'Travel','Music','Foodie','Art','Outdoors','Fitness','Movies','Reading','Gaming',
    'Photography','Hiking','Dancing','Yoga','Cooking','Tech','Pets','Fashion','Coffee',
    'Rugby','Soccer','Cycling','Running','Road Trips','Self-Improvement','Startups'
  ];
  static const goalOptions = [
    'Long-term','Short-term','Open to explore','Marriage','Friendship'
  ];
  static const languageOptions = [
    'English','Afrikaans','Zulu','Xhosa','Sotho','Tswana','Venda','Tsonga',
    'Swati','Ndebele','French','Spanish','German','Italian','Portuguese'
  ];

  FlowStartChoice? _choice; // null -> show gate screen
  Set<_StepId> _serverMissing = const {};

  late final http.Client _http;
  StreamSubscription<AuthState>? _authSub;

  // Router extras (read once)
  bool _extrasApplied = false;

  // Draft persistence
  Timer? _draftDebounce;
  static const _draftKeyPrefix = 'profile_draft_';

  // UI ↔ DB mapping
  String? _mapInterestedInFromDb(String? db) {
    switch ((db ?? '').toUpperCase()) {
      case 'M': return 'Males';
      case 'F': return 'Females';
      case 'O':
      case '': return 'Both';
      default:  return 'Both';
    }
  }
  String? _mapInterestedInToDb(String? ui) {
    switch (ui) {
      case 'Males': return 'M';
      case 'Females': return 'F';
      case 'Both':
      default: return null;
    }
  }
  String? _mapUiGenderToDb(String? g) {
    switch (g) {
      case 'Male': return 'M';
      case 'Female': return 'F';
      case 'Other': return 'O';
      default: return null;
    }
  }
  String? _mapDbGenderToUi(String? g) {
    switch ((g ?? '').toUpperCase()) {
      case 'M': return 'Male';
      case 'F': return 'Female';
      case 'O': return 'Other';
      default:  return g?.isEmpty ?? true ? null : g;
    }
  }

  int ageFromDate(DateTime dob) {
    final now = DateTime.now();
    var years = now.year - dob.year;
    final hadBirthday = (now.month > dob.month) ||
        (now.month == dob.month && now.day >= dob.day);
    if (!hadBirthday) years -= 1;
    return years;
  }
  int _ageFrom(DateTime dob) => ageFromDate(dob);

  @override
  void initState() {
    super.initState();

    final cache = painting.PaintingBinding.instance.imageCache;
    cache.maximumSize = 300;
    cache.maximumSizeBytes = 120 << 20;

    _http = http.Client();

    _name.addListener(_onFieldChanged);
    _bio.addListener(_onFieldChanged);
    _loveLanguage.addListener(_onFieldChanged);
    _city.addListener(_onFieldChanged);

    _allSteps = [
      _StepSpec(_StepId.nameGender, "What's your first name?", _PlaceholderBuilder._name),
      _StepSpec(_StepId.interestedIn, 'I am interested in:', _PlaceholderBuilder._gender),
      _StepSpec(_StepId.dob, "When's your birthday?", _PlaceholderBuilder._dob),
      _StepSpec(_StepId.city, 'Where are you based?', _PlaceholderBuilder._city),
      _StepSpec(_StepId.about, 'About you', _PlaceholderBuilder._about),
      _StepSpec(_StepId.interests, 'Pick your interests', _PlaceholderBuilder._interests),
      _StepSpec(_StepId.goals, 'Relationship goals', _PlaceholderBuilder._goals),
      _StepSpec(_StepId.languages, 'Languages I can speak:', _PlaceholderBuilder._languages),
      _StepSpec(_StepId.photosAndPrefs, 'Photos & preferences', _PlaceholderBuilder._photosAndPrefs),
    ];

    _activeSteps = List.of(_allSteps);

    if (widget.fresh) {
      _clearAllProfileState();
      _choice = FlowStartChoice.all;
      _activeSteps = List.of(_allSteps);
      _index = 0;
    }

    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      final e = data.event;
      if (e == AuthChangeEvent.signedIn ||
          e == AuthChangeEvent.userUpdated ||
          e == AuthChangeEvent.signedOut) {
        _clearAllProfileState();
      }
    });

    _loadDraft(); // device-first
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_extrasApplied) return;
    _extrasApplied = true;

    // Read router extras once; never hold context across async.
    try {
      final extra = GoRouterState.of(context).extra;
      if (extra is Map) {
        final fresh = (extra['fresh'] is bool) ? extra['fresh'] as bool : false;
        if (fresh) {
          _choice = FlowStartChoice.all;
          _activeSteps = List.of(_allSteps);
        }
        final start = (extra['start'] is String)
            ? (extra['start'] as String).toLowerCase().trim()
            : null;
        if (start == 'all') {
          _choice = FlowStartChoice.all;
          _activeSteps = List.of(_allSteps);
        } else if (start == 'missing') {
          _choice = FlowStartChoice.missingOnly;
          _applyMissingFilterOnce();
        }
      }
      setState(() {});
    } catch (_) {/* ignore */}
  }

  @override
  void didUpdateWidget(covariant CreateOrCompleteProfilePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.fresh && widget.fresh) {
      _clearAllProfileState();
      setState(() {
        _choice = FlowStartChoice.all;
        _activeSteps = List.of(_allSteps);
        _index = 0;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _page.hasClients) _page.jumpToPage(0);
      });
    }
  }

  @override
  void dispose() {
    _draftDebounce?.cancel();

    _name.removeListener(_onFieldChanged);
    _bio.removeListener(_onFieldChanged);
    _loveLanguage.removeListener(_onFieldChanged);
    _city.removeListener(_onFieldChanged);

    _authSub?.cancel();
    _http.close();

    _page.dispose();
    _name.dispose();
    _city.dispose();
    _bio.dispose();
    _loveLanguage.dispose();
    super.dispose();
  }

  void _onFieldChanged() {
    if (mounted) setState(() {});
    _scheduleSaveDraft();
  }

  String _meId() {
    final me = Supabase.instance.client.auth.currentUser?.id;
    if (me == null) throw Exception('Not authenticated');
    return me;
  }

  // ────────────── DRAFT CACHE (device-first) ──────────────
  String get _draftKey => '$_draftKeyPrefix${_safeUid()}';
  String _safeUid() => Supabase.instance.client.auth.currentUser?.id ?? 'anon';

  void _scheduleSaveDraft() {
    _draftDebounce?.cancel();
    _draftDebounce = Timer(const Duration(milliseconds: 500), _saveDraft);
  }

  Future<void> _saveDraft() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final draft = {
        'name': _name.text,
        'city': _city.text,
        'bio': _bio.text,
        'love': _loveLanguage.text,
        'gender': _gender,
        'interestedIn': _interestedIn,
        'dob': _dob?.toIso8601String(),
        'pictures': _nonNullPictures(),
        'interests': _interests.toList(),
        'goals': _relationshipGoals.toList(),
        'languages': _languages.toList(),
        'ageMin': _ageRange.start.round(),
        'ageMax': _ageRange.end.round(),
        'dist': _maxDistanceKm,
        'loc2': _location2,
      };
      await sp.setString(_draftKey, jsonEncode(draft));
    } catch (_) {}
  }

  Future<void> _loadDraft() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_draftKey);
      if (raw == null) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _name.text = (m['name'] as String?) ?? _name.text;
        _city.text = (m['city'] as String?) ?? _city.text;
        _bio.text = (m['bio'] as String?) ?? _bio.text;
        _loveLanguage.text = (m['love'] as String?) ?? _loveLanguage.text;
        _gender = m['gender'] as String?;
        _interestedIn = m['interestedIn'] as String?;
        final dobStr = m['dob'] as String?;
        _dob = (dobStr != null) ? DateTime.tryParse(dobStr) : _dob;
        final pics = (m['pictures'] as List?)?.cast<String>() ?? const <String>[];
        for (var i = 0; i < _pictures.length; i++) {
          _pictures[i] = i < pics.length ? pics[i] : _pictures[i];
        }
        _interests
          ..clear()
          ..addAll(((m['interests'] as List?)?.cast<String>() ?? const <String>[]));
        _relationshipGoals
          ..clear()
          ..addAll(((m['goals'] as List?)?.cast<String>() ?? const <String>[]));
        _languages
          ..clear()
          ..addAll(((m['languages'] as List?)?.cast<String>() ?? const <String>[]));
        final aMin = (m['ageMin'] as num?)?.toDouble();
        final aMax = (m['ageMax'] as num?)?.toDouble();
        if (aMin != null && aMax != null) {
          _ageRange = RangeValues(aMin, aMax);
        }
        _maxDistanceKm = (m['dist'] as num?)?.toInt() ?? _maxDistanceKm;
        final loc = m['loc2'];
        if (loc is List && loc.length >= 2) {
          _location2 = [loc[0] as num, loc[1] as num];
        }
      });
    } catch (_) {}
  }

  void _clearAllProfileState() {
    _name.clear();
    _city.clear();
    _bio.clear();
    _loveLanguage.clear();
    _gender = null;
    _interestedIn = null;
    _dob = null;
    _location2 = null;

    for (var i = 0; i < _pictures.length; i++) {
      _pictures[i] = null;
    }
    _interests.clear();
    _relationshipGoals.clear();
    _languages.clear();

    _ageRange = const RangeValues(21, 35);
    _maxDistanceKm = 50;
    _prefilled = false;
    _prefilledPrefs = false;
    _index = 0;
    _serverMissing = const {};
    _choice = null;

    ref.invalidate(profile_facade.myProfileProvider);
    ref.invalidate(_completionProvider);

    ref.read(profileStatusListenableProvider).value = ProfileStatus.incomplete;

    if (mounted) setState(() {});
    _saveDraft(); // reset draft
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

  // Prefill from store (no network)
  void _prefillOnce(Map<String, dynamic>? p) {
    if (_prefilled || p == null) return;
    _prefilled = true;

    _name.text = p['name'] ?? _name.text;
    _bio.text = p['bio'] ?? _bio.text;
    _gender = _mapDbGenderToUi(p['gender']);

    final List<String> photos = p['profile_pictures'] ?? [];
    for (int i = 0; i < _pictures.length; i++) {
      _pictures[i] = i < photos.length ? photos[i] : _pictures[i];
    }
    _scheduleSaveDraft();
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
          _interestedIn =
              _mapInterestedInFromDb((res['interested_in_gender'] as String?)?.trim());
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
      _scheduleSaveDraft();
    } catch (_) {
      _prefilledPrefs = true; // offline-safe
    }
  }

  int? _firstOpenSlot() {
    for (int i = 0; i < _pictures.length; i++) {
      if (_pictures[i] == null) return i;
    }
    return null;
  }

  List<String> _nonNullPictures() =>
      _pictures.whereType<String>().toList(growable: false);

  Future<void> _putRowByUserId({
    required String table,
    required Map<String, dynamic> payloadWithUserId,
  }) async {
    final client = Supabase.instance.client;
    final userId = payloadWithUserId['user_id'];

    final updated = await client
        .from(table)
        .update(payloadWithUserId)
        .eq('user_id', userId)
        .select('user_id');
    if (updated.isNotEmpty) return;

    try {
      await client.from(table).insert(payloadWithUserId);
    } on PostgrestException catch (e) {
      if (e.code == '23505') return;
      rethrow;
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
        final placemarks = await geocoding.placemarkFromCoordinates(
            pos.latitude, pos.longitude);
        String pick(List<String?> xs) {
          for (final s in xs) {
            if (s != null && s.trim().isNotEmpty) return s.trim();
          }
          return '';
        }

        if (placemarks.isNotEmpty) {
          final pm = placemarks.first;
          final city = pick([
            pm.locality,
            pm.subAdministrativeArea,
            pm.administrativeArea,
            pm.subLocality
          ]);
          final country = pick([pm.country]);
          final parts = <String>[
            if (city.isNotEmpty) city,
            if (country.isNotEmpty) country
          ];
          if (parts.isNotEmpty) {
            if (!mounted) return;
            setState(() => _city.text = parts.join(', '));
            setOk = true;
          }
        }
      } catch (_) {}

      if (!setOk) {
        final label = await _reverseGeocodeWeb(pos.latitude, pos.longitude);
        if (!mounted) return;
        setState(() => _city.text = label ?? 'Unknown');
      }
      _scheduleSaveDraft();
    } on TimeoutException {
      _snack('Location timed out. Try again near a window.', isError: true);
    } catch (e) {
      _snack('Failed to get location: $e', isError: true);
    }
  }

  Future<String?> _reverseGeocodeWeb(double lat, double lon) async {
    try {
      final uri = Uri.parse(
          'https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=$lat&lon=$lon');
      final res = await _http
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
        final parts = <String>[
          if (city.isNotEmpty) city,
          if (country.isNotEmpty) country
        ];
        return parts.isEmpty ? null : parts.join(', ');
      }
    } catch (_) {}
    return null;
  }

  Widget _buildStorePeek(Map<String, dynamic>? p) {
    final photosCount = (p?['profile_pictures'] as List?)?.length ?? 0;
    final name = p?['name'] ?? '-';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.ffAlt),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.storage, size: 14, color: Colors.white70),
        const SizedBox(width: 6),
        Text('Store → name: $name | photos: $photosCount',
            style: const TextStyle(fontSize: 11, color: Colors.white70)),
        const SizedBox(width: 6),
        InkWell(
          onTap: () => ref.read(profile_facade.myProfileProvider.notifier).refresh(),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Icon(Icons.refresh, size: 14, color: Colors.white70),
          ),
        ),
      ]),
    );
  }

  Future<Uint8List?> _cropWithDialogPro(Uint8List srcBytes) async {
    return showProfilePhotoCropper(context, sourceBytes: srcBytes);
  }

  Future<ImageSource?> _choosePhotoSource() async {
    return showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: AppTheme.ffPrimaryBg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_camera, color: Colors.white),
                title: const Text('Take photo', style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library, color: Colors.white),
                title: const Text('Choose from gallery',
                    style: TextStyle(color: Colors.white)),
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
      _snack(
        'Unable to open ${source == ImageSource.camera ? 'camera' : 'gallery'}: ${e.message ?? e.code}',
        isError: true,
      );
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

    if (mounted) {
      setState(() {
        _photoBusy = true;
        _photoBusyMsg = 'Uploading photo…';
      });
    }

    final repo = EditProfileRepository(Supabase.instance.client);
    try {
      final uid = _meId();

      String url;
      if (kIsWeb) {
        url = await repo.uploadProfileImage(
            userId: uid, filePath: xfile.name, bytes: croppedBytes);
      } else {
        var safeName = xfile.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
        if (safeName.length > 64) {
          safeName = safeName.substring(safeName.length - 64);
        }
        final fileName = 'p_${DateTime.now().millisecondsSinceEpoch}_$safeName';
        final tmpPath = await tempfs.saveBytesToTempFile(croppedBytes, fileName);
        url = await repo.uploadProfileImage(
          userId: uid,
          filePath: tmpPath,
          bytes: croppedBytes,
        );
      }

      final slot = _firstOpenSlot();
      if (slot == null) {
        _snack('You can add up to 6 photos.');
      } else {
        if (mounted) setState(() => _pictures[slot] = url);
        await repo.setProfilePictures(userId: uid, urls: _nonNullPictures());
        ref.read(profile_facade.myProfileProvider.notifier).updateProfile({'profile_pictures': _nonNullPictures()});
      }
      _scheduleSaveDraft();
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

    if (mounted) {
      setState(() {
        _photoBusy = true;
        _photoBusyMsg = 'Uploading photo…';
      });
    }

    final repo = EditProfileRepository(Supabase.instance.client);
    try {
      final uid = _meId();

      String url;
      if (kIsWeb) {
        url = await repo.uploadProfileImage(
            userId: uid, filePath: xfile.name, bytes: croppedBytes);
      } else {
        var safeName = xfile.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
        if (safeName.length > 64) safeName = safeName.substring(safeName.length - 64);
        final fileName = 'p_${DateTime.now().millisecondsSinceEpoch}_$safeName';
        final tmpPath = await tempfs.saveBytesToTempFile(croppedBytes, fileName);
        url = await repo.uploadProfileImage(
          userId: uid,
          filePath: tmpPath,
          bytes: croppedBytes,
        );
      }

      final slot = _pictures.indexOf(oldUrl);
      if (slot != -1) {
        if (mounted) setState(() => _pictures[slot] = url);
        await repo.setProfilePictures(userId: uid, urls: _nonNullPictures());
        ref.read(profile_facade.myProfileProvider.notifier).updateProfile({'profile_pictures': _nonNullPictures()});
      }
      _scheduleSaveDraft();
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
        if (mounted) setState(() => _pictures[slot] = null);
        await EditProfileRepository(Supabase.instance.client).setProfilePictures(
          userId: _meId(),
          urls: _nonNullPictures(),
      );
      }
      _scheduleSaveDraft();
    });
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

  @override
  Widget build(BuildContext context) {
    // AUTH GUARD
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      final router = GoRouter.of(context);
      return Scaffold(
        backgroundColor: AppTheme.ffSecondaryBg,
        appBar: AppBar(
          backgroundColor: AppTheme.ffPrimaryBg,
          title: const Text('Profile'),
          centerTitle: true,
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
                    'Please sign in to create your profile',
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
                    onPressed: () => router.go('/auth'),
                    child: const Text('Sign in', style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // Safe to read providers; prefill
    final profileState = ref.watch(profile_facade.myProfileProvider);
    if (!widget.fresh) _prefillOnce(profileState.valueOrNull);
    if (!widget.fresh && !_prefilledPrefs) _prefillInterestedIn();

    // Only run the completeness gate when NOT fresh.
    if (!widget.fresh) {
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
          subtitle: 'Working offline. You can still continue.',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => ref.refresh(_completionProvider),
                child: const Text('Retry'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => setState(() => _choice ??= FlowStartChoice.all),
                child: const Text('Continue anyway'),
              ),
            ],
          ),
        );
      }

      if (completionAsync.hasValue) {
        final completion = completionAsync.value!;
        _serverMissing = completion.missing;

        if (completion.complete) {
          final router = GoRouter.of(context);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              router.replace(TestSwipeStackPage.routePath);
            }
          });
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
          return _buildStartChoice(completion.missing);
        }

        if (_choice == FlowStartChoice.missingOnly) {
          _applyMissingFilterOnce();
        } else {
          _activeSteps = List.of(_allSteps);
        }
      }
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
          title: Text(_choice == FlowStartChoice.missingOnly
              ? 'Complete missing info'
              : 'Create your profile'),
          centerTitle: true,
          actions: _showDebugStorePeek
              ? [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _buildStorePeek(
                      ref.watch(profile_facade.myProfileProvider).valueOrNull,
                    ),
                  )
                ]
              : null,
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
                        Text('${_index + 1}/$total',
                            style: const TextStyle(
                                color: Colors.white, fontWeight: FontWeight.w600)),
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
                          onPageChanged: (i) {
                            final goingForward = i > _index;
                            if (goingForward &&
                                !_canProceedForStep(_activeSteps[_index].id)) {
                              _guardIndex(_index);
                              _page.animateToPage(
                                _index,
                                duration: const Duration(milliseconds: 180),
                                curve: Curves.easeOut,
                              );
                              return;
                            }
                            if (mounted) {
                              ScaffoldMessenger.of(context).clearSnackBars();
                            }
                            setState(() => _index = i);
                          },
                          itemBuilder: (context, i) =>
                              _activeSteps[i].builder(context, this),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: _FooterButtons(
                      canGoBack: _index > 0,
                      onBack: () async {
                        await _page.previousPage(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut,
                        );
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).clearSnackBars();
                      },
                      primaryEnabled: showPrimary && !_saving,
                      saving: _saving,
                      onPrimary: () async {
                        if (!_guardIndex(_index)) return;
                        if (_index == _activeSteps.length - 1) {
                          await _onSave();
                        } else {
                          await _page.nextPage(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOut,
                          );
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).clearSnackBars();
                        }
                      },
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
                              const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2)),
                              const SizedBox(width: 10),
                              Text(_photoBusyMsg,
                                  style: const TextStyle(color: Colors.white)),
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

  // ─────────────────────────── Choice Gate ───────────────────────────
  Widget _buildStartChoice(Set<_StepId> missing) {
    return _GateScaffold(
      title: 'Finish your profile',
      subtitle: 'Choose how you want to proceed.',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (missing.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: missing.map((m) => Chip(label: Text(_pretty(m)))).toList(),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    setState(() {
                      _choice = FlowStartChoice.all;
                      _activeSteps = List.of(_allSteps);
                      _index = 0;
                    });
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(_radiusPill)),
                  ),
                  child: const Text('Re-enter ALL'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () {
                    setState(() {
                      _choice = FlowStartChoice.missingOnly;
                      _applyMissingFilterOnce();
                      _index = 0;
                    });
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.ffPrimary,
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(_radiusPill)),
                  ),
                  child: const Text('Finish MISSING only'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _applyMissingFilterOnce() {
    if (_serverMissing.isEmpty) {
      _activeSteps = List.of(_allSteps);
      return;
    }
    final ids = _serverMissing;
    _activeSteps = _allSteps.where((s) => ids.contains(s.id)).toList();
    if (_activeSteps.isEmpty) {
      _activeSteps = List.of(_allSteps);
    }
  }

  String _pretty(_StepId s) {
    switch (s) {
      case _StepId.nameGender: return 'Name & gender';
      case _StepId.interestedIn: return 'Interested in';
      case _StepId.dob: return 'Date of birth';
      case _StepId.city: return 'City / Location';
      case _StepId.about: return 'About me';
      case _StepId.interests: return 'Interests';
      case _StepId.goals: return 'Relationship goals';
      case _StepId.languages: return 'Languages';
      case _StepId.photosAndPrefs: return 'Photos & Prefs';
    }
  }

  // ───────────────────────── Validation / Save ───────────────────────
  bool _canProceedForStep(_StepId id) {
    switch (id) {
      case _StepId.nameGender:
        return _name.text.trim().isNotEmpty && _gender != null;
      case _StepId.interestedIn:
        return _interestedIn != null;
      case _StepId.dob:
        return _dob != null && _ageFrom(_dob!) >= 18;
      case _StepId.city:
        return _city.text.trim().isNotEmpty ||
            (_location2 != null && _location2!.length >= 2);
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

  Set<_StepId> get _activeStepIds => _activeSteps.map((e) => e.id).toSet();

  Future<_ProfileCompletion> _recheckCompletionWithFallback() async {
    try {
      return await ref.refresh(_completionProvider.future);
    } catch (_) {
      // Heuristic fallback when offline: treat as incomplete if any criticals missing locally
      final missing = <_StepId>{};
      if (_name.text.trim().isEmpty || _gender == null) missing.add(_StepId.nameGender);
      if (_interestedIn == null) missing.add(_StepId.interestedIn);
      if (_dob == null || _ageFrom(_dob!) < 18) missing.add(_StepId.dob);
      if (_city.text.trim().isEmpty && (_location2 == null || _location2!.length < 2)) {
        missing.add(_StepId.city);
      }
      if (_bio.text.trim().isEmpty || _loveLanguage.text.trim().isEmpty) {
        missing.add(_StepId.about);
      }
      if (_interests.length < 3) missing.add(_StepId.interests);
      if (_languages.isEmpty) missing.add(_StepId.languages);
      if (_relationshipGoals.isEmpty) missing.add(_StepId.goals);
      if (_nonNullPictures().isEmpty) missing.add(_StepId.photosAndPrefs);
      return _ProfileCompletion(complete: missing.isEmpty, missing: missing);
    }
  }

  Future<void> _onSave() async {
    // Validate only active steps.
    for (final step in _activeSteps) {
      if (!_canProceedForStep(step.id)) {
        final reason = _blockReason(step.id) ?? 'Please complete this step';
        _snack(reason, isError: true);
        return;
      }
    }

    setState(() => _saving = true);
    HapticFeedback.lightImpact();
    final router = GoRouter.of(context); // capture BEFORE any await
    try {
      final me = _meId();
      final ids = _activeStepIds;

      final profileMap = <String, dynamic>{'user_id': me};

      if (ids.contains(_StepId.nameGender)) {
        profileMap['name'] = _name.text.trim();
        profileMap['gender'] = _mapUiGenderToDb(_gender);
      }
      if (ids.contains(_StepId.city)) {
        final city = _city.text.trim();
        if (city.isNotEmpty) profileMap['current_city'] = city;
        if (_location2 != null) profileMap['location2'] = _location2;
      }
      if (ids.contains(_StepId.about)) {
        final bio = _bio.text.trim();
        final love = _loveLanguage.text.trim();
        if (bio.isNotEmpty) profileMap['bio'] = bio;
        if (love.isNotEmpty) profileMap['love_language'] = love;
      }
      if (ids.contains(_StepId.dob)) {
        if (_dob != null) {
          profileMap['date_of_birth'] =
              '${_dob!.year}-${_dob!.month.toString().padLeft(2, '0')}-${_dob!.day.toString().padLeft(2, '0')}';
          profileMap['age'] = _ageFrom(_dob!);
        }
      }
      if (ids.contains(_StepId.interests)) {
        profileMap['interests'] = List<String>.from(_interests);
      }
      if (ids.contains(_StepId.goals)) {
        profileMap['relationship_goals'] = List<String>.from(_relationshipGoals);
      }
      if (ids.contains(_StepId.languages)) {
        profileMap['my_languages'] = List<String>.from(_languages);
      }
      if (ids.contains(_StepId.photosAndPrefs)) {
        profileMap['profile_pictures'] = _nonNullPictures();
      }

      // Optimistic local update BEFORE remote
      ref.read(profile_facade.myProfileProvider.notifier).updateProfile(profileMap);

      // Upsert partial profile
      await _putRowByUserId(table: 'profiles', payloadWithUserId: profileMap);

      // Preferences payload
      if (ids.contains(_StepId.interestedIn) || ids.contains(_StepId.photosAndPrefs)) {
        final prefsPayload = <String, dynamic>{'user_id': me};
        if (ids.contains(_StepId.interestedIn)) {
          prefsPayload['interested_in_gender'] = _mapInterestedInToDb(_interestedIn);
        }
        if (ids.contains(_StepId.photosAndPrefs)) {
          prefsPayload['age_min'] = _ageRange.start.round();
          prefsPayload['age_max'] = _ageRange.end.round();
          prefsPayload['distance_radius'] = _maxDistanceKm;
        }
        if (prefsPayload.length > 1) {
          await _putRowByUserId(table: 'preferences', payloadWithUserId: prefsPayload);
        }
      }

      // Re-evaluate completion (RPC) with heuristic fallback when offline.
      final latest = await _recheckCompletionWithFallback();
      ref.invalidate(profile_facade.myProfileProvider);

      if (latest.complete) {
        ref.read(profileStatusListenableProvider).value = ProfileStatus.complete;
        _saveDraft(); // keep last draft; harmless
        if (mounted) router.go(TestSwipeStackPage.routePath);
      } else {
        ref.read(profileStatusListenableProvider).value = ProfileStatus.incomplete;
        if (mounted) {
          _snack('Saved. Keep going to finish your profile.');
          _serverMissing = latest.missing;
          if (_choice == FlowStartChoice.missingOnly) {
            setState(_applyMissingFilterOnce);
          }
        }
      }
    } on AuthException catch (e) {
      _snack(e.message, isError: true);
    } catch (e) {
      // Offline save failure: keep draft locally
      _snack('Saved locally. Will sync when online.', isError: false);
      await _saveDraft();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
            _InputText(
                label: 'First name',
                controller: _name,
                hint: 'Enter your first name',
                required: true),
            const SizedBox(height: 16),
            const _StepTitle('I am a:'),
            const SizedBox(height: 6),
            _ChoiceChips(
              options: genders,
              value: _gender,
              onChanged: (v) {
                HapticFeedback.selectionClick();
                setState(() => _gender = v);
                _scheduleSaveDraft();
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
                _scheduleSaveDraft();
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
              onPick: (d) {
                setState(() => _dob = d);
                _scheduleSaveDraft();
              },
            ),
            const SizedBox(height: 8),
            const Text('You must be at least 18 years old.',
                style: TextStyle(color: Colors.white70)),
          ],
        ),
      );

  Widget _buildCityStep(BuildContext context) => _buildPadding(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _StepTitle('Where are you based?'),
            _InputText(label: 'City', controller: _city, hint: 'Type your city'),
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
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.ffPrimary, shape: const StadiumBorder()),
              ),
              if (_location2 != null)
                const Text('Location set ✓', style: TextStyle(color: Colors.white70)),
            ]),
          ],
        ),
      );

  Widget _buildAboutStep(BuildContext context) => _buildPadding(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _StepTitle('About you'),
            _InputText(
                label: 'Short bio',
                controller: _bio,
                hint: 'Tell people a little about you',
                maxLines: 4),
            const SizedBox(height: 12),
            _InputText(
                label: 'Love language',
                controller: _loveLanguage,
                hint: 'e.g. Quality Time'),
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
              onChanged: (next) {
                setState(() {
                  _interests
                    ..clear()
                    ..addAll(next);
                });
                _scheduleSaveDraft();
              },
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
              onChanged: (next) {
                setState(() {
                  _relationshipGoals
                    ..clear()
                    ..addAll(next);
                });
                _scheduleSaveDraft();
              },
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
            const _StepTitle('Languages I can speak:'),
            _CheckboxGroup(
              options: languageOptions,
              values: _languages,
              onChanged: (next) {
                setState(() {
                  _languages
                    ..clear()
                    ..addAll(next);
                });
                _scheduleSaveDraft();
              },
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
            const Text('Tip: Add 3–6 clear photos for the best results.',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 16),
            const _StepTitle('Preferences'),
            const SizedBox(height: 8),
            Text('Age range: ${_ageRange.start.round()} - ${_ageRange.end.round()}',
                style: const TextStyle(color: Colors.white)),
            RangeSlider(
              values: _ageRange,
              min: 18,
              max: 100,
              divisions: 82,
              labels: RangeLabels('${_ageRange.start.round()}',
                  '${_ageRange.end.round()}'),
              activeColor: AppTheme.ffPrimary,
              onChanged: (v) => setState(() => _ageRange = v),
            ),
            const SizedBox(height: 8),
            Text('Max distance: $_maxDistanceKm km',
                style: const TextStyle(color: Colors.white)),
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
    final raw = shown[indexInShown];

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
                      _pillButton(
                          icon: Icons.close,
                          label: 'Close',
                          onTap: () => Navigator.of(context).pop()),
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

  Widget _pillButton(
      {required IconData icon,
      required String label,
      required VoidCallback onTap}) {
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
  static Widget _name(BuildContext c, _CreateOrCompleteProfilePageState s) =>
      s._buildNameStep(c);
  static Widget _gender(BuildContext c, _CreateOrCompleteProfilePageState s) =>
      s._buildGenderStep(c);
  static Widget _dob(BuildContext c, _CreateOrCompleteProfilePageState s) =>
      s._buildDobStep(c);
  static Widget _city(BuildContext c, _CreateOrCompleteProfilePageState s) =>
      s._buildCityStep(c);
  static Widget _about(BuildContext c, _CreateOrCompleteProfilePageState s) =>
      s._buildAboutStep(c);
  static Widget _interests(BuildContext c, _CreateOrCompleteProfilePageState s) =>
      s._buildInterestsStep(c);
  static Widget _goals(BuildContext c, _CreateOrCompleteProfilePageState s) =>
      s._buildGoalsStep(c);
  static Widget _languages(BuildContext c, _CreateOrCompleteProfilePageState s) =>
      s._buildLanguagesStep(c);
  static Widget _photosAndPrefs(BuildContext c, _CreateOrCompleteProfilePageState s) =>
      s._buildPhotosAndPrefsStep(c);
}

class _StepTitle extends StatelessWidget {
  const _StepTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(text,
            style: const TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
      );
}

class _InputText extends StatelessWidget {
  const _InputText({
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
        fillColor: const Color(0xFF141414),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
          borderRadius: BorderRadius.circular(_radiusPill),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: AppTheme.ffPrimary),
          borderRadius: BorderRadius.circular(_radiusPill),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      validator: required
          ? (v) => (v == null || v.trim().isEmpty) ? '$label is required' : null
          : null,
    );
  }
}

class _ChoiceChips extends StatelessWidget {
  const _ChoiceChips(
      {required this.options, required this.value, required this.onChanged});
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
          backgroundColor: const Color(0xFF141414),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_radiusPill)),
          side: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
        );
      }).toList(),
    );
  }
}

class _ChipsSelector extends StatelessWidget {
  const _ChipsSelector(
      {required this.options, required this.values, required this.onChanged});
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
          backgroundColor: const Color(0xFF141414),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_radiusPill)),
          side: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
        );
      }).toList(),
    );
  }
}

class _CheckboxGroup extends StatelessWidget {
  const _CheckboxGroup(
      {required this.options, required this.values, required this.onChanged});
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
            Flexible(
                child: Text(opt,
                    style: const TextStyle(color: Colors.white70),
                    overflow: TextOverflow.ellipsis)),
          ]),
        );
      }).toList(),
    );
  }
}

class _EditStylePhotosGrid extends StatelessWidget {
  const _EditStylePhotosGrid(
      {required this.pictures, required this.onAdd, required this.onTapImage});
  final List<String> pictures;
  final VoidCallback onAdd;
  final ValueChanged<int> onTapImage;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final cols = width < 480 ? 2 : 3;

    final cells = <Widget>[
      for (int i = 0; i < pictures.length; i++)
        InkWell(
          onTap: () => onTapImage(i),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: _SignedImage(rawUrlOrPath: pictures[i], fit: BoxFit.cover),
          ),
        ),
      if (pictures.length < 6)
        InkWell(
          onTap: onAdd,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF141414),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.ffAlt.withValues(alpha: .60)),
            ),
            child: const Center(
                child: Icon(Icons.add_a_photo_outlined, color: Colors.white70)),
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
                  surface: const Color(0xFF000000),
                  onSurface: Colors.white,
                ),
            textButtonTheme:
                TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: AppTheme.ffPrimary)),
            dialogTheme: const DialogThemeData(backgroundColor: Color(0xFF000000)),
          ),
          child: child!,
        ),
      );
      onPick(picked);
    }

    return InkWell(
      onTap: pick,
      borderRadius: BorderRadius.circular(_radiusPill),
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
  Widget buildOverscrollIndicator(
          BuildContext context, Widget child, ScrollableDetails details) =>
      child;
}

// Footer buttons
class _FooterButtons extends StatelessWidget {
  const _FooterButtons({
    required this.canGoBack,
    required this.onBack,
    required this.primaryEnabled,
    required this.saving,
    required this.onPrimary,
  });

  final bool canGoBack;
  final VoidCallback onBack;
  final bool primaryEnabled;
  final bool saving;
  final VoidCallback onPrimary;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: canGoBack ? onBack : null,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(_radiusPill)),
              backgroundColor: Colors.transparent,
            ),
            child: const Text('Back'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: primaryEnabled
                ? ElevatedButton(
                    key: const ValueKey('primary-visible'),
                    onPressed: saving ? null : onPrimary,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.ffPrimary,
                      minimumSize: const Size.fromHeight(52),
                      shape:
                          RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radiusPill)),
                    ),
                    child: saving
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
    );
  }
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
                    Text(title,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
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