// FILE: lib/features/profile/pages/user_profile_page.dart
// Changes:
// 1) Removed the top header row (Profile title, UPGRADE button, Settings icon).
// 2) "About Me" now renders as a read-only text-field style block to reflect typed input.
//    Colors match the rest of the page (dark fill, white text, pink untouched).
// 3) Loading state now shows a fast, single-ticker skeleton that mimics the final layout.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart' as smooth_page_indicator;
import 'package:percent_indicator/percent_indicator.dart';
import 'package:go_router/go_router.dart';

import '../../../theme/app_theme.dart';
import '../profile_repository.dart';

class UserProfilePage extends ConsumerStatefulWidget {
  const UserProfilePage({super.key});

  static const String routeName = 'userProfile';
  static const String routePath = '/userProfile';

  @override
  ConsumerState<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends ConsumerState<UserProfilePage> {
  final _pageCtrl = PageController();

  // Design tokens
  static const double _screenHPad = 10; // wider fill to use more of the screen
  static const double _radiusCard = 12;
  static const double _radiusPill = 10;
  static const double _chipMinHeight = 34;

  Color get _outline => AppTheme.ffAlt;

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
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
    final asyncProfile = ref.watch(myProfileProvider);

    return GestureDetector(
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: Scaffold(
        backgroundColor: AppTheme.ffSecondaryBg,
        floatingActionButton: Padding(
          padding: const EdgeInsetsDirectional.only(bottom: 75),
          child: FloatingActionButton(
            backgroundColor: AppTheme.ffPrimary,
            onPressed: () => context.push('/edit-profile'),
            child: const Icon(Icons.edit, color: Colors.white, size: 22),
          ),
        ),
        body: SafeArea(
          bottom: false,
          child: asyncProfile.when(
            // ─────────────── SKELETON LOADING ───────────────
            loading: () => const _UserProfileSkeleton(),
            error: (e, _) => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Failed to load profile',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color.fromARGB(255, 255, 255, 255)),
                ),
              ),
            ),
            data: (p) {
              bool hasStr(String? s) => s != null && s.trim().isNotEmpty;
              bool hasList(List<dynamic>? l) => l != null && l.isNotEmpty;

              final completion = p?.completion ?? 0.0;
              final completionPct = (completion * 100).clamp(0, 100).round();

              final photos = p?.profilePictures ?? const <String>[];
              final interests = p?.interests ?? const <String>[];
              final goals = p?.relationshipGoals ?? const <String>[];
              final languages = p?.languages ?? const <String>[];

              final gender = _genderLabel(p?.gender);
              final city = p?.currentCity;
              final bio = p?.bio;
              final familyPlans = p?.familyPlans;
              final loveLanguage = p?.loveLanguage;
              final education = p?.education;
              final commStyle = p?.communicationStyle;

              final drinking = p?.drinking;
              final smoking = p?.smoking;
              final pets = p?.pets;
              final workout = p?.workout;
              final diet = p?.dietaryPreference;
              final sleep = p?.sleepingHabits;

              return CustomScrollView(
                slivers: [
                  // (Header completely removed)

                  // Completion (clickable)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(_screenHPad, 14, _screenHPad, 12),
                    sliver: SliverToBoxAdapter(
                      child: Material(
                        color: const Color.fromARGB(255, 0, 0, 0),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(_radiusCard),
                          onTap: () => context.push('/edit-profile'),
                          child: _Card(
                            radius: _radiusCard,
                            outline: _outline,
                            child: Row(
                              children: [
                                CircularPercentIndicator(
                                  percent: completion.clamp(0.0, 1.0),
                                  radius: 30,
                                  lineWidth: 6,
                                  animation: false,
                                  progressColor: AppTheme.ffPrimary, // keep pink
                                  backgroundColor: Colors.white.withValues(alpha: .12),
                                  center: Text(
                                    '$completionPct%',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                const Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Complete your Profile',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                        ),
                                      ),
                                      SizedBox(height: 6),
                                      Text(
                                        'Complete your profile to experience the best dating!',
                                        style: TextStyle(
                                          color: Color.fromARGB(255, 255, 255, 255),
                                          fontSize: 12,
                                          height: 1.25,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right, color: AppTheme.ffPrimary),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

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
                                      physics: const PageScrollPhysics(), // web-friendly
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
                                                ),
                                                transitionsBuilder: (_, anim, __, child) =>
                                                    FadeTransition(opacity: anim, child: child),
                                              ),
                                            );
                                          },
                                          child: Hero(
                                            tag: 'profile_photo_$i',
                                            child: Image.network(
                                              url,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, __, ___) => const ColoredBox(
                                                color: Color.fromARGB(255, 0, 0, 0),
                                                child: Center(
                                                  child: Icon(
                                                    Icons.broken_image,
                                                    color: Color.fromARGB(255, 255, 255, 255),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ),

                                // Optional subtle overall gradient
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            const Color.fromARGB(63, 0, 0, 0),
                                            Colors.black.withValues(alpha: .10),
                                            Colors.black.withValues(alpha: .25),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),

                                // FULL-WIDTH gray bar overlay (taller) with name/age + verified
                                if (p != null)
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
                                              color: const Color.fromARGB(255, 0, 0, 0).withValues(alpha: .42),
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
                                                    '${p.name ?? 'Unknown'}${p.age != null ? ' (${p.age})' : ''}',
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
                  if (p != null)
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
                                _RowIcon(icon: Icons.location_on_outlined, text: 'Lives in $city'),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),

                  // About Me (now: read-only text-field look)
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
                              _ReadOnlyField(
                                value: bio ?? '',
                                outline: _outline,
                                radius: _radiusPill,
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
                                items: [familyPlans ?? ''],
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
                                items: [loveLanguage ?? ''],
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
                                items: [education ?? ''],
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
                                items: [commStyle ?? ''],
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
                            const _Heading(icon: Icons.translate_outlined, text: 'Languages I know'),
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
                                items: const ['Add languages'],
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
                  if (p != null)
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
                                  items: [drinking ?? ''],
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
                                  items: [smoking ?? ''],
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
                                  items: [pets ?? ''],
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
                                  items: [workout ?? ''],
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
                                  items: [diet ?? ''],
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
                                  items: [sleep ?? ''],
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
              );
            },
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

// Building blocks

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
        color: const Color.fromARGB(255, 0, 0, 0),
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
        Icon(icon, color: AppTheme.ffPrimary, size: 18), // keep pink
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

// Read-only text field look for About Me (keeps dark fill + white text)
class _ReadOnlyField extends StatelessWidget {
  const _ReadOnlyField({required this.value, required this.outline, required this.radius});
  final String value;
  final Color outline;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color.fromARGB(255, 20, 20, 20), // same dark as other blocks
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
        Icon(icon, size: 18, color: AppTheme.ffPrimary), // keep pink
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
              physics: const PageScrollPhysics(), // explicit physics for web swipe
              controller: _controller,
              onPageChanged: (i) => setState(() => _index = i),
              itemCount: widget.images.length,
              itemBuilder: (_, i) {
                final url = widget.images[i];
                return Center(
                  child: Hero(
                    tag: 'profile_photo_$i',
                    child: InteractiveViewer(
                      minScale: 1.0,
                      maxScale: 4.0,
                      child: Image.network(
                        url,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.broken_image, color: Color.fromARGB(255, 255, 255, 255), size: 48),
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
                  dotColor: Color.fromARGB(255, 255, 255, 255),
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
// SKELETONS (single ticker driving entire subtree)

class _UserProfileSkeleton extends StatelessWidget {
  const _UserProfileSkeleton();

  @override
  Widget build(BuildContext context) {
    return _PulseAll(
      child: RepaintBoundary(
        child: CustomScrollView(
          slivers: [
            // Completion card skeleton
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(_UserProfileSkeletonParts.hpad, 14, _UserProfileSkeletonParts.hpad, 12),
              sliver: SliverToBoxAdapter(child: _CompletionCardSkeleton()),
            ),

            // Photos skeleton
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(_UserProfileSkeletonParts.hpad, 0, _UserProfileSkeletonParts.hpad, 12),
              sliver: SliverToBoxAdapter(child: _PhotoCarouselSkeleton()),
            ),

            // Basic sections skeletons
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(_UserProfileSkeletonParts.hpad, 0, _UserProfileSkeletonParts.hpad, 10),
              sliver: SliverToBoxAdapter(child: _SectionSkeleton(lines: 2)),
            ),
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(_UserProfileSkeletonParts.hpad, 0, _UserProfileSkeletonParts.hpad, 10),
              sliver: SliverToBoxAdapter(child: _SectionSkeleton(lines: 3, pills: true)),
            ),
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(_UserProfileSkeletonParts.hpad, 0, _UserProfileSkeletonParts.hpad, 10),
              sliver: SliverToBoxAdapter(child: _SectionSkeleton(lines: 2, pills: true)),
            ),
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(_UserProfileSkeletonParts.hpad, 0, _UserProfileSkeletonParts.hpad, 10),
              sliver: SliverToBoxAdapter(child: _SectionSkeleton(lines: 2, pills: true)),
            ),
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(_UserProfileSkeletonParts.hpad, 0, _UserProfileSkeletonParts.hpad, 10),
              sliver: SliverToBoxAdapter(child: _SectionSkeleton(lines: 2, pills: true)),
            ),

            // Languages
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(_UserProfileSkeletonParts.hpad, 0, _UserProfileSkeletonParts.hpad, 10),
              sliver: SliverToBoxAdapter(child: _SectionSkeleton(lines: 1, pills: true)),
            ),

            // Lifestyle (more content)
            const SliverPadding(
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
  static const Color border = Color(0xFF3A3D44);
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
            child: ColoredBox(color: _UserProfileSkeletonParts.fill),
          ),
          // Top page bars
          Positioned(
            top: 10,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                _SkeletonBox(width: 28, height: 3, radius: 3),
                SizedBox(width: 6),
                _SkeletonBox(width: 28, height: 3, radius: 3),
                SizedBox(width: 6),
                _SkeletonBox(width: 28, height: 3, radius: 3),
                SizedBox(width: 6),
                _SkeletonBox(width: 28, height: 3, radius: 3),
              ],
            ),
          ),
          // Bottom name bar
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
                  Expanded(child: _SkeletonBox(width: double.infinity, height: 14, radius: 6)),
                  SizedBox(width: 8),
                  _SkeletonCircle(d: 18),
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
          // Heading
          Row(
            children: const [
              _SkeletonCircle(d: 18),
              SizedBox(width: 8),
              _SkeletonBox(width: 120, height: 14, radius: 6),
            ],
          ),
          const SizedBox(height: 12),
          // Body
          if (!pills)
            for (int i = 0; i < lines; i++) ...[
              const _SkeletonBox(width: 200, height: 12, radius: 6),
              if (i != lines - 1) const SizedBox(height: 8),
            ]
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: List.generate(lines * 2, (i) {
                final w = 70 + (i % 3) * 40;
                return _SkeletonPill(width: w.toDouble(), height: 28, radius: 10);
              }),
            ),
        ],
      ),
    );
  }
}

class _SkeletonPill extends StatelessWidget {
  const _SkeletonPill({required this.width, required this.height, required this.radius});
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(minHeight: height),
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: _UserProfileSkeletonParts.fill,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: _UserProfileSkeletonParts.border.withValues(alpha: .4), width: 1),
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

class _SkeletonCircle extends StatelessWidget {
  const _SkeletonCircle({required this.d});
  final double d;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: d,
      height: d,
      decoration: const BoxDecoration(
        color: _UserProfileSkeletonParts.fill,
        shape: BoxShape.circle,
      ),
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
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
        ..repeat(reverse: true);

  late final Animation<double> _a =
      CurvedAnimation(parent: _c, curve: Curves.easeInOut).drive(Tween(begin: 0.55, end: 1.0));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _a,
      child: widget.child,
      builder: (_, child) => Opacity(opacity: _a.value, child: child),
    );
  }
}
