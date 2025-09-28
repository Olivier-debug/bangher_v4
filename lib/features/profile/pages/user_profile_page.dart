import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart' as smooth_page_indicator;
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../theme/app_theme.dart';
import '../../profile/application/providers.dart'; // exposes myProfileProvider

// ──────────────────────────────────────────────────────────────
// Signed URL resolver (public URLs return immediately) with tiny TTL cache.

class _SignedUrlCache {
  static const Duration _ttl = Duration(minutes: 30);
  static const int _cap = 200; // simple size cap to avoid unbounded growth
  static final Map<String, _SignedUrlEntry> _map = {};

  static Future<String> resolve(String urlOrPath) async {
    try {
      if (urlOrPath.startsWith('http')) return urlOrPath; // already public

      final now = DateTime.now();
      final hit = _map[urlOrPath];
      if (hit != null && now.isBefore(hit.expires)) return hit.url;

      // Accept "bucket/path/to/file.jpg" or "storage://bucket/path..."
      final cleaned = urlOrPath.replaceFirst(RegExp(r'^storage://'), '');
      final i = cleaned.indexOf('/');
      if (i <= 0) return urlOrPath; // fail-soft: return original string
      final bucket = cleaned.substring(0, i);
      final path = cleaned.substring(i + 1);

      final signed = await Supabase.instance.client.storage
          .from(bucket)
          .createSignedUrl(path, _ttl.inSeconds);

      // Renew slightly early to avoid edge-expiry misses
      final expires = now.add(_ttl - const Duration(minutes: 2));
      _map[urlOrPath] = _SignedUrlEntry(signed, expires);

      // trim cache (FIFO-ish based on insertion order)
      if (_map.length > _cap) {
        _map.remove(_map.keys.first);
      }

      return signed;
    } catch (_) {
      // Avoid throwing into FutureBuilder → return original string as best-effort.
      return urlOrPath;
    }
  }
}

class _SignedUrlEntry {
  _SignedUrlEntry(this.url, this.expires);
  final String url;
  final DateTime expires;
}

class UserProfilePage extends ConsumerStatefulWidget {
  const UserProfilePage({super.key});

  static const String routeName = 'userProfile';
  static const String routePath = '/userProfile';

  @override
  ConsumerState<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends ConsumerState<UserProfilePage> with WidgetsBindingObserver {
  final _pageCtrl = PageController();

  // Design tokens
  static const double _screenHPad = 10; // wider fill to use more of the screen
  static const double _radiusCard = 12;
  static const double _radiusPill = 10;
  static const double _chipMinHeight = 34;

  Color get _outline => AppTheme.ffAlt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(myProfileProvider.notifier).refresh();
    }
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
        return 'Other';
      default:
        return v;
    }
  }

  // Convert any JSON-ish list to List<String> safely (prevents JS web cast errors)
  List<String> _asStrList(dynamic v) {
    if (v is List) {
      return v
          .map((e) => e?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return <String>[];
  }

  // 1 → fully visible; 0 → collapsed during swipe
  double _overlayT() {
    if (!_pageCtrl.hasClients || !_pageCtrl.position.hasPixels) return 1;
    final page = _pageCtrl.page ?? 0.0;
    final frac = (page - page.round()).abs();
    final t = 1 - (frac * 2);
    return t.clamp(0.0, 1.0);
  }

  int? _calculateAge(Map<String, dynamic> p) {
    final dobStr = p['date_of_birth'] as String?;
    if (dobStr == null) return null;
    final dob = DateTime.tryParse(dobStr);
    if (dob == null) return null;
    final now = DateTime.now();
    var age = now.year - dob.year;
    if (now.month < dob.month || (now.month == dob.month && now.day < dob.day)) {
      age--;
    }
    return age;
  }

  double _calculateCompletion(Map<String, dynamic> p) {
    final name = p['name'] as String?;
    final bio = p['bio'] as String?;
    final age = _calculateAge(p);
    final profilePictures = _asStrList(p['profile_pictures']);
    final interests = _asStrList(p['interests']);
    final languages = _asStrList(p['my_languages']);
    final currentCity = p['current_city'] as String?;
    final education = p['education'] as String?;

    final checks = <bool>[
      (name?.trim().isNotEmpty ?? false),
      (bio?.trim().isNotEmpty ?? false),
      (age != null && age >= 18),
      profilePictures.isNotEmpty,
      interests.length >= 3,
      languages.isNotEmpty,
      (currentCity?.trim().isNotEmpty ?? false),
      (education?.trim().isNotEmpty ?? false),
    ];
    final score = checks.where((c) => c).length;
    return score / checks.length;
  }

  bool _hasStr(Map<String, dynamic>? p, String key) {
    final s = p?[key] as String?;
    return s != null && s.trim().isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    // ── AUTH GUARD
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      return Scaffold(
        backgroundColor: AppTheme.ffSecondaryBg,
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
                    'Please sign in to view your profile',
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

    // Data
    final a = ref.watch(myProfileProvider);
    final p = a.valueOrNull;
    final isLoading = a.isLoading;
    final hasError = a.hasError && p == null;

    final pics = _asStrList(p?['profile_pictures']);
    final interests = _asStrList(p?['interests']);
    final langs = _asStrList(p?['my_languages']);
    final goals = _asStrList(p?['relationship_goals']);

    final slivers = <Widget>[
      // Completion
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(_screenHPad, 14, _screenHPad, 12),
        sliver: SliverToBoxAdapter(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: (p != null)
                ? _CompletionCard(_calculateCompletion(p))
                : const _CompletionCardSkeleton(),
          ),
        ),
      ),

      // Photos
      if (pics.isNotEmpty || isLoading)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 12),
          sliver: SliverToBoxAdapter(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: (p != null && pics.isNotEmpty)
                  ? _PhotoCarousel(
                      pageCtrl: _pageCtrl,
                      photos: pics,
                      name: p['name'] as String?,
                      age: _calculateAge(p),
                      overlayT: _overlayT,
                      outline: _outline,
                    )
                  : const _PhotoCarouselSkeleton(),
            ),
          ),
        ),

      // Basics
      if (p != null || isLoading)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 10),
          sliver: SliverToBoxAdapter(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: (p != null)
                  ? _Card(
                      radius: _radiusCard,
                      outline: _outline,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _Heading(icon: Icons.badge_outlined, text: 'Basics'),
                          const SizedBox(height: 12),
                          if (_hasStr(p, 'gender'))
                            _RowIcon(icon: Icons.wc_rounded, text: _genderLabel(p['gender'] as String?)),
                          if (_hasStr(p, 'current_city')) ...[
                            const SizedBox(height: 8),
                            _RowIcon(icon: Icons.location_on_outlined, text: 'Lives in ${p['current_city'] as String?}')
                          ],
                        ],
                      ),
                    )
                  : const _SectionSkeleton(lines: 2),
            ),
          ),
        ),

      // About Me
      if (_hasStr(p, 'bio') || isLoading)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 10),
          sliver: SliverToBoxAdapter(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: (p != null && _hasStr(p, 'bio'))
                  ? _Card(
                      radius: _radiusCard,
                      outline: _outline,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _Heading(icon: Icons.info_outline, text: 'About Me'),
                          const SizedBox(height: 12),
                          _ReadOnlyField(
                            value: p['bio'] as String? ?? '',
                            outline: _outline,
                            radius: _radiusPill,
                          ),
                        ],
                      ),
                    )
                  : const _SectionSkeleton(lines: 3),
            ),
          ),
        ),

      // Interests
      if (interests.isNotEmpty || isLoading)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 10),
          sliver: SliverToBoxAdapter(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: (p != null && interests.isNotEmpty)
                  ? _Card(
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
                    )
                  : const _SectionSkeleton(lines: 3, pills: true),
            ),
          ),
        ),

      // Family Plans
      if (_hasStr(p, 'family_plans') || isLoading)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 10),
          sliver: SliverToBoxAdapter(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: (p != null && _hasStr(p, 'family_plans'))
                  ? _Card(
                      radius: _radiusCard,
                      outline: _outline,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _Heading(icon: Icons.family_restroom_outlined, text: 'Family Plans'),
                          const SizedBox(height: 10),
                          _PillsWrap(
                            items: [p['family_plans'] as String? ?? ''],
                            outline: _outline,
                            radius: _radiusPill,
                            minHeight: _chipMinHeight,
                          ),
                        ],
                      ),
                    )
                  : const _SectionSkeleton(lines: 2, pills: true),
            ),
          ),
        ),

      // Love Style
      if (_hasStr(p, 'love_language') || isLoading)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 10),
          sliver: SliverToBoxAdapter(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: (p != null && _hasStr(p, 'love_language'))
                  ? _Card(
                      radius: _radiusCard,
                      outline: _outline,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _Heading(icon: Icons.favorite_border, text: 'Love Style'),
                          const SizedBox(height: 10),
                          _PillsWrap(
                            items: [p['love_language'] as String? ?? ''],
                            outline: _outline,
                            radius: _radiusPill,
                            minHeight: _chipMinHeight,
                          ),
                        ],
                      ),
                    )
                  : const _SectionSkeleton(lines: 2, pills: true),
            ),
          ),
        ),

      // Education
      if (_hasStr(p, 'education') || isLoading)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 10),
          sliver: SliverToBoxAdapter(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: (p != null && _hasStr(p, 'education'))
                  ? _Card(
                      radius: _radiusCard,
                      outline: _outline,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _Heading(icon: Icons.school_outlined, text: 'Education'),
                          const SizedBox(height: 10),
                          _PillsWrap(
                            items: [p['education'] as String? ?? ''],
                            outline: _outline,
                            radius: _radiusPill,
                            minHeight: _chipMinHeight,
                          ),
                        ],
                      ),
                    )
                  : const _SectionSkeleton(lines: 2, pills: true),
            ),
          ),
        ),

      // Communication Style
      if (_hasStr(p, 'communication_style') || isLoading)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 10),
          sliver: SliverToBoxAdapter(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: (p != null && _hasStr(p, 'communication_style'))
                  ? _Card(
                      radius: _radiusCard,
                      outline: _outline,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _Heading(icon: Icons.chat_bubble_outline, text: 'Communication Style'),
                          const SizedBox(height: 10),
                          _PillsWrap(
                            items: [p['communication_style'] as String? ?? ''],
                            outline: _outline,
                            radius: _radiusPill,
                            minHeight: _chipMinHeight,
                          ),
                        ],
                      ),
                    )
                  : const _SectionSkeleton(lines: 2, pills: true),
            ),
          ),
        ),

      // Relationship Goal
      if (goals.isNotEmpty || isLoading)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 10),
          sliver: SliverToBoxAdapter(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: (p != null && goals.isNotEmpty)
                  ? _Card(
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
                    )
                  : const _SectionSkeleton(lines: 2, pills: true),
            ),
          ),
        ),

      // Languages
      if (langs.isNotEmpty || isLoading)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 10),
          sliver: SliverToBoxAdapter(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: (p != null && langs.isNotEmpty)
                  ? _Card(
                      radius: _radiusCard,
                      outline: _outline,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _Heading(icon: Icons.translate_outlined, text: 'Languages I know'),
                          const SizedBox(height: 10),
                          _PillsWrap(
                            items: langs,
                            outline: _outline,
                            radius: _radiusPill,
                            minHeight: _chipMinHeight,
                          ),
                        ],
                      ),
                    )
                  : const _SectionSkeleton(lines: 2, pills: true),
            ),
          ),
        ),

      // Lifestyle
      if (p != null || isLoading)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(_screenHPad, 0, _screenHPad, 24),
          sliver: SliverToBoxAdapter(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: (p != null)
                  ? _Card(
                      radius: _radiusCard,
                      outline: _outline,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _Heading(icon: Icons.style_outlined, text: 'Lifestyle'),
                          const SizedBox(height: 12),

                          if (_hasStr(p, 'drinking')) ...[
                            const _Subheading(icon: Icons.local_bar_rounded, text: 'Drinking'),
                            const SizedBox(height: 6),
                            _PillsWrap(
                              items: [p['drinking'] as String? ?? ''],
                              outline: _outline,
                              radius: _radiusPill,
                              minHeight: _chipMinHeight,
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (_hasStr(p, 'smoking')) ...[
                            const _Subheading(icon: Icons.smoke_free, text: 'Smoking'),
                            const SizedBox(height: 6),
                            _PillsWrap(
                              items: [p['smoking'] as String? ?? ''],
                              outline: _outline,
                              radius: _radiusPill,
                              minHeight: _chipMinHeight,
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (_hasStr(p, 'pets')) ...[
                            const _Subheading(icon: Icons.pets_outlined, text: 'Pets'),
                            const SizedBox(height: 6),
                            _PillsWrap(
                              items: [p['pets'] as String? ?? ''],
                              outline: _outline,
                              radius: _radiusPill,
                              minHeight: _chipMinHeight,
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (_hasStr(p, 'workout')) ...[
                            const _Subheading(icon: Icons.fitness_center, text: 'Workout'),
                            const SizedBox(height: 6),
                            _PillsWrap(
                              items: [p['workout'] as String? ?? ''],
                              outline: _outline,
                              radius: _radiusPill,
                              minHeight: _chipMinHeight,
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (_hasStr(p, 'dietary_preference')) ...[
                            const _Subheading(icon: Icons.restaurant_menu, text: 'Diet'),
                            const SizedBox(height: 6),
                            _PillsWrap(
                              items: [p['dietary_preference'] as String? ?? ''],
                              outline: _outline,
                              radius: _radiusPill,
                              minHeight: _chipMinHeight,
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (_hasStr(p, 'sleeping_habits')) ...[
                            const _Subheading(icon: Icons.nightlight_round, text: 'Sleep'),
                            const SizedBox(height: 6),
                            _PillsWrap(
                              items: [p['sleeping_habits'] as String? ?? ''],
                              outline: _outline,
                              radius: _radiusPill,
                              minHeight: _chipMinHeight,
                            ),
                          ],
                        ],
                      ),
                    )
                  : const _SectionSkeleton(lines: 6, pills: true),
            ),
          ),
        ),
    ];

    return GestureDetector(
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: Scaffold(
        backgroundColor: AppTheme.ffSecondaryBg,
        floatingActionButton: const Padding(
          padding: EdgeInsetsDirectional.only(bottom: 75),
          child: _EditFab(),
        ),
        body: SafeArea(
          bottom: false,
          child: hasError
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Failed to load profile',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color.fromARGB(255, 255, 255, 255)),
                    ),
                  ),
                )
              : (isLoading && p == null)
                  ? const _UserProfileSkeleton()
                  : RefreshIndicator(
                      color: AppTheme.ffPrimary,
                      backgroundColor: const Color.fromARGB(255, 0, 0, 0),
                      onRefresh: () => ref.read(myProfileProvider.notifier).refresh(),
                      child: CustomScrollView(slivers: slivers),
                    ),
        ),
      ),
    );
  }
}

class _EditFab extends StatelessWidget {
  const _EditFab();
  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      backgroundColor: AppTheme.ffPrimary,
      onPressed: () => context.push('/edit-profile'),
      child: const Icon(Icons.edit, color: Colors.white, size: 22),
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

// Building blocks

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
            style: const TextStyle(color: Color.fromARGB(255, 255, 255, 255), fontSize: 14, height: 1.25),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _ReadOnlyField extends StatelessWidget {
  const _ReadOnlyField({required this.value, required this.outline, required this.radius});
  final String value;
  final Color outline;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color.fromARGB(255, 20, 20, 20),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(width: 1, color: outline.withValues(alpha: .60)),
      ),
      padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 10),
      child: Text(
        value,
        style: const TextStyle(color: Colors.white, height: 1.38),
      ),
    );
  }
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
            color: const Color.fromARGB(255, 20, 20, 20),
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

// Fullscreen, pinch-to-zoom gallery
class _FullScreenGallery extends StatefulWidget {
  const _FullScreenGallery({required this.images, required this.initialIndex});
  final List<String> images;
  final int initialIndex;

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
          style: const TextStyle(color: Color.fromARGB(255, 255, 255, 255), fontSize: 14),
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
                final raw = widget.images[i];
                final mq = MediaQuery.of(context);
                final targetW = (mq.size.width * mq.devicePixelRatio).round();

                return Center(
                  child: Hero(
                    tag: 'profile_photo_$i',
                    child: FutureBuilder<String>(
                      future: _SignedUrlCache.resolve(raw),
                      builder: (context, snap) {
                        final url = snap.data;
                        if (url == null) return const _ShimmerBox();
                        return InteractiveViewer(
                          minScale: 1.0,
                          maxScale: 4.0,
                          child: Image.network(
                            url,
                            fit: BoxFit.contain,
                            cacheWidth: targetW,
                            filterQuality: FilterQuality.medium,
                            gaplessPlayback: true,
                            errorBuilder: (_, __, ___) => const Icon(
                              Icons.broken_image,
                              color: Color.fromARGB(255, 255, 255, 255),
                              size: 48,
                            ),
                          ),
                        );
                      },
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
                  dotColor: Color(0x90FFFFFF),
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

// ──────────────────────────────────────────────────────────────
// SKELETONS (now with shimmer sweep)

class _UserProfileSkeleton extends StatelessWidget {
  const _UserProfileSkeleton();

  @override
  Widget build(BuildContext context) {
    return _PulseAll(
      child: RepaintBoundary(
        child: CustomScrollView(
          slivers: const [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(_UserProfileSkeletonParts.hpad, 14, _UserProfileSkeletonParts.hpad, 12),
              sliver: SliverToBoxAdapter(child: _CompletionCardSkeleton()),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(_UserProfileSkeletonParts.hpad, 0, _UserProfileSkeletonParts.hpad, 12),
              sliver: SliverToBoxAdapter(child: _PhotoCarouselSkeleton()),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(_UserProfileSkeletonParts.hpad, 0, _UserProfileSkeletonParts.hpad, 10),
              sliver: SliverToBoxAdapter(child: _SectionSkeleton(lines: 2)),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(_UserProfileSkeletonParts.hpad, 0, _UserProfileSkeletonParts.hpad, 10),
              sliver: SliverToBoxAdapter(child: _SectionSkeleton(lines: 3, pills: true)),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(_UserProfileSkeletonParts.hpad, 0, _UserProfileSkeletonParts.hpad, 10),
              sliver: SliverToBoxAdapter(child: _SectionSkeleton(lines: 2, pills: true)),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(_UserProfileSkeletonParts.hpad, 0, _UserProfileSkeletonParts.hpad, 10),
              sliver: SliverToBoxAdapter(child: _SectionSkeleton(lines: 2, pills: true)),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(_UserProfileSkeletonParts.hpad, 0, _UserProfileSkeletonParts.hpad, 10),
              sliver: SliverToBoxAdapter(child: _SectionSkeleton(lines: 2, pills: true)),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(_UserProfileSkeletonParts.hpad, 0, _UserProfileSkeletonParts.hpad, 10),
              sliver: SliverToBoxAdapter(child: _SectionSkeleton(lines: 1, pills: true)),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(_UserProfileSkeletonParts.hpad, 0, _UserProfileSkeletonParts.hpad, 24),
              sliver: SliverToBoxAdapter(child: _SectionSkeleton(lines: 6, pills: true)),
            ),
          ],
        ),
      ),
    );
  }
}

class _UserProfileSkeletonParts {
  static const double hpad = 10;
  static const double radius = 12;
  static const double outlineAlpha = .50;
  static const Color cardBg = Color.fromARGB(255, 0, 0, 0);
  static const Color fill = Color(0xFF202227);
}

class _CompletionCardSkeleton extends StatelessWidget {
  const _CompletionCardSkeleton();

  @override
  Widget build(BuildContext context) {
    final outline = AppTheme.ffAlt;
    return Container(
      decoration: BoxDecoration(
        color: _UserProfileSkeletonParts.cardBg,
        borderRadius: BorderRadius.circular(_UserProfileSkeletonParts.radius),
        border: Border.all(color: outline.withValues(alpha: _UserProfileSkeletonParts.outlineAlpha), width: 1.2),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: const [
          _SkeletonCircle(d: 60),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SkeletonBox(width: 180, height: 12, radius: 6),
                SizedBox(height: 8),
                _SkeletonBox(width: 220, height: 10, radius: 6),
              ],
            ),
          ),
          SizedBox(width: 10),
          _SkeletonBox(width: 16, height: 22, radius: 4),
        ],
      ),
    );
  }
}

class _PhotoCarouselSkeleton extends StatelessWidget {
  const _PhotoCarouselSkeleton();

  @override
  Widget build(BuildContext context) {
    final outline = AppTheme.ffAlt;
    return Container(
      decoration: BoxDecoration(
        color: _UserProfileSkeletonParts.cardBg,
        borderRadius: BorderRadius.circular(_UserProfileSkeletonParts.radius),
        border: Border.all(color: outline.withValues(alpha: _UserProfileSkeletonParts.outlineAlpha), width: 1.2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          const AspectRatio(
            aspectRatio: 4 / 5,
            child: _ShimmerBox(),
          ),
          Positioned(
            top: 10,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                _ShimmerLine(height: 3, width: 28),
                SizedBox(width: 6),
                _ShimmerLine(height: 3, width: 28),
                SizedBox(width: 6),
                _ShimmerLine(height: 3, width: 28),
                SizedBox(width: 6),
                _ShimmerLine(height: 3, width: 28),
              ],
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
                  Expanded(child: _ShimmerLine(height: 14)),
                  SizedBox(width: 8),
                  _ShimmerDot(size: 18),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionSkeleton extends StatelessWidget {
  const _SectionSkeleton({required this.lines, this.pills = false});

  final int lines;
  final bool pills;

  @override
  Widget build(BuildContext context) {
    final outline = AppTheme.ffAlt;
    return Container(
      decoration: BoxDecoration(
        color: _UserProfileSkeletonParts.cardBg,
        borderRadius: BorderRadius.circular(_UserProfileSkeletonParts.radius),
        border: Border.all(color: outline.withValues(alpha: _UserProfileSkeletonParts.outlineAlpha), width: 1.2),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              _ShimmerDot(size: 18),
              SizedBox(width: 8),
              _ShimmerLine(height: 14, width: 120),
            ],
          ),
          const SizedBox(height: 12),
          if (!pills)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: List.generate(lines, (i) => const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: _ShimmerLine(height: 12),
                  )),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: List.generate(lines * 2, (i) {
                final w = 70 + (i % 3) * 40;
                return _ShimmerBox(height: 28, width: w.toDouble(), radius: 10);
              }),
            ),
        ],
      ),
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  const _SkeletonBox({this.width = double.infinity, required this.height, this.radius = 12});
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return _Shimmer(child: _BaseSkeletonBox(width: width, height: height, radius: radius));
  }
}

class _SkeletonCircle extends StatelessWidget {
  const _SkeletonCircle({required this.d});
  final double d;

  @override
  Widget build(BuildContext context) {
    return _Shimmer(child: _BaseSkeletonCircle(d: d));
  }
}

// Base non-animated shapes (used by shimmer wrappers)
class _BaseSkeletonBox extends StatelessWidget {
  const _BaseSkeletonBox({this.width = double.infinity, required this.height, this.radius = 12});
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: _UserProfileSkeletonParts.fill,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

class _BaseSkeletonCircle extends StatelessWidget {
  const _BaseSkeletonCircle({required this.d});
  final double d;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: d,
      height: d,
      decoration: const BoxDecoration(color: _UserProfileSkeletonParts.fill, shape: BoxShape.circle),
    );
  }
}

/// One animation driving the whole subtree (cheapest possible pulse)
class _PulseAll extends StatefulWidget {
  const _PulseAll({required this.child});
  final Widget child;

  @override
  State<_PulseAll> createState() => _PulseAllState();
}

class _PulseAllState extends State<_PulseAll> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);

  late final Animation<double> _a = CurvedAnimation(parent: _c, curve: Curves.easeInOut).drive(Tween(begin: 0.55, end: 1.0));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _a,
      builder: (context, child) => Opacity(opacity: _a.value, child: child),
      child: widget.child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shimmer primitives

class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.child});
  final Widget child;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

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
            final double x = (2 * dx) * t - dx; // sweep
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
    return _Shimmer(child: _BaseSkeletonBox(height: height ?? double.infinity, width: width ?? double.infinity, radius: radius));
  }
}

class _ShimmerLine extends StatelessWidget {
  const _ShimmerLine({required this.height, this.width});
  final double height;
  final double? width;
  @override
  Widget build(BuildContext context) {
    return _ShimmerBox(height: height, width: width, radius: 6);
  }
}

class _ShimmerDot extends StatelessWidget {
  const _ShimmerDot({required this.size});
  final double size;
  @override
  Widget build(BuildContext context) {
    return _Shimmer(child: _BaseSkeletonCircle(d: size));
  }
}

// ──────────────────────────────────────────────────────────────
// Local shared widgets

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

class _CompletionCard extends StatelessWidget {
  const _CompletionCard(this.progress);
  final double progress;

  @override
  Widget build(BuildContext context) {
    final pct = (progress.clamp(0, 1) * 100).round();
    return _Card(
      radius: 12,
      outline: AppTheme.ffAlt,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Heading(icon: Icons.check_circle_outline, text: 'Profile completeness'),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              height: 10,
              child: LayoutBuilder(
                builder: (context, c) {
                  final w = c.maxWidth * progress.clamp(0, 1);
                  return Stack(
                    children: [
                      Container(color: const Color(0x332A2C31)),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          width: w,
                          color: AppTheme.ffPrimary,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text('$pct% complete', style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }
}

class _PhotoCarousel extends StatelessWidget {
  const _PhotoCarousel({
    required this.pageCtrl,
    required this.photos,
    required this.name,
    required this.age,
    required this.overlayT,
    required this.outline,
  });

  final PageController pageCtrl;
  final List<String> photos;
  final String? name;
  final int? age;
  final double Function() overlayT;
  final Color outline;

  @override
  Widget build(BuildContext context) {
    final images = photos.where((s) => s.trim().isNotEmpty).toList(growable: false);

    return _Card(
      radius: 12,
      outline: outline,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            AspectRatio(
              aspectRatio: 4 / 5,
              child: ScrollConfiguration(
                behavior: const _DragScrollBehavior(),
                child: PageView.builder(
                  controller: pageCtrl,
                  itemCount: images.length,
                  itemBuilder: (_, i) {
                    final raw = images[i];
                    final mq = MediaQuery.of(context);
                    final targetW = (mq.size.width * mq.devicePixelRatio).round();
                    return Hero(
                      tag: 'profile_photo_$i',
                      child: FutureBuilder<String>(
                        future: _SignedUrlCache.resolve(raw),
                        builder: (context, snap) {
                          final url = snap.data;
                          if (url == null) return const _ShimmerBox();
                          return GestureDetector(
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => _FullScreenGallery(images: images, initialIndex: i),
                                  fullscreenDialog: true,
                                ),
                              );
                            },
                            child: Image.network(
                              url,
                              fit: BoxFit.cover,
                              cacheWidth: targetW,
                              filterQuality: FilterQuality.medium,
                              gaplessPlayback: true,
                              errorBuilder: (_, __, ___) =>
                                  const Center(child: Icon(Icons.broken_image, color: Colors.white70)),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
            ),
            Positioned(
              top: 10,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  images.length,
                  (_) => Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: 28,
                    height: 3,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Opacity(
                opacity: overlayT().clamp(0.0, 1.0),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .42),
                    border: Border(top: BorderSide(color: Colors.white.withValues(alpha: .12), width: 1)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          [
                            if ((name ?? '').trim().isNotEmpty) name!.trim(),
                            if (age != null) age.toString(),
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                      ),
                      smooth_page_indicator.SmoothPageIndicator(
                        controller: pageCtrl,
                        count: images.length,
                        effect: const smooth_page_indicator.WormEffect(
                          dotHeight: 6,
                          dotWidth: 6,
                          spacing: 6,
                          dotColor: Color(0x90FFFFFF),
                          activeDotColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
