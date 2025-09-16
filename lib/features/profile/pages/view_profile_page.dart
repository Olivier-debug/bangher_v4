// -----------------------------------------------------------------------------
// file: lib/features/profile/pages/view_profile_page.dart
// Public profile page (offline-first). Uses PeerProfileCache + OfflineImage.
// Now shows a non-blocking top banner when the device is offline.
// -----------------------------------------------------------------------------

import 'dart:async' show StreamSubscription, unawaited;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart' as smooth_page_indicator;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../theme/app_theme.dart';
import '../../../widgets/offline_image.dart';
import '../../../core/cache/peer_profile_cache.dart';
import '../../../core/cache/pinned_image_cache.dart';

class ViewProfilePage extends StatefulWidget {
  const ViewProfilePage({super.key, required this.userId});
  final String userId;

  static const String routeName = 'viewProfile';
  static const String routePath = '/viewProfile';

  @override
  State<ViewProfilePage> createState() => _ViewProfilePageState();
}

class _ViewProfilePageState extends State<ViewProfilePage> {
  final _pageCtrl = PageController();

  // Design tokens
  static const double _screenHPad = 24; // match UserProfilePage
  static const double _radiusCard = 12;
  static const double _radiusPill = 10;
  static const double _chipMinHeight = 34;

  final SupabaseClient _supa = Supabase.instance.client;

  Map<String, dynamic>? _p; // profile row
  bool _loading = true;
  Object? _error;

  // Connectivity banner
  bool _isOffline = false;
  StreamSubscription<List<ConnectivityResult>>? _connSub;

  Color get _outline => AppTheme.ffAlt;

  @override
  void initState() {
    super.initState();
    _bootstrapConnectivity();
    _hydrateThenFetch();
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _connSub?.cancel();
    super.dispose();
  }

  // --- Connectivity helpers ---------------------------------------------------

  Future<void> _bootstrapConnectivity() async {
    final connectivity = Connectivity();

    // Initial state
    final initial = await connectivity.checkConnectivity();
    _isOffline = _allNone(initial);
    if (mounted) setState(() {});

    // Stream updates
    _connSub?.cancel();
    _connSub = connectivity.onConnectivityChanged.listen((results) {
      final nextOffline = _allNone(results);
      if (!mounted || nextOffline == _isOffline) return;
      setState(() => _isOffline = nextOffline);
    });
  }

  bool _allNone(dynamic v) {
    if (v is ConnectivityResult) return v == ConnectivityResult.none;
    if (v is List<ConnectivityResult>) {
      if (v.isEmpty) return true;
      return v.every((r) => r == ConnectivityResult.none);
    }
    return false;
  }

  // --- Data flow --------------------------------------------------------------

  Future<void> _hydrateThenFetch() async {
    // 1) Try local cache first (renders even if offline)
    final cached = await PeerProfileCache.instance.read(widget.userId);
    if (mounted && cached != null) {
      setState(() {
        _p = cached;
        _loading = false; // show immediately
        _error = null;
      });
      _warmPhotos();
    }

    // 2) Fetch from server; if newer, persist + update UI. Errors only matter if no cache.
    try {
      final row = await _supa
          .from('profiles')
          .select('*')
          .eq('user_id', widget.userId)
          .maybeSingle();
      if (row == null) throw Exception("Profile not found for userId: '${widget.userId}'");
      final raw = Map<String, dynamic>.from(row as Map);
      await PeerProfileCache.instance.write(widget.userId, raw);
      if (!mounted) return;
      setState(() {
        _p = raw;
        _loading = false;
        _error = null;
      });
      _warmPhotos();
    } catch (e) {
      if (!mounted) return;
      if (_p != null) return; // keep cached view, no error UI
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _warmPhotos() async {
    final photos = _photos();
    if (photos.isEmpty) return;
    // Best-effort pin; if offline, no-op.
    // Do not await to avoid blocking UI.
    unawaited(PinnedImageCache.instance.prefetchAll(photos, uid: widget.userId));
  }

  List<String> _photos() {
    final v = _p?['profile_pictures'];
    if (v is List) {
      return v.map((e) => e?.toString() ?? '').where((s) => s.isNotEmpty).toList();
    }
    return const <String>[];
  }

  String _genderLabel(String? raw) {
    if (raw == null) return '';
    final v = raw.trim();
    if (v.isEmpty) return '';
    switch (v.toUpperCase()) {
      case 'M':
        return 'Male';
      case 'F':
        return 'Female';
      case 'O':
        return 'Non-Binary';
      default:
        return v;
    }
  }

  // 1 → fully visible; 0 → collapsed during swipe
  double _overlayT() {
    if (!_pageCtrl.hasClients || !_pageCtrl.position.hasPixels) return 1;
    final page = _pageCtrl.page ?? 0.0;
    final frac = (page - page.round()).abs();
    final t = 1 - (frac * 2);
    return t.clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    Theme.of(context);

    // Cross-fade between: skeleton ↔ error ↔ loaded.
    Widget child;
    Key key;
    if (_loading) {
      child = _buildSkeletonScaffold();
      key = const ValueKey('profile-skeleton');
    } else if (_error != null && _p == null) {
      // only show error when nothing cached
      child = _buildErrorScaffold();
      key = const ValueKey('profile-error');
    } else {
      child = _buildLoadedScaffold(_p!);
      key = const ValueKey('profile-loaded');
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        children: <Widget>[
          ...previousChildren,
          if (currentChild != null) currentChild,
        ],
      ),
      transitionBuilder: (widget, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.02), end: Offset.zero).animate(animation),
          child: widget,
        ),
      ),
      child: KeyedSubtree(key: key, child: child),
    );
  }

  // ── Pages (kept visually identical, with banner overlays) -------------------

  Widget _buildErrorScaffold() {
    return Scaffold(
      backgroundColor: AppTheme.ffSecondaryBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('Profile', style: TextStyle(color: Colors.white)),
      ),
      body: Stack(
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isOffline ? Icons.wifi_off_rounded : Icons.error_outline,
                    color: Colors.white70,
                    size: 48,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _isOffline
                        ? 'You’re offline and no saved profile was found.'
                        : 'Failed to load profile',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.ffPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _hydrateThenFetch,
                    child: const Text('Retry', style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ),
          ),
          _bannerOverlay(),
        ],
      ),
    );
  }

  Widget _buildSkeletonScaffold() {
    return _SkeletonScaffold(
      outline: _outline,
      pageCtrl: _pageCtrl,
      screenHPad: _screenHPad,
      radiusCard: _radiusCard,
      radiusPill: _radiusPill,
      chipMinHeight: _chipMinHeight,
      banner: _bannerOverlay(),
    );
  }

  Widget _buildLoadedScaffold(Map<String, dynamic> p) {
    bool hasStr(String? s) => s != null && s.trim().isNotEmpty;
    bool hasList(List<dynamic>? l) => l != null && l.isNotEmpty;

    final List<String> photos = _photos();

    final List<String> interests = _toStrList(p['interests']);
    final List<String> goals = _toStrList(p['relationship_goals']);
    final List<String> languages = _toStrList(p['languages']);

    final String name = (p['name'] ?? 'Unknown').toString();
    final int? age = (p['age'] is int) ? p['age'] as int : int.tryParse('${p['age']}');

    final String gender = _genderLabel(p['gender']?.toString());
    final String? city = (p['current_city']?.toString());
    final String? bio = (p['bio']?.toString());

    final String? familyPlans = p['family_plans']?.toString();
    final String? loveLanguage = p['love_language']?.toString();
    final String? education = p['education']?.toString();
    final String? commStyle = p['communication_style']?.toString();

    final String? drinking = p['drinking']?.toString();
    final String? smoking = p['smoking']?.toString();
    final String? pets = p['pets']?.toString();
    final String? workout = p['workout']?.toString();
    final String? diet = p['dietary_preference']?.toString();
    final String? sleep = p['sleeping_habits']?.toString();

    return GestureDetector(
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: Scaffold(
        backgroundColor: AppTheme.ffSecondaryBg,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: const Text('Profile', style: TextStyle(color: Colors.white)),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              onPressed: _hydrateThenFetch,
              icon: const Icon(Icons.refresh, color: Colors.white70),
            ),
          ],
        ),
        body: Stack(
          children: [
            SafeArea(
              bottom: false,
              child: CustomScrollView(
                slivers: [
                  // Photos
                  if (photos.isNotEmpty)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 12),
                      sliver: SliverToBoxAdapter(
                        child: _Card(
                          radius: _radiusCard,
                          outline: _outline,
                          padding: EdgeInsets.zero,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(_radiusCard - 1),
                            child: Stack(
                              children: [
                                AspectRatio(
                                  aspectRatio: 4 / 5,
                                  child: ScrollConfiguration(
                                    behavior: const _DragScrollBehavior(),
                                    child: PageView.builder(
                                      physics: const PageScrollPhysics(),
                                      controller: _pageCtrl,
                                      itemCount: photos.length,
                                      itemBuilder: (context, i) {
                                        final url = photos[i];
                                        return GestureDetector(
                                          onTap: () {
                                            Navigator.of(context).push(
                                              PageRouteBuilder(
                                                pageBuilder: (_, __, ___) => _FullScreenGallery(
                                                  images: photos,
                                                  initialIndex: i,
                                                  ownerUid: widget.userId,
                                                ),
                                                transitionsBuilder: (_, anim, __, child) =>
                                                    FadeTransition(opacity: anim, child: child),
                                              ),
                                            );
                                          },
                                          child: Hero(
                                            tag: 'public_profile_photo_$i',
                                            child: OfflineImage.url(
                                              url: url,
                                              ownerUid: widget.userId,
                                              fit: BoxFit.cover,
                                              error: const ColoredBox(
                                                color: Colors.black26,
                                                child: Center(
                                                  child: Icon(Icons.broken_image, color: Colors.white38),
                                                ),
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ),
                                // Subtle gradient
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: DecoratedBox(
                                      decoration: const BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            Colors.transparent,
                                            Colors.black54,
                                            Colors.black87,
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                // FULL-WIDTH gray bar overlay with name/age
                                AnimatedBuilder(
                                  animation: _pageCtrl,
                                  builder: (context, _) {
                                    final t = _overlayT();
                                    return Positioned(
                                      left: 0,
                                      right: 0,
                                      bottom: 0,
                                      child: Opacity(
                                        opacity: t,
                                        child: Container(
                                          padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
                                          decoration: BoxDecoration(
                                            color: Colors.black.withValues(alpha: .42),
                                            border: Border(
                                              top: BorderSide(
                                                color: Colors.white.withValues(alpha: .12),
                                                width: 1,
                                              ),
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  age != null ? '$name ($age)' : name,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 18,
                                                    fontWeight: FontWeight.w700,
                                                    letterSpacing: .2,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              const Icon(Icons.verified_rounded,
                                                  color: AppTheme.ffPrimary, size: 18),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),

                                // pager dots
                                Positioned(
                                  top: 10,
                                  left: 0,
                                  right: 0,
                                  child: Center(
                                    child: smooth_page_indicator.SmoothPageIndicator(
                                      controller: _pageCtrl,
                                      count: photos.length,
                                      effect: const smooth_page_indicator.SlideEffect(
                                        spacing: 8,
                                        radius: 10,
                                        dotWidth: 22,
                                        dotHeight: 3,
                                        dotColor: Color(0x90FFFFFF),
                                        activeDotColor: Colors.white,
                                        paintStyle: PaintingStyle.fill,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                  // Basics
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 10),
                    sliver: SliverToBoxAdapter(
                      child: _Card(
                        radius: _radiusCard,
                        outline: _outline,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const _Heading(icon: Icons.badge_outlined, text: 'Basics'),
                            const SizedBox(height: 12),
                            if (hasStr(gender)) _RowIcon(icon: Icons.wc_rounded, text: gender),
                            if (hasStr(city)) ...[
                              const SizedBox(height: 8),
                              _RowIcon(icon: Icons.location_on_outlined, text: 'Lives in ${city!}'),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),

                  // About Me
                  if (hasStr(bio))
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 10),
                      sliver: SliverToBoxAdapter(
                        child: _Card(
                          radius: _radiusCard,
                          outline: _outline,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const _Heading(icon: Icons.info_outline, text: 'About Me'),
                              const SizedBox(height: 12),
                              _OutlinedBlock(
                                outline: _outline,
                                radius: _radiusPill,
                                child: Text(
                                  bio ?? '',
                                  style: const TextStyle(color: Colors.white70, height: 1.38),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  // Interests
                  if (hasList(interests))
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 10),
                      sliver: SliverToBoxAdapter(
                        child: _Card(
                          radius: _radiusCard,
                          outline: _outline,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const _Heading(icon: Icons.interests_outlined, text: 'Interests'),
                              const SizedBox(height: 10),
                              _PillsWrap(
                                items: interests,
                                outline: _outline,
                                radius: _radiusPill,
                                minHeight: _chipMinHeight,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  // Family Plans
                  if (hasStr(familyPlans))
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 10),
                      sliver: SliverToBoxAdapter(
                        child: _Card(
                          radius: _radiusCard,
                          outline: _outline,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const _Heading(icon: Icons.family_restroom_outlined, text: 'Family Plans'),
                              const SizedBox(height: 10),
                              _PillsWrap(
                                items: [familyPlans!],
                                outline: _outline,
                                radius: _radiusPill,
                                minHeight: _chipMinHeight,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  // Love Style
                  if (hasStr(loveLanguage))
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 10),
                      sliver: SliverToBoxAdapter(
                        child: _Card(
                          radius: _radiusCard,
                          outline: _outline,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const _Heading(icon: Icons.favorite_border, text: 'Love Style'),
                              const SizedBox(height: 10),
                              _PillsWrap(
                                items: [loveLanguage!],
                                outline: _outline,
                                radius: _radiusPill,
                                minHeight: _chipMinHeight,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  // Education
                  if (hasStr(education))
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 10),
                      sliver: SliverToBoxAdapter(
                        child: _Card(
                          radius: _radiusCard,
                          outline: _outline,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const _Heading(icon: Icons.school_outlined, text: 'Education'),
                              const SizedBox(height: 10),
                              _PillsWrap(
                                items: [education!],
                                outline: _outline,
                                radius: _radiusPill,
                                minHeight: _chipMinHeight,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  // Communication Style
                  if (hasStr(commStyle))
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 10),
                      sliver: SliverToBoxAdapter(
                        child: _Card(
                          radius: _radiusCard,
                          outline: _outline,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const _Heading(icon: Icons.chat_bubble_outline, text: 'Communication Style'),
                              const SizedBox(height: 10),
                              _PillsWrap(
                                items: [commStyle!],
                                outline: _outline,
                                radius: _radiusPill,
                                minHeight: _chipMinHeight,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  // Relationship Goal
                  if (hasList(goals))
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 10),
                      sliver: SliverToBoxAdapter(
                        child: _Card(
                          radius: _radiusCard,
                          outline: _outline,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const _Heading(icon: Icons.flag_outlined, text: 'Relationship Goal'),
                              const SizedBox(height: 10),
                              _PillsWrap(
                                items: goals,
                                outline: _outline,
                                radius: _radiusPill,
                                minHeight: _chipMinHeight,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  // Languages
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 10),
                    sliver: SliverToBoxAdapter(
                      child: _Card(
                        radius: _radiusCard,
                        outline: _outline,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const _Heading(icon: Icons.translate_outlined, text: 'Languages'),
                            const SizedBox(height: 10),
                            if (languages.isNotEmpty)
                              _PillsWrap(
                                items: languages,
                                outline: _outline,
                                radius: _radiusPill,
                                minHeight: _chipMinHeight,
                              )
                            else
                              _PillsWrap(
                                items: const ['Not specified'],
                                outline: _outline,
                                radius: _radiusPill,
                                minHeight: _chipMinHeight,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Lifestyle
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 24),
                    sliver: SliverToBoxAdapter(
                      child: _Card(
                        radius: _radiusCard,
                        outline: _outline,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const _Heading(icon: Icons.style_outlined, text: 'Lifestyle'),
                            const SizedBox(height: 12),

                            if (hasStr(drinking)) ...[
                              const _Subheading(icon: Icons.local_bar_rounded, text: 'Drinking'),
                              const SizedBox(height: 6),
                              _PillsWrap(
                                items: [drinking!],
                                outline: _outline,
                                radius: _radiusPill,
                                minHeight: _chipMinHeight,
                              ),
                              const SizedBox(height: 12),
                            ],
                            if (hasStr(smoking)) ...[
                              const _Subheading(icon: Icons.smoke_free, text: 'Smoking'),
                              const SizedBox(height: 6),
                              _PillsWrap(
                                items: [smoking!],
                                outline: _outline,
                                radius: _radiusPill,
                                minHeight: _chipMinHeight,
                              ),
                              const SizedBox(height: 12),
                            ],
                            if (hasStr(pets)) ...[
                              const _Subheading(icon: Icons.pets_outlined, text: 'Pets'),
                              const SizedBox(height: 6),
                              _PillsWrap(
                                items: [pets!],
                                outline: _outline,
                                radius: _radiusPill,
                                minHeight: _chipMinHeight,
                              ),
                              const SizedBox(height: 12),
                            ],
                            if (hasStr(workout)) ...[
                              const _Subheading(icon: Icons.fitness_center, text: 'Workout'),
                              const SizedBox(height: 6),
                              _PillsWrap(
                                items: [workout!],
                                outline: _outline,
                                radius: _radiusPill,
                                minHeight: _chipMinHeight,
                              ),
                              const SizedBox(height: 12),
                            ],
                            if (hasStr(diet)) ...[
                              const _Subheading(icon: Icons.restaurant_menu, text: 'Diet'),
                              const SizedBox(height: 6),
                              _PillsWrap(
                                items: [diet!],
                                outline: _outline,
                                radius: _radiusPill,
                                minHeight: _chipMinHeight,
                              ),
                              const SizedBox(height: 12),
                            ],
                            if (hasStr(sleep)) ...[
                              const _Subheading(icon: Icons.nightlight_round, text: 'Sleep'),
                              const SizedBox(height: 6),
                              _PillsWrap(
                                items: [sleep!],
                                outline: _outline,
                                radius: _radiusPill,
                                minHeight: _chipMinHeight,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _bannerOverlay(),
          ],
        ),
      ),
    );
  }

  // --- Top banner overlay -----------------------------------------------------

  Widget _bannerOverlay() {
    return IgnorePointer(
      ignoring: true, // banner is informational only
      child: SafeArea(
        top: true,
        bottom: false,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          offset: _isOffline ? Offset.zero : const Offset(0, -0.3),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            opacity: _isOffline ? 1 : 0,
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppTheme.ffPrimaryBg.withValues(alpha: .92),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _outline.withValues(alpha: .55)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.wifi_off_rounded, size: 16, color: Colors.white70),
                    SizedBox(width: 8),
                    Text(
                      'You’re offline — showing last saved profile',
                      style: TextStyle(color: Colors.white, fontSize: 12.5),
                    ),
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

// Web-friendly drag for PageView
class _DragScrollBehavior extends MaterialScrollBehavior {
  const _DragScrollBehavior();
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.unknown,
      };
}

// Building blocks (mirrored)
class _Card extends StatelessWidget {
  const _Card({required this.child, required this.radius, required this.outline, this.padding});
  final Widget child;
  final double radius;
  final Color outline;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.ffPrimaryBg,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: outline.withValues(alpha: .50), width: 1.2),
      ),
      child: Padding(padding: padding ?? const EdgeInsets.all(14), child: child),
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

class _RowIcon extends StatelessWidget {
  const _RowIcon({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppTheme.ffPrimary, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.25),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _OutlinedBlock extends StatelessWidget {
  const _OutlinedBlock({required this.child, required this.outline, required this.radius});
  final Widget child;
  final Color outline;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.ffPrimaryBg,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(width: 1, color: outline.withValues(alpha: .60)),
      ),
      padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 10),
      child: child,
    );
  }
}

List<String> _toStrList(dynamic v) {
  if (v is List) {
    return v.map((e) => e?.toString() ?? '').where((s) => s.trim().isNotEmpty).toList();
  }
  if (v is String && v.trim().isNotEmpty) return [v.trim()];
  return const <String>[];
}

class _PillsWrap extends StatelessWidget {
  const _PillsWrap({
    required this.items,
    required this.outline,
    required this.radius,
    required this.minHeight,
  });

  final List<String> items;
  final Color outline;
  final double radius;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: items.map((t) {
        return Container(
          constraints: BoxConstraints(minHeight: minHeight, maxWidth: 260),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: AppTheme.ffPrimaryBg,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: outline.withValues(alpha: .60), width: 1),
          ),
          child: Text(
            t,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, height: 1.1),
          ),
        );
      }).toList(),
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

// Fullscreen, pinch-to-zoom gallery (local-first)
class _FullScreenGallery extends StatefulWidget {
  const _FullScreenGallery({required this.images, required this.initialIndex, required this.ownerUid});
  final List<String> images;
  final int initialIndex;
  final String ownerUid;

  @override
  State<_FullScreenGallery> createState() => _FullScreenGalleryState();
}

class _FullScreenGalleryState extends State<_FullScreenGallery> {
  late final PageController _controller = PageController(initialPage: widget.initialIndex);
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.images.length;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: .2),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          '${_index + 1} / $total',
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
      ),
      body: Stack(
        children: [
          ScrollConfiguration(
            behavior: const _DragScrollBehavior(),
            child: PageView.builder(
              physics: const PageScrollPhysics(),
              controller: _controller,
              onPageChanged: (i) => setState(() => _index = i),
              itemCount: widget.images.length,
              itemBuilder: (_, i) {
                final url = widget.images[i];
                return Center(
                  child: Hero(
                    tag: 'public_profile_photo_$i',
                    child: InteractiveViewer(
                      minScale: 1.0,
                      maxScale: 4.0,
                      child: OfflineImage.url(
                        url: url,
                        ownerUid: widget.ownerUid,
                        fit: BoxFit.contain,
                        error: const Icon(Icons.broken_image, color: Colors.white38, size: 48),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Positioned(
            bottom: 24,
            left: 0,
            right: 0,
            child: Center(
              child: smooth_page_indicator.SmoothPageIndicator(
                controller: _controller,
                count: widget.images.length,
                effect: const smooth_page_indicator.WormEffect(
                  dotHeight: 6,
                  dotWidth: 6,
                  spacing: 6,
                  dotColor: Colors.white24,
                  activeDotColor: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Skeleton Loader (shimmer) — now accepts an optional banner overlay
// ─────────────────────────────────────────────────────────────────────────────
class _SkeletonScaffold extends StatelessWidget {
  const _SkeletonScaffold({
    required this.outline,
    required this.pageCtrl,
    required this.screenHPad,
    required this.radiusCard,
    required this.radiusPill,
    required this.chipMinHeight,
    this.banner,
  });

  final Color outline;
  final PageController pageCtrl;
  final double screenHPad;
  final double radiusCard;
  final double radiusPill;
  final double chipMinHeight;
  final Widget? banner;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.ffSecondaryBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('Profile', style: TextStyle(color: Colors.white)),
      ),
      body: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(screenHPad, 0, screenHPad, 12),
                  sliver: SliverToBoxAdapter(
                    child: _Card(
                      radius: radiusCard,
                      outline: outline,
                      padding: EdgeInsets.zero,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(radiusCard - 1),
                        child: Stack(
                          children: [
                            const AspectRatio(
                              aspectRatio: 4 / 5,
                              child: _ShimmerBox(),
                            ),
                            Positioned.fill(
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  decoration: const BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.transparent,
                                        Colors.black54,
                                        Colors.black87,
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: Container(
                                padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: .42),
                                  border: Border(
                                    top: BorderSide(color: Colors.white.withValues(alpha: .12), width: 1),
                                  ),
                                ),
                                child: Row(
                                  children: const [
                                    Expanded(
                                      child: _ShimmerLine(height: 18, widthFactor: .42),
                                    ),
                                    SizedBox(width: 6),
                                    _ShimmerDot(size: 18),
                                  ],
                                ),
                              ),
                            ),
                            Positioned(
                              top: 10,
                              left: 0,
                              right: 0,
                              child: Center(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: const [
                                    _ShimmerLine(height: 3, width: 60),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                SliverPadding(
                  padding: EdgeInsets.fromLTRB(screenHPad, 0, screenHPad, 10),
                  sliver: SliverToBoxAdapter(
                    child: _Card(
                      radius: radiusCard,
                      outline: outline,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          _Heading(icon: Icons.badge_outlined, text: 'Basics'),
                          SizedBox(height: 12),
                          _ShimmerRowIcon(),
                          SizedBox(height: 8),
                          _ShimmerRowIcon(),
                        ],
                      ),
                    ),
                  ),
                ),

                SliverPadding(
                  padding: EdgeInsets.fromLTRB(screenHPad, 0, screenHPad, 10),
                  sliver: SliverToBoxAdapter(
                    child: _Card(
                      radius: radiusCard,
                      outline: outline,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _Heading(icon: Icons.info_outline, text: 'About Me'),
                          const SizedBox(height: 12),
                          _OutlinedBlock(
                            outline: outline,
                            radius: radiusPill,
                            child: const _ShimmerParagraph(lines: 3),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                SliverPadding(
                  padding: EdgeInsets.fromLTRB(screenHPad, 0, screenHPad, 10),
                  sliver: SliverToBoxAdapter(
                    child: _Card(
                      radius: radiusCard,
                      outline: outline,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          _Heading(icon: Icons.interests_outlined, text: 'Interests'),
                          SizedBox(height: 10),
                          _ShimmerPills(count: 6),
                        ],
                      ),
                    ),
                  ),
                ),

                SliverPadding(
                  padding: EdgeInsets.fromLTRB(screenHPad, 0, screenHPad, 10),
                  sliver: SliverToBoxAdapter(
                    child: _Card(
                      radius: radiusCard,
                      outline: outline,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          _Heading(icon: Icons.translate_outlined, text: 'Languages'),
                          SizedBox(height: 10),
                          _ShimmerPills(count: 3),
                        ],
                      ),
                    ),
                  ),
                ),

                SliverPadding(
                  padding: EdgeInsets.fromLTRB(screenHPad, 0, screenHPad, 24),
                  sliver: SliverToBoxAdapter(
                    child: _Card(
                      radius: radiusCard,
                      outline: outline,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          _Heading(icon: Icons.style_outlined, text: 'Lifestyle'),
                          SizedBox(height: 12),
                          _ShimmerSubsection(),
                          SizedBox(height: 12),
                          _ShimmerSubsection(),
                          SizedBox(height: 12),
                          _ShimmerSubsection(),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (banner != null) banner!,
        ],
      ),
    );
  }
}

class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.child});
  final Widget child;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const Color base = Color(0xFF2A2C31);
    const Color highlight = Color(0xFF3A3D44);

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final t = _ctrl.value; // 0..1
        return ShaderMask(
          shaderCallback: (rect) {
            final dx = rect.width;
            final double x = (2 * dx) * t - dx;
            return const LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [base, highlight, base],
              stops: [0.35, 0.50, 0.65],
            ).createShader(Rect.fromLTWH(x, 0, dx, rect.height));
          },
          blendMode: BlendMode.srcATop,
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

class _ShimmerBox extends StatelessWidget {
  const _ShimmerBox({this.height, this.width, this.radius = 8});
  final double? height;
  final double? width;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return _Shimmer(
      child: Container(
        height: height,
        width: width,
        decoration: BoxDecoration(
          color: const Color(0xFF2A2C31),
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }
}

class _ShimmerLine extends StatelessWidget {
  const _ShimmerLine({required this.height, this.width, this.widthFactor});
  final double height;
  final double? width; // explicit px width
  final double? widthFactor; // fraction of available width

  @override
  Widget build(BuildContext context) {
    Widget box = _ShimmerBox(height: height, radius: 6);
    if (width != null) box = SizedBox(width: width, child: box);
    if (widthFactor != null) box = FractionallySizedBox(widthFactor: widthFactor, child: box);
    return box;
  }
}

class _ShimmerDot extends StatelessWidget {
  const _ShimmerDot({required this.size});
  final double size;
  @override
  Widget build(BuildContext context) {
    return _ShimmerBox(height: size, width: size, radius: size);
  }
}

class _ShimmerRowIcon extends StatelessWidget {
  const _ShimmerRowIcon();
  @override
  Widget build(BuildContext context) {
    return Row(
      children: const [
        _ShimmerDot(size: 18),
        SizedBox(width: 10),
        Expanded(child: _ShimmerLine(height: 14, widthFactor: .5)),
      ],
    );
  }
}

class _ShimmerParagraph extends StatelessWidget {
  const _ShimmerParagraph({this.lines = 3});
  final int lines;
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(lines, (i) {
        final last = i == lines - 1;
        return Padding(
          padding: EdgeInsets.only(bottom: last ? 0 : 8),
          child: _ShimmerLine(height: 12, widthFactor: last ? .6 : 1.0),
        );
      }),
    );
  }
}

class _ShimmerPills extends StatelessWidget {
  const _ShimmerPills({this.count = 5});
  final int count;
  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: List.generate(count, (i) {
        final w = 60 + (i * 12 % 100);
        return _ShimmerBox(height: 28, width: w.toDouble(), radius: 10);
      }),
    );
  }
}

class _ShimmerSubsection extends StatelessWidget {
  const _ShimmerSubsection();
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: const [
        _ShimmerRowIcon(),
        SizedBox(height: 6),
        _ShimmerPills(count: 2),
      ],
    );
  }
}
