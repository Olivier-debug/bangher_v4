// FILE: lib/features/swipe/pages/swipe_stack_page.dart
// Wide cards + Super Like (down) compose overlay + paused stack while composing.
// Includes: non-undoable Super Like when a message is sent on instant match,
// and stable card width/height so cards don't shrink after first swipe.

import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:swipable_stack/swipable_stack.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';

import '../presentation/swipe_models.dart';
import '../presentation/controllers/swipe_controller.dart';
import '../../profile/pages/view_profile_page.dart' show ViewProfilePage;
import '../../swipe/data/swipe_feed_cache.dart';
import '../../../filters/filter_matches_sheet.dart';
import '../../../ui/shimmer.dart';
import '../../profile/data/preferences_store.dart' show myPreferencesUiStoreProvider;
import '../../matches/data/match_seen_store.dart' show MatchSeenStore;
import '../../matches/widgets/match_overlay.dart' as overlay show MatchOverlay, ProfileLite;
// NEW: centralized storage URL helpers (replaces local duplications)
import '../../../core/images/storage_url_resolver.dart';

// ────────────────────────────────────────────────────────────────────────────
// Logging helpers

String _ts() {
  final now = DateTime.now();
  String two(int x) => x.toString().padLeft(2, '0');
  final ms = now.millisecond.toString().padLeft(3, '0');
  return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.$ms';
}

int _swipeLogId = 0;
int _ctrlLogId = 0;
void logSwipe(String msg) {
  _swipeLogId += 1;
  // ignore: avoid_print
  print('[SWIPE ${_swipeLogId.toString().padLeft(4, '0')} ${_ts()}] $msg');
}
void logCtrl(String msg) {
  _ctrlLogId += 1;
  // ignore: avoid_print
  print('[CTRL ${_ctrlLogId.toString().padLeft(4, '0')} ${_ts()}] $msg');
}

// ────────────────────────────────────────────────────────────────────────────

final RouteObserver<ModalRoute<void>> routeObserver = RouteObserver<ModalRoute<void>>();

final prefGenderProvider = StateProvider<String>((_) => 'A');
final prefAgeMinProvider = StateProvider<int>((_) => 18);
final prefAgeMaxProvider = StateProvider<int>((_) => 60);
final prefRadiusKmProvider = StateProvider<double>((_) => 50.0);

final photoIndexByIdProvider = StateProvider<Map<String, int>>((_) => <String, int>{});

// NOTE: Config(...) is NOT const in flutter_cache_manager. No const here.
final customCacheManager = CacheManager(
  Config(
    'profileCacheKey',
    stalePeriod: const Duration(days: 14),
    maxNrOfCacheObjects: 4000,
  ),
);

// Controller provider
final swipeStackControllerProvider = Provider<SwipableStackController>((ref) {
  final ctrl = SwipableStackController();
  ref.onDispose(ctrl.dispose);
  return ctrl;
});

/// ───────────────────────────────────────────────────────────────────────────
/// Undo meta (top-level class; not nested inside a State class)
class _UndoMeta {
  final String userId;
  final bool undoable;
  const _UndoMeta(this.userId, {required this.undoable});
}
// ────────────────────────────────────────────────────────────────────────────

class TestSwipeStackPage extends ConsumerStatefulWidget {
  const TestSwipeStackPage({super.key});
  static const String routeName = 'SwipePage';
  static const String routePath = '/swipe';

  @override
  ConsumerState<TestSwipeStackPage> createState() => _TestSwipeStackPageState();
}

class _TestSwipeStackPageState extends ConsumerState<TestSwipeStackPage>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin, WidgetsBindingObserver, RouteAware {
  static const int _kTopUpThreshold = 3;

  SwipableStackController get _stack => ref.read(swipeStackControllerProvider);

  final ValueNotifier<(SwipeDirection?, double)> _overlayVN =
      ValueNotifier<(SwipeDirection?, double)>((null, 0.0));

  // Width/height lock (prevents cards shrinking after first swipe)
  double? _lockedCardW, _lockedCardH;
  Orientation? _lastOrientation;

  String? _firstCardIdSeen;
  String? _lastTopCardId;

  bool _toppingUp = false;
  DateTime _lastTopUpAt = DateTime.fromMillisecondsSinceEpoch(0);

  final FocusNode _focusNode = FocusNode(debugLabel: 'SwipeStackFocus');

  final Map<String, List<String?>> _urlOverridesByCard = <String, List<String?>>{};
  final Set<String> _refreshingUrls = <String>{};

  int _lastIndexSeen = -1;
  late final VoidCallback _stackListener;

  static const double _kBottomBarHeight = 88;

  // pause/lock interactions while overlays are open
  bool _locked = false;

  // one-shot bypass for programmatic advance while locked
  bool _bypassLockOnce = false;

  // Haptic threshold state (per direction)
  final Set<SwipeDirection> _hapticFiredForDir = <SwipeDirection>{};

  late AnimationController _floatController;

  StreamSubscription<MatchEvent>? _matchSub;
  final Set<String> _shownMatchIds = <String>{};
  final Set<String> _revokedMatchIds = <String>{};
  String? _visibleMatchOverlayId;

  // ── Super Like / Undo policy ──────────────────────────────────────────────
  // Toggle: make *all* Super Likes final?
  static const bool _kAllSuperLikesFinal = false;

  // If the last action should not be undoable, we set this id before the stack advances.
  String? _pendingNonUndoableId;

  // Lightweight meta mirror so we can block rewind before UI moves.
  final List<_UndoMeta> _undoMeta = <_UndoMeta>[];

  String _subtitleFrom({int? age, String? distance}) {
    final parts = <String>[];
    if ((age ?? 0) > 0) parts.add(age!.toString());
    if ((distance ?? '').trim().isNotEmpty) parts.add(distance!.trim());
    return parts.join(' • ');
  }

  SwipeCard? _findCardById(String id) {
    final st = ref.read(swipeControllerProvider);
    for (final c in st.cards) {
      if (c.id == id) return c;
    }
    return null;
  }

  overlay.ProfileLite _otherLiteFromCard(SwipeCard c) {
    return overlay.ProfileLite(
      id: c.id,
      name: c.name,
      photoUrl: c.photos.isNotEmpty ? c.photos.first : null,
      subtitle: _subtitleFrom(age: c.age, distance: c.distance),
      bio: (c.bio ?? '').trim().isEmpty ? null : c.bio!.trim(),
    );
  }

  @override
  void initState() {
    super.initState();
    logSwipe('initState()');
    _floatController = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat(reverse: true);
    WidgetsBinding.instance.addObserver(this);
    _stackListener = _onStackChanged;
    _stack.addListener(_stackListener);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctrl = ref.read(swipeControllerProvider.notifier);
      ctrl.bootstrapIfNeeded();

      // Realtime match popups
      _matchSub?.cancel();
      _matchSub = ctrl.matchStream.listen((e) async {
        if (!_shownMatchIds.add(e.matchId)) return;
        if (_revokedMatchIds.contains(e.matchId)) return;

        final meId = Supabase.instance.client.auth.currentUser?.id ?? '';
        if (meId.isEmpty) return;

        final alreadySeen = await MatchSeenStore.instance.isSeen(e.matchId, meId: meId);
        if (alreadySeen) return;

        final ctx = context;
        if (!ctx.mounted) return;

        final fromDeck = _findCardById(e.otherId);
        final otherLite = fromDeck != null
            ? _otherLiteFromCard(fromDeck)
            : overlay.ProfileLite(id: e.otherId, name: e.otherName, photoUrl: e.otherPhotoUrl);

        _visibleMatchOverlayId = e.matchId;
        try {
          _locked = true;
          await overlay.MatchOverlay.show(
            ctx,
            me: overlay.ProfileLite(id: meId, name: 'You', photoUrl: null),
            other: otherLite,
            onMessage: () => _openChat(e.matchId, e.otherId),
            onDismiss: () {},
          );
        } finally {
          await MatchSeenStore.instance.markSeen(e.matchId, meId: meId);
          _visibleMatchOverlayId = null;
          _locked = false;
        }
      });

      _focusNode.requestFocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Lock width/height to the first meaningful layout for stability;
    // re-lock only when orientation changes or size jumps by > 30 px.
    final mq = MediaQuery.of(context);
    final size = mq.size;
    final orientation = mq.orientation;

    final targetW = (size.width - 16).clamp(280.0, 1200.0);
    final targetH = size.height;

    bool relock = false;
    if (_lastOrientation == null || _lastOrientation != orientation) relock = true;
    if (_lockedCardW == null || (targetW - (_lockedCardW ?? 0)).abs() > 30) relock = true;
    if (_lockedCardH == null || (targetH - (_lockedCardH ?? 0)).abs() > 30) relock = true;

    if (relock) {
      _lastOrientation = orientation;
      _lockedCardW = targetW.toDouble();
      _lockedCardH = targetH.toDouble();
      logSwipe('Width/height locked: ${_lockedCardW!.toStringAsFixed(1)} x ${_lockedCardH!.toStringAsFixed(1)}');
    }

    final route = ModalRoute.of(context);
    if (route is PageRoute) routeObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _stack.removeListener(_stackListener);
    _overlayVN.dispose();
    _focusNode.dispose();
    _matchSub?.cancel();
    _floatController.dispose();

    final mid = _visibleMatchOverlayId;
    if (mid != null) {
      final meId = Supabase.instance.client.auth.currentUser?.id;
      if (meId != null && meId.isNotEmpty) {
        // ignore: discarded_futures
        MatchSeenStore.instance.markSeen(mid, meId: meId);
      }
      _visibleMatchOverlayId = null;
    }

    super.dispose();
  }

  void _openChat(String matchId, String otherUserId) {
    if (matchId.isEmpty) return;
    final intMatchId = int.tryParse(matchId) ?? 0;
    context.push('/chat', extra: {'matchId': intMatchId, 'userId': otherUserId});
  }

  // Display format helpers (image transform hints)

  String get _fmt => 'webp';

  String _variantCacheKey({
    required String rawUrlOrStable,
    required int widthPx,
    required int heightPx,
    required double dpr,
    required String fmt,
  }) {
    final base = stableCacheKey(rawUrlOrStable);
    return '$base#w${widthPx}h${heightPx}d${dpr.toStringAsFixed(2)}f$fmt';
  }

  Future<void> _prefetchOne({
    required BuildContext context,
    required String rawUrl,
    required int widthPx,
    required int heightPx,
    required double dpr,
  }) async {
    if (rawUrl.isEmpty) return;

    final fullUrl = addVariantTransform(
      url: rawUrl,
      widthPx: widthPx,
      heightPx: heightPx,
      dpr: dpr,
      format: _fmt,
      quality: 78,
      fit: 'cover',
    );
    final lqipUrl = addLqipTransform(url: rawUrl, format: _fmt);

    final fullKey = _variantCacheKey(
      rawUrlOrStable: rawUrl,
      widthPx: widthPx,
      heightPx: heightPx,
      dpr: dpr,
      fmt: _fmt,
    );

    final lqipProv = CachedNetworkImageProvider(
      lqipUrl,
      cacheManager: customCacheManager,
      cacheKey: '$fullKey#lqip',
    );
    final fullProv = CachedNetworkImageProvider(
      fullUrl,
      cacheManager: customCacheManager,
      cacheKey: fullKey,
    );

    try {
      if (!context.mounted) return;
      await precacheImage(lqipProv, context);
      if (!context.mounted) return;
      await precacheImage(fullProv, context);
    } catch (_) {}
  }

  Future<void> _prefetchAdjacentPhotos({
    required BuildContext context,
    required List<String> photos,
    required int index,
  }) async {
    if (photos.isEmpty) return;
    final mq = MediaQuery.maybeOf(context);
    final dpr = (mq?.devicePixelRatio ?? 2.0).clamp(1.0, 3.0);
    final projectedW = (_lockedCardW ?? _projectedCardWidth(context));
    final projectedH = _lockedCardH ?? MediaQuery.of(context).size.height;
    final widthPx = (projectedW * dpr).round().clamp(320, 1080);
    final heightPx = (projectedH * dpr).round().clamp(480, 1920);
    final indices = <int>{
      index,
      if (index - 1 >= 0) index - 1,
      if (index + 1 < photos.length) index + 1,
    };
    for (final i in indices) {
      final raw = photos[i];
      final url = _overrideUrlIfAny(_lastTopCardId ?? '', i, raw);
      unawaited(_prefetchOne(
        context: context,
        rawUrl: url,
        widthPx: widthPx,
        heightPx: heightPx,
        dpr: dpr.toDouble(),
      ));
    }
  }

  void _onStackChanged() {
    final cur = _stack.currentIndex;
    if (cur != _lastIndexSeen) {
      _lastIndexSeen = cur;
      _overlayVN.value = (null, 0.0);
      _hapticFiredForDir.clear();

      final st = ref.read(swipeControllerProvider);
      if (cur >= 0 && cur < st.cards.length) {
        final top = st.cards[cur];
        _lastTopCardId = top.id;
        ref.read(swipeControllerProvider.notifier).markTopCardId(top.id);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final photoIdxMap = ref.read(photoIndexByIdProvider);
          final currentPhotoIdx = (photoIdxMap[top.id] ?? 0)
              .clamp(0, top.photos.isEmpty ? 0 : top.photos.length - 1);
          unawaited(_prefetchAdjacentPhotos(
            context: context,
            photos: top.photos,
            index: currentPhotoIdx,
          ));
        });

        for (int i = cur + 1; i < math.min(cur + 4, st.cards.length); i++) {
          final photos = st.cards[i].photos;
          if (photos.isEmpty) continue;

          final urlRaw = _overrideUrlIfAny(st.cards[i].id, 0, photos.first);
          if (urlRaw.isEmpty) continue;

          final mq = MediaQuery.maybeOf(context);
          final dpr = (mq?.devicePixelRatio ?? 2.0).clamp(1.0, 3.0);
          final projectedW = _projectedCardWidth(context);
          final projectedH = _lockedCardH ?? MediaQuery.of(context).size.height;
          final widthPx = (projectedW * dpr).round().clamp(320, 1080);
          final heightPx = (projectedH * dpr).round().clamp(480, 1920);

          final displayUrl = addVariantTransform(
            url: urlRaw,
            widthPx: widthPx,
            heightPx: heightPx,
            dpr: dpr.toDouble(),
            format: _fmt,
            quality: 78,
            fit: 'cover',
          );
          final cacheKey = _variantCacheKey(
            rawUrlOrStable: urlRaw,
            widthPx: widthPx,
            heightPx: heightPx,
            dpr: dpr.toDouble(),
            fmt: _fmt,
          );

          final prov = CachedNetworkImageProvider(
            displayUrl,
            cacheManager: customCacheManager,
            cacheKey: cacheKey,
          );
          // ignore: discarded_futures
          precacheImage(prov, context).catchError((_) {});
        }
      } else {
        logSwipe('_onStackChanged: cur=$cur (no valid card)');
      }
      if (mounted) setState(() {});
    }
  }

  @override
  void didPushNext() {
    _lastTopCardId ??= _topCardId();
    if (_lastTopCardId != null) {
      ref.read(swipeControllerProvider.notifier).markTopCardId(_lastTopCardId);
      logCtrl('markTopCardId: $_lastTopCardId');
    }
    final mid = _visibleMatchOverlayId;
    if (mid != null) {
      final meId = Supabase.instance.client.auth.currentUser?.id;
      if (meId != null && meId.isNotEmpty) {
        unawaited(MatchSeenStore.instance.markSeen(mid, meId: meId));
      }
      _visibleMatchOverlayId = null;
    }
  }

  @override
  void didPopNext() {
    _overlayVN.value = (null, 0.0);
    if (mounted) setState(() {});
    _topUpIfNeeded();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      logSwipe('lifecycle: resumed -> topUpIfNeeded');
      _revokedMatchIds.clear();
      _topUpIfNeeded();
    } else if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      final mid = _visibleMatchOverlayId;
      if (mid != null) {
        final meId = Supabase.instance.client.auth.currentUser?.id;
        if (meId != null && meId.isNotEmpty) {
          unawaited(MatchSeenStore.instance.markSeen(mid, meId: meId));
        }
        _visibleMatchOverlayId = null;
      }
    }
  }

  @override
  bool get wantKeepAlive => true;

  // Cache/signing helpers (now using StorageUrlResolver)

  Future<void> _refreshSignedUrlFor({
    required String cardId,
    required int photoIndex,
    required String currentUrl,
  }) async {
    if (!isSupabaseSignedUrl(currentUrl)) return;
    if (!_refreshingUrls.add(currentUrl)) return;
    try {
      final parsed = parseBucketAndPathFromSignedUrl(currentUrl);
      if (parsed == null) return;
      final bucket = parsed.bucket;
      final objectPath = parsed.objectPath;

      final stableKey = stableCacheKey(currentUrl);
      await customCacheManager.removeFile(stableKey).catchError((_) {});

      final supa = Supabase.instance.client;
      var freshUrl = await supa.storage.from(bucket).createSignedUrl(objectPath, 55 * 60);
      if (kIsWeb) {
        final sep = freshUrl.contains('?') ? '&' : '?';
        freshUrl = '$freshUrl${sep}cb=${DateTime.now().millisecondsSinceEpoch}';
      }

      final list = _urlOverridesByCard.putIfAbsent(cardId, () => <String?>[]);
      if (photoIndex >= list.length) list.length = photoIndex + 1;
      list[photoIndex] = freshUrl;
      if (mounted) setState(() {});
    } catch (_) {
      // ignore
    } finally {
      _refreshingUrls.remove(currentUrl);
    }
  }

  // Data bootstrap / top-up

  Future<void> _bootstrap() async {
    await ref.read(swipeControllerProvider.notifier).bootstrapAndFirstLoad();
  }

  Future<void> _topUpIfNeeded() async {
    final now = DateTime.now();
    if (_toppingUp) return;
    if (now.difference(_lastTopUpAt) < const Duration(milliseconds: 600)) return;
    _toppingUp = true;
    _lastTopUpAt = now;
    try {
      logSwipe('UI topUpIfNeeded(): start');
      final ctrl = ref.read(swipeControllerProvider.notifier);
      await ctrl.topUpIfNeededCorrect(
        prefs: {
          'interested_in_gender': ref.read(prefGenderProvider) == 'A' ? null : ref.read(prefGenderProvider),
          'age_min': ref.read(prefAgeMinProvider),
          'age_max': ref.read(prefAgeMaxProvider),
          'radius_km': ref.read(prefRadiusKmProvider),
        },
        limit: 20,
      );
    } finally {
      _toppingUp = false;
    }
  }

  // Radius helper kept from your version
  Future<void> _applyRadiusAndReload(double km) async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please sign in first.')));
      return;
    }

    final intKm = km.round();
    ref.read(prefRadiusKmProvider.notifier).state = intKm.toDouble();
    ref.read(myPreferencesUiStoreProvider.notifier).setDistance(intKm);

    try {
      await client
          .from('preferences')
          .upsert({'user_id': userId, 'distance_radius': intKm}, onConflict: 'user_id')
          .select();

      await ref.read(swipeControllerProvider.notifier).topUpIfNeededCorrect(
        prefs: {
          'interested_in_gender': ref.read(prefGenderProvider) == 'A' ? null : ref.read(prefGenderProvider),
          'age_min': ref.read(prefAgeMinProvider),
          'age_max': ref.read(prefAgeMaxProvider),
          'radius_km': intKm.toDouble(),
        },
        limit: 20,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Radius updated to $intKm km ✅')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not update radius. Please try again.')),
      );
    }
  }

  Widget _maybeFloat({required bool isTopCard, required Widget child}) {
    if (!isTopCard || _isDragging) return child;
    return AnimatedBuilder(
      animation: _floatController,
      builder: (context, kid) {
        final t = _floatController.value * 2 * math.pi;
        final y = math.sin(t) * 3.0;
        final r = math.sin(t) * 0.004;
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.translationValues(0, y, 0)..rotateZ(r),
          child: kid,
        );
      },
      child: child,
    );
  }

  bool get _isDragging {
    final p = _overlayVN.value.$2;
    return p > 0.01;
  }

  // Build

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = ref.watch(swipeControllerProvider);

    if (Supabase.instance.client.auth.currentUser == null) {
      return const Center(child: Text('Please sign in to discover profiles', style: TextStyle(fontSize: 16)));
    }

    final newFirstId = state.cards.isNotEmpty ? state.cards.first.id : null;
    if (_firstCardIdSeen == null && newFirstId != null) {
      _firstCardIdSeen = newFirstId;
      _lastTopCardId = _topCardId();
      if (_lastTopCardId != null) {
        ref.read(swipeControllerProvider.notifier).markTopCardId(_lastTopCardId);
        logCtrl('markTopCardId: $_lastTopCardId');
      }
      logSwipe('firstIdInit: $_firstCardIdSeen');
    } else if (newFirstId != _firstCardIdSeen) {
      logSwipe('firstIdChanged: $_firstCardIdSeen -> $newFirstId');
      _firstCardIdSeen = newFirstId;
    }

    final totalCards = state.cards.length;
    final remaining = math.max(0, totalCards - _stack.currentIndex);
    final showEmptyNow = !state.fetching && state.exhausted && remaining == 0;

    // Ensure width/height are locked before building stack
    final cardW = _lockedCardW ?? _projectedCardWidth(context);
    final cardH = _lockedCardH ?? MediaQuery.of(context).size.height;

    return ColoredBox(
      color: kSwipeBg,
      child: Focus(
        focusNode: _focusNode,
        child: Shortcuts(
          shortcuts: <LogicalKeySet, Intent>{
            LogicalKeySet(LogicalKeyboardKey.arrowLeft): const _SwipeIntent.left(),
            LogicalKeySet(LogicalKeyboardKey.arrowRight): const _SwipeIntent.right(),
            LogicalKeySet(LogicalKeyboardKey.arrowUp): const _SwipeIntent.up(),
            LogicalKeySet(LogicalKeyboardKey.backspace): const _SwipeIntent.rewind(),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              _SwipeIntent: CallbackAction<_SwipeIntent>(onInvoke: (intent) {
                if (_locked) return null;
                final hasCard = _stack.currentIndex >= 0 && _stack.currentIndex < totalCards;
                if (intent.kind == _SwipeKind.rewind) {
                  logSwipe('btn: undo tapped');
                  _undoLast();
                  return null;
                }
                if (!hasCard) return null;
                switch (intent.kind) {
                  case _SwipeKind.left:
                    _stack.next(swipeDirection: SwipeDirection.left);
                    break;
                  case _SwipeKind.right:
                    _stack.next(swipeDirection: SwipeDirection.right);
                    break;
                  case _SwipeKind.up:
                    final idx = _stack.currentIndex;
                    if (idx >= 0 && idx < state.cards.length) {
                      _openViewProfileWithPrefill(state.cards[idx]);
                    }
                    break;
                  case _SwipeKind.rewind:
                    break;
                }
                return null;
              }),
            },
            child: LayoutBuilder(
              builder: (context, constraints) {
                final hasCards = totalCards > 0 && !showEmptyNow;

                return Stack(
                  children: [
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeOutCubic,
                          child: RepaintBoundary(
                            key: ValueKey(hasCards ? 'stack' : (state.fetching ? 'skeleton' : 'empty')),
                            child: (totalCards == 0 || showEmptyNow)
                                ? (state.fetching
                                    ? const _SkeletonFeed()
                                    : _OutOfPeopleScrollable(
                                        onAdjustFilters: _openFiltersScreen,
                                        onRetry: _bootstrap,
                                        onExpandRadius: _applyRadiusAndReload,
                                      ))
                                : _buildStack(state, totalCards, cardW, cardH),
                          ),
                        ),
                      ),
                    ),
                    if (!showEmptyNow)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: -12,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.35),
                          ),
                          child: _bottomBar(totalCards, enabled: !_locked),
                        ),
                      ),
                    if (state.fetching && totalCards > 0)
                      const SwipeBusyOverlay(message: 'Finding more people…', visible: true),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStack(SwipeUiState state, int totalCards, double cardW, double cardH) {
    return Center(
      child: SizedBox(
        width: cardW,
        height: cardH,
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(color: Colors.black.withValues(alpha: 0.10)),
              ),
            ),
            ClipRect(
              clipBehavior: Clip.none,
              child: SwipableStack(
                controller: _stack,
                detectableSwipeDirections: const {
                  SwipeDirection.left,
                  SwipeDirection.right,
                  SwipeDirection.up,
                  SwipeDirection.down, // NEW: down = Super Like compose
                },
                horizontalSwipeThreshold: 0.28,
                verticalSwipeThreshold: 0.24,
                overlayBuilder: (context, props) {
                  final dir = props.direction;
                  final raw = props.swipeProgress;
                  final p = (raw.isNaN ? 0.0 : raw.clamp(0.0, 1.0).toDouble());

                  if (p >= 1.0 && !_hapticFiredForDir.contains(dir)) {
                    HapticFeedback.mediumImpact();
                    _hapticFiredForDir.add(dir);
                  } else if (p < 0.6) {
                    _hapticFiredForDir.remove(dir);
                  }

                  if (_overlayVN.value.$1 != dir || _overlayVN.value.$2 != p) {
                    _overlayVN.value = (dir, p);
                  }

                  return Stack(
                    children: [
                      if (dir == SwipeDirection.right && p > 0.2)
                        Positioned(top: 32, left: 32, child: _swipeIcon(Icons.favorite, kBrandPink, p)),
                      if (dir == SwipeDirection.left && p > 0.2)
                        Positioned(top: 32, right: 32, child: _swipeIcon(Icons.close, Colors.redAccent, p)),
                      if (dir == SwipeDirection.up && p > 0.2)
                        Center(child: _swipeIcon(Icons.visibility, Colors.purpleAccent, p)),
                      if (dir == SwipeDirection.down && p > 0.2)
                        Center(child: _swipeIcon(Icons.auto_awesome, Colors.blueAccent, p)),
                    ],
                  );
                },
                onWillMoveNext: (index, direction) {
                  // allow a one-shot programmatic advance while locked
                  if (_locked && !_bypassLockOnce) return false;

                  final cards = state.cards;
                  if (index < 0 || index >= cards.length) return false;
                  if (index < _stack.currentIndex) return false;

                  if (direction == SwipeDirection.up) {
                    _openViewProfileWithPrefill(cards[index]);
                    HapticFeedback.heavyImpact();
                    return false;
                  }
                  if (direction == SwipeDirection.down) {
                    _onSuperLikePressed(cards[index]); // pause and show composer
                    HapticFeedback.heavyImpact();
                    return false;
                  }
                  return true;
                },
                onSwipeCompleted: (index, direction) async {
                  final cards = ref.read(swipeControllerProvider).cards;
                  if (index < 0 || index >= cards.length) return;
                  if (index < _stack.currentIndex - 1) return;

                  final card = cards[index];
                  final liked = direction == SwipeDirection.right;

                  logSwipe('onSwipeCompleted: idx=$index dir=$direction curBefore=${_stack.currentIndex} id=${card.id}');
                  try {
                    logCtrl('swipeCard: id=${card.id} liked=$liked');
                    final result = await ref
                        .read(swipeControllerProvider.notifier)
                        .swipeCardWithResult(swipeeId: card.id, liked: liked);

                    final matchId = result?.matchId ?? '';
                    if (liked && matchId.isNotEmpty && _shownMatchIds.add(matchId)) {
                      final meId = Supabase.instance.client.auth.currentUser?.id ?? '';
                      if (meId.isNotEmpty) {
                        final alreadySeen = await MatchSeenStore.instance.isSeen(matchId, meId: meId);
                        if (!alreadySeen) {
                          final meLite = overlay.ProfileLite(id: meId, name: 'You', photoUrl: null);
                          final otherLite = _otherLiteFromCard(card);

                          final ctx = context;
                          if (!ctx.mounted) return;

                          _visibleMatchOverlayId = matchId;
                          try {
                            _locked = true;
                            await overlay.MatchOverlay.show(
                              ctx,
                              me: meLite,
                              other: otherLite,
                              onMessage: () => _openChat(matchId, otherLite.id),
                              onDismiss: () {},
                            );
                          } finally {
                            await MatchSeenStore.instance.markSeen(matchId, meId: meId);
                            _visibleMatchOverlayId = null;
                            _locked = false;
                          }
                        }
                      }
                    }
                    HapticFeedback.heavyImpact();

                    final snapshotMap = card.toCacheMap();
                    if (matchId.isNotEmpty) {
                      snapshotMap['match_id'] = matchId; // keep for undo
                    }
                    SwipeUndoStore.instance.push(cardMap: snapshotMap, index: index);

                    // Mirror meta push: is this action undoable?
                    final bool nonUndoableNow =
                        _kAllSuperLikesFinal || (_pendingNonUndoableId == card.id);
                    _undoMeta.add(_UndoMeta(card.id, undoable: !nonUndoableNow));
                    _pendingNonUndoableId = null; // consume

                  } finally {
                    _overlayVN.value = (null, 0.0);

                    final cache = SwipeFeedCache.instance;
                    final topId = _topCardId();
                    final last3 = cache.swipedIds.length <= 3
                        ? cache.swipedIds.toList()
                        : cache.swipedIds.toList().sublist(cache.swipedIds.length - 3);
                    final next20 = ref
                        .read(swipeControllerProvider)
                        .cards
                        .skip(_stack.currentIndex + 1)
                        .take(20)
                        .map((c) => c.id);

                    final keep = <String>{
                      if (topId != null) topId,
                      ...last3,
                      ...next20,
                    }..removeWhere((e) => e.isEmpty);

                    cache.compactSwipedCardsInCache(keepFullIds: keep);

                    final stillTotal = ref.read(swipeControllerProvider).cards.length;
                    final remainingAhead = math.max(0, stillTotal - (_stack.currentIndex + 1));

                    if (remainingAhead <= _kTopUpThreshold) {
                      await _topUpIfNeeded();
                    }

                    final topIdNow = _topCardId();
                    ref.read(swipeControllerProvider.notifier).markTopCardId(topIdNow);

                    final visibleNow = math.max(0, stillTotal - _stack.currentIndex);
                    if (visibleNow == 0) {
                      await ref.read(swipeControllerProvider.notifier).markExhaustedIfDepleted(visibleCount: 0);
                    }
                    if (mounted) setState(() {});
                  }
                },
                itemCount: totalCards,
                builder: (context, props) {
                  final i = props.index;
                  if (i < _stack.currentIndex) return const SizedBox.shrink();
                  final st = ref.read(swipeControllerProvider);
                  if (i < 0 || i >= st.cards.length) return const SizedBox.shrink();

                  final card = st.cards[i];
                  final isTopCard = (i == _stack.currentIndex);

                  return KeyedSubtree(
                    key: ValueKey(card.id),
                    child: _card(isTopCard, i, card, cardW, cardH),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ───────────────────────── Super Like flow (down swipe or big middle button)

  Future<void> _onSuperLikePressed(SwipeCard card) async {
    if (_locked) return;
    _locked = true;
    try {
      final meId = Supabase.instance.client.auth.currentUser?.id ?? '';
      if (meId.isEmpty) return;

      final result = await _SuperLikeComposeOverlay.show(
        context,
        card: card,
      );

      // result:
      // - message != null -> send message (with Like)
      // - message == ''   -> Just Super Like (no message)
      // - null            -> cancel, keep current card
      if (result == null) {
        // cancelled: return to same user
        return;
      }

      final message = result.message?.trim() ?? '';

      // Perform the Like (right swipe in backend)
      final swipeRes = await ref
          .read(swipeControllerProvider.notifier)
          .swipeCardWithResult(swipeeId: card.id, liked: true);

      HapticFeedback.heavyImpact();

      final matchId = swipeRes?.matchId ?? '';
      if (message.isNotEmpty) {
        if (matchId.isNotEmpty) {
          // Instant match → insert message now
          try {
            final client = Supabase.instance.client;
            await client.from('messages').insert({
              'chat_id': int.tryParse(matchId) ?? 0,
              'sender_id': meId,
              'message': message,
            });
            _openChat(matchId, card.id);
          } catch (_) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Message queued — open the chat to retry if needed.')),
              );
            }
          }
        } else {
          // Not matched yet — they’ll see your note once they like back
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Super Like sent. They’ll see your note if they Like you back.')),
            );
          }
        }

        // 🔒 Make Super Like WITH NOTE non-undoable regardless of instant match
        _pendingNonUndoableId = card.id;
      }

      // Programmatically advance the stack to the next card.
      // Use a one-shot bypass so onWillMoveNext allows it even while _locked.
      _bypassLockOnce = true;
      _stack.next(swipeDirection: SwipeDirection.right);
      _bypassLockOnce = false;
    } finally {
      _locked = false;
    }
  }

  Widget _card(bool isTopCard, int realIndex, SwipeCard data, double cardW, double cardH) {
    final userId = data.id;
    final name = data.name;
    final age = data.age ?? 0;
    final bio = data.bio ?? '';
    final distance = data.distance ?? '';
    final photos = data.photos;

    final photoIndexById = ref.watch(photoIndexByIdProvider);
    final photoIndexByIdNotifier = ref.read(photoIndexByIdProvider.notifier);

    final maxIdx = photos.isEmpty ? 0 : photos.length - 1;
    final int currentIndex = (photoIndexById[userId] ?? 0).clamp(0, maxIdx).toInt();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_prefetchAdjacentPhotos(context: context, photos: photos, index: currentIndex));
    });

    final String? rawCurrent = photos.isEmpty ? null : photos[currentIndex];
    final String currentPhoto = _overrideUrlIfAny(userId, currentIndex, rawCurrent ?? '');

    final mq = MediaQuery.of(context);
    final dpr = mq.devicePixelRatio.clamp(1.0, 3.0);
    final effectiveW = ((cardW) * dpr).round().clamp(320, 1080);
    final effectiveH = ((cardH) * dpr).round().clamp(480, 1920);

    final String displayUrl = addVariantTransform(
      url: currentPhoto,
      widthPx: effectiveW,
      heightPx: effectiveH,
      dpr: dpr.toDouble(),
      format: _fmt,
      quality: 78,
      fit: 'cover',
    );

    final String lqipUrl = addLqipTransform(url: currentPhoto, format: _fmt);

    final String cacheKey = _variantCacheKey(
      rawUrlOrStable: currentPhoto,
      widthPx: effectiveW,
      heightPx: effectiveH,
      dpr: dpr.toDouble(),
      fmt: _fmt,
    );

    final imageCore = rawCurrent == null
        ? const ColoredBox(color: Colors.black)
        : Stack(
            fit: StackFit.expand,
            children: [
              CachedNetworkImage(
                key: ValueKey('$cacheKey:lqip'),
                imageUrl: lqipUrl,
                cacheManager: customCacheManager,
                cacheKey: '$cacheKey#lqip',
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
                fadeInDuration: Duration.zero,
                fadeOutDuration: Duration.zero,
                memCacheWidth: 64,
                memCacheHeight: 64,
              ),
              CachedNetworkImage(
                key: ValueKey('$cacheKey:full'),
                imageUrl: displayUrl,
                cacheManager: customCacheManager,
                cacheKey: cacheKey,
                fit: BoxFit.cover,
                alignment: Alignment.center,
                width: cardW,
                height: cardH,
                memCacheWidth: effectiveW,
                memCacheHeight: effectiveH,
                fadeInDuration: kIsWeb ? const Duration(milliseconds: 0) : const Duration(milliseconds: 90),
                filterQuality: FilterQuality.low,
                useOldImageOnUrlChange: false,
                placeholder: (context, url) => const SizedBox.expand(),
                errorWidget: (context, url, error) {
                  _refreshSignedUrlFor(cardId: userId, photoIndex: currentIndex, currentUrl: currentPhoto);
                  return const SizedBox.expand();
                },
              ),
            ],
          );

    final imageWithBoundary = RepaintBoundary(child: imageCore);

    return _maybeFloat(
      isTopCard: isTopCard,
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          width: cardW,
          height: cardH,
          decoration: BoxDecoration(
            boxShadow: [
              BoxShadow(color: Colors.white.withValues(alpha: 0.1), blurRadius: 20, spreadRadius: 0),
              const BoxShadow(blurRadius: 22, color: Colors.black45, offset: Offset(0, 14)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Container(
              color: Colors.black,
              child: LayoutBuilder(
                builder: (context, c) {
                  final cw = c.maxWidth;

                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) {
                      if (photos.length < 2) return;
                      final isRight = details.localPosition.dx > cw / 2;
                      final int n = (currentIndex + (isRight ? 1 : -1)).clamp(0, maxIdx).toInt();

                      unawaited(_prefetchAdjacentPhotos(context: context, photos: photos, index: n));

                      final next = Map<String, int>.from(photoIndexById)..[userId] = n;
                      photoIndexByIdNotifier.state = next;
                      HapticFeedback.selectionClick();
                    },
                    onLongPress: () => _openViewProfileWithPrefill(data),
                    child: Stack(
                      children: [
                        positionedFillOrHero(isTopCard, userId, imageWithBoundary),
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: RadialGradient(
                                center: Alignment.center,
                                radius: 0.9,
                                colors: [
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: 0.2),
                                ],
                                stops: const [0.6, 1.0],
                              ),
                            ),
                          ),
                        ),
                        if (photos.length > 1) _PhotoDots(currentIndex: currentIndex, count: photos.length),
                        _PresenceIndicator(presence: _presenceInfo(isOnline: data.isOnline, lastSeenRaw: data.lastSeen)),
                        _InfoGradient(
                          name: name,
                          age: age,
                          distance: distance,
                          bio: bio,
                          interests: data.interests,
                          onTap: () => _openViewProfileWithPrefill(data),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget positionedFillOrHero(bool isTopCard, String userId, Widget imageWithBoundary) {
    return Positioned.fill(
      child: isTopCard
          ? Hero(
              tag: 'public_profile_photo_$userId',
              child: AnimatedBuilder(
                animation: Listenable.merge([_stack, _overlayVN]),
                builder: (_, __) {
                  final tuple = _overlayVN.value;
                  final d = tuple.$1;
                  final p = tuple.$2;
                  final dx = (d == SwipeDirection.left ? -1 : d == SwipeDirection.right ? 1 : 0) * p * 8;
                  final dy = (d == SwipeDirection.up ? -1 : 0) * p * 8;
                  final tilt = (d == SwipeDirection.left ? -1 : d == SwipeDirection.right ? 1 : 0) * p * 0.02;
                  return Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.translationValues(dx, dy, 0)..rotateZ(tilt),
                    child: Transform.scale(
                      // Keep a consistent base scale for top/non-top to avoid perceived size jumps.
                      scale: 1.06 + p * 0.02,
                      child: Stack(fit: StackFit.expand, children: [imageWithBoundary]),
                    ),
                  );
                },
              ),
            )
          : Transform.scale(scale: 1.06, child: imageWithBoundary),
    );
  }

  String _overrideUrlIfAny(String cardId, int index, String original) {
    final list = _urlOverridesByCard[cardId];
    if (list == null) return original;
    if (index < 0 || index >= list.length) return original;
    final o = list[index];
    return (o == null || o.isEmpty) ? original : o;
  }

  double _projectedCardWidth(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return (w - 16).clamp(280.0, 1200.0);
  }

  Widget _bottomBar(int totalCards, {required bool enabled}) {
    final bottomPadding = 12 + MediaQuery.of(context).padding.bottom * 0.6;

    final double cardW = _lockedCardW ?? _projectedCardWidth(context);
    final barWidth = math.max(cardW - 8, 220.0);

    final double btn = cardW < 320 ? 52 : (cardW < 360 ? 58 : 62);
    final double bigBtn = btn + 10;

    final hasCard = enabled && _stack.currentIndex >= 0 && _stack.currentIndex < totalCards;
    final canUndo = enabled && SwipeUndoStore.instance.has;

    return Padding(
      padding: EdgeInsets.fromLTRB(12, 8, 12, bottomPadding),
      child: Align(
        alignment: Alignment.center,
        child: SizedBox(
          width: barWidth,
          height: _kBottomBarHeight,
          child: ValueListenableBuilder<(SwipeDirection?, double)>(
            valueListenable: _overlayVN,
            builder: (_, tuple, __) {
              final dir = tuple.$1;
              final pRaw = tuple.$2;
              final p = enabled ? pRaw.clamp(0.0, 1.0) : 0.0;

              double nopeScale = 1.0, superLikeScale = 1.0, likeScale = 1.0, rewindScale = 1.0, viewScale = 1.0;
              Color nopeColor = Colors.redAccent,
                  superLikeColor = Colors.blueAccent,
                  likeColor = Colors.greenAccent,
                  rewindColor = Colors.white24,
                  viewColor = Colors.purpleAccent;

              if (enabled) {
                if (dir == SwipeDirection.left) {
                  nopeScale = 1 + p * 0.3;
                  nopeColor = Colors.redAccent.withValues(alpha: 0.5 + p * 0.5);
                } else if (dir == SwipeDirection.right) {
                  likeScale = 1 + p * 0.3;
                  likeColor = Colors.greenAccent.withValues(alpha: 0.5 + p * 0.5);
                } else if (dir == SwipeDirection.up) {
                  viewScale = 1 + p * 0.3;
                  viewColor = Colors.purpleAccent.withValues(alpha: 0.5 + p * 0.5);
                } else if (dir == SwipeDirection.down) {
                  superLikeScale = 1 + p * 0.3;
                  superLikeColor = Colors.blueAccent.withValues(alpha: 0.5 + p * 0.5);
                }
              }

              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Semantics(
                    button: true, label: 'Rewind last', enabled: canUndo,
                    child: _RoundAction(
                      icon: Icons.rotate_left,
                      color: canUndo ? Colors.white : rewindColor,
                      size: btn, scale: rewindScale,
                      onTap: canUndo ? _undoLast : null,
                    ),
                  ),
                  Semantics(
                    button: true, label: 'Nope',
                    child: _RoundAction(
                      icon: Icons.cancel,
                      color: hasCard ? nopeColor : Colors.white24,
                      size: btn, scale: nopeScale,
                      onTap: hasCard ? () => _stack.next(swipeDirection: SwipeDirection.left) : null,
                    ),
                  ),
                  // BIG MIDDLE = SUPER LIKE (opens composer; does not swipe automatically)
                  Semantics(
                    button: true, label: 'Super Like',
                    child: _RoundAction(
                      icon: Icons.auto_awesome,
                      color: hasCard ? superLikeColor : Colors.white24,
                      size: bigBtn, scale: superLikeScale,
                      onTap: hasCard
                          ? () {
                              final idx = _stack.currentIndex;
                              if (idx >= 0 && idx < totalCards) {
                                _onSuperLikePressed(ref.read(swipeControllerProvider).cards[idx]);
                              }
                            }
                          : null,
                    ),
                  ),
                  Semantics(
                    button: true, label: 'Like',
                    child: _RoundAction(
                      icon: Icons.favorite,
                      color: hasCard ? likeColor : Colors.white24,
                      size: btn, scale: likeScale,
                      onTap: hasCard ? () => _stack.next(swipeDirection: SwipeDirection.right) : null,
                    ),
                  ),
                  // FAR RIGHT = VIEW PROFILE (maps to Up action)
                  Semantics(
                    button: true, label: 'View profile',
                    child: _RoundAction(
                      icon: Icons.visibility,
                      color: hasCard ? viewColor : Colors.white24,
                      size: btn, scale: viewScale,
                      onTap: hasCard
                          ? () {
                              final idx = _stack.currentIndex;
                              if (idx >= 0 && idx < totalCards) {
                                _openViewProfileWithPrefill(ref.read(swipeControllerProvider).cards[idx]);
                              }
                            }
                          : null,
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

  Future<void> _undoLast() async {
    // Gate undo BEFORE moving UI if the last action is non-undoable.
    if (_undoMeta.isNotEmpty && !_undoMeta.last.undoable) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("You can’t undo this — your Super Like included a note."),
          ),
        );
      }
      HapticFeedback.selectionClick();
      return;
    }

    if (_stack.currentIndex > 0) _stack.rewind();

    // Pop mirror meta (if any)
    if (_undoMeta.isNotEmpty) {
      _undoMeta.removeLast();
    }

    final snap = SwipeUndoStore.instance.take();
    final swipeeId = snap?.cardMap['potential_match_id']?.toString();
    final matchId = snap?.cardMap['match_id']?.toString();

    if (swipeeId != null && swipeeId.isNotEmpty) {
      try {
        logCtrl('undo: $swipeeId (matchId=$matchId)');
        await ref.read(swipeControllerProvider.notifier).undo(swipeeId: swipeeId);

        if (matchId != null && matchId.isNotEmpty) {
          _shownMatchIds.remove(matchId);
          _revokedMatchIds.add(matchId);
        }

        HapticFeedback.selectionClick();
      } catch (_) {/* ignore */}
    }

    ref.read(swipeControllerProvider.notifier).markTopCardId(_topCardId());
    if (mounted) setState(() {});
  }

  String? _topCardId() {
    final st = ref.read(swipeControllerProvider);
    final idx = _stack.currentIndex;
    if (idx < 0 || idx >= st.cards.length) return null;
    return st.cards[idx].id;
  }

  void _openViewProfileWithPrefill(SwipeCard card) {
    if (card.id.isEmpty) return;

    final prefill = <String, dynamic>{
      'user_id': card.id,
      'name': card.name,
      'age': card.age,
      'bio': card.bio,
      'profile_pictures': card.photos,
      'interests': card.interests,
      'distance': card.distance,
      'is_online': card.isOnline,
      'last_seen': card.lastSeen,
    }..removeWhere((_, v) => v == null);

    final List<String> photos = card.photos;
    if (photos.isNotEmpty) {
      final idxMap = ref.read(photoIndexByIdProvider);
      final int cur = (idxMap[card.id] ?? 0).clamp(0, math.max(0, photos.length - 1)).toInt();

      final effective = <String>[];
      for (int i = 0; i < photos.length; i++) {
        final raw = photos[i];
        final u = _overrideUrlIfAny(card.id, i, raw);
        if (u.isNotEmpty) effective.add(u);
      }

      if (effective.isNotEmpty) {
        final rotated = <String>[...effective.skip(cur), ...effective.take(cur)];
        prefill['resolved_photos'] = rotated;
      }
    }

    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, __, ___) => ViewProfilePage(userId: card.id, prefill: prefill),
        transitionsBuilder: (_, anim, __, child) {
          final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.98, end: 1).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  Future<void> _openFiltersScreen() async {
    await Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, __, ___) => const _FiltersHost(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic), child: child),
      ),
    );
  }

  Widget _swipeIcon(IconData icon, Color color, double p) {
    return Transform.scale(
      scale: 0.6 + p * 1.4,
      child: Transform.rotate(
        angle: -math.pi / 12 * p,
        child: Material(
          type: MaterialType.transparency,
          color: Colors.transparent,
          shadowColor: Colors.transparent,
          child: Icon(icon, color: color.withValues(alpha: p), size: 64),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Super Like Compose Overlay

class _SuperLikeResult {
  final String? message; // null => cancel; '' => super-like without message
  const _SuperLikeResult(this.message);
}

class _SuperLikeComposeOverlay extends StatelessWidget {
  const _SuperLikeComposeOverlay({required this.card});
  final SwipeCard card;

  static Future<_SuperLikeResult?> show(BuildContext context, {required SwipeCard card}) {
    return showGeneralDialog<_SuperLikeResult>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, __, ___) => _SuperLikeComposeOverlay(card: card),
      transitionBuilder: (context, anim, _, child) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return FadeTransition(opacity: curved, child: child);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final photo = card.photos.isNotEmpty ? card.photos.first : '';
    final title = card.age != null && card.age! > 0 ? '${card.name}, ${card.age}' : card.name;
    final distance = (card.distance ?? '').trim();
    final interests = card.interests;
    final bio = (card.bio ?? '').trim();

    final controller = TextEditingController();
    final focus = FocusNode();

    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 0.85),
      body: SafeArea(
        child: Stack(
          children: [
            // Background photo
            Positioned.fill(
              child: photo.isEmpty
                  ? const ColoredBox(color: Colors.black)
                  : CachedNetworkImage(imageUrl: photo, fit: BoxFit.cover),
            ),
            // Vignette
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.88),
                        Colors.black.withValues(alpha: 0.55),
                        Colors.black.withValues(alpha: 0.10),
                      ],
                      stops: const [0.0, .35, 1],
                    ),
                  ),
                ),
              ),
            ),

            // Card content
            Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: math.min(560, size.width - 24)),
                child: Padding(
                  padding: EdgeInsets.only(left: 12, right: 12, bottom: 12 + math.max(10, MediaQuery.of(context).padding.bottom)),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFF121217).withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                      boxShadow: const [BoxShadow(blurRadius: 28, color: Colors.black54, offset: Offset(0, 10))],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(
                          children: [
                            const Icon(Icons.auto_awesome, color: Colors.blueAccent),
                            const SizedBox(width: 8),
                            const Text('Super Like', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () => Navigator.of(context).pop<_SuperLikeResult>(null),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                        if (distance.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(Icons.place_outlined, size: 16, color: Colors.white70),
                              const SizedBox(width: 6),
                              Flexible(child: Text(distance, style: const TextStyle(color: Colors.white70))),
                            ],
                          ),
                        ],
                        if (bio.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(bio, maxLines: 3, overflow: TextOverflow.ellipsis),
                        ],
                        if (interests.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 6,
                            runSpacing: -6,
                            children: interests.take(5).map((t) {
                              return Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.35),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
                                ),
                                child: Text(t, style: const TextStyle(fontSize: 12, color: Colors.white)),
                              );
                            }).toList(),
                          ),
                        ],
                        const SizedBox(height: 14),

                        // Composer
                        TextField(
                          controller: controller,
                          focusNode: focus,
                          maxLines: 3,
                          minLines: 1,
                          textInputAction: TextInputAction.newline,
                          decoration: InputDecoration(
                            hintText: 'Send ${card.name} a note…',
                            hintStyle: const TextStyle(color: Colors.white70),
                            filled: true,
                            fillColor: const Color(0xFF0F0F14),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),

                        Row(children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.send),
                              label: const Text('Send & Super Like'),
                              onPressed: () {
                                final msg = controller.text.trim();
                                Navigator.of(context).pop<_SuperLikeResult>(_SuperLikeResult(msg.isEmpty ? '' : msg));
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blueAccent,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                          ),
                        ]),
                        const SizedBox(height: 8),
                        Center(
                          child: TextButton(
                            onPressed: () => Navigator.of(context).pop<_SuperLikeResult>(const _SuperLikeResult('')),
                            child: const Text('Just Super Like'),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Center(
                          child: Text(
                            'Super Likes that send a message can’t be undone.',
                            style: const TextStyle(fontSize: 12, color: Colors.white54),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ]),
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
}

// ────────────────────────────────────────────────────────────────────────────
// Small UI bits reused above

void unawaited(Future<void> f) {}

class _RoundAction extends StatelessWidget {
  const _RoundAction({required this.icon, required this.color, required this.size, this.scale = 1.0, this.onTap});
  final IconData icon;
  final Color color;
  final double size;
  final double scale;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    const Color bg = Color(0xFF1E1F24);
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: GestureDetector(
          onTap: onTap,
          child: Transform.scale(
            scale: scale.clamp(0.8, 1.35),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: bg,
                shape: BoxShape.circle,
                boxShadow: const [BoxShadow(blurRadius: 10, color: Colors.black38, offset: Offset(0, 4))],
                border: Border.all(color: color.withValues(alpha: 0.25), width: 1),
              ),
              child: Center(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 120),
                  opacity: onTap == null ? 0.4 : 0.9,
                  child: Icon(icon, color: color, size: size * 0.44),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _PresenceBucket { active, recent, offline }
class _PresenceInfo {
  final _PresenceBucket bucket;
  final String label;
  final Color color;
  const _PresenceInfo(this.bucket, this.label, this.color);
}
_PresenceInfo _presenceInfo({required bool isOnline, required dynamic lastSeenRaw}) {
  if (isOnline) return const _PresenceInfo(_PresenceBucket.active, 'Active now', Color(0xFF00E676));
  DateTime? toDt(dynamic v) => v == null ? null : DateTime.tryParse(v.toString());
  final lastSeen = toDt(lastSeenRaw);
  if (lastSeen == null) return const _PresenceInfo(_PresenceBucket.offline, 'Offline', Colors.white24);
  final now = DateTime.now().toUtc();
  final dt = lastSeen.isUtc ? lastSeen : lastSeen.toUtc();
  final diff = now.difference(dt);
  if (diff.inMinutes <= 10) return const _PresenceInfo(_PresenceBucket.recent, 'Recently active', Color(0xFFFFC107));
  String fmt() {
    if (diff.inMinutes < 60) return 'Last seen ${diff.inMinutes} m';
    if (diff.inHours < 24) return 'Last seen ${diff.inHours} h';
    return 'Last seen ${diff.inDays} d';
  }
  return _PresenceInfo(_PresenceBucket.offline, fmt(), Colors.white24);
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.text, required this.color});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
      ]),
    );
  }
}

class _PresenceIndicator extends StatelessWidget {
  const _PresenceIndicator({required this.presence});
  final _PresenceInfo presence;
  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      if (presence.bucket == _PresenceBucket.active)
        const Positioned(
          top: 14, left: 14,
          child: DecoratedBox(
            decoration: BoxDecoration(color: Color(0xFF00E676), shape: BoxShape.circle, boxShadow: [BoxShadow(color: Color(0x8000E676), blurRadius: 8)]),
            child: SizedBox(width: 12, height: 12),
          ),
        ),
      Positioned(top: 12, left: 34, child: _StatusChip(text: presence.label, color: presence.color)),
    ]);
  }
}

// Info/footer

class _InfoGradient extends StatelessWidget {
  const _InfoGradient({
    required this.name,
    required this.age,
    required this.distance,
    required this.bio,
    required this.onTap,
    this.interests,
  });

  final String name;
  final int age;
  final String distance;
  final String bio;
  final VoidCallback onTap;
  final List<String>? interests;

  @override
  Widget build(BuildContext context) {
    const double reserveForBottomBar = 96;

    return Positioned(
      left: 0, right: 0, bottom: -20,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14 + reserveForBottomBar),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                Color.fromARGB(240, 0, 0, 0),
                Color.fromARGB(200, 0, 0, 0),
                Color.fromARGB(102, 0, 0, 0),
              ],
              stops: [0.0, 0.55, 1.0],
            ),
            borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                age > 0 ? '$name, $age' : name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              if (distance.isNotEmpty)
                Row(
                  children: [
                    const Icon(Icons.place_outlined, size: 16, color: Colors.white70),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        distance,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                    ),
                  ],
                ),
              if (bio.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  bio,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ],
              if ((interests?.isNotEmpty ?? false)) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: -6,
                  children: interests!.take(3).map((t) {
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
                      ),
                      child: Text(
                        t,
                        style: const TextStyle(fontSize: 12, color: Colors.white),
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }).toList(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PhotoDots extends StatelessWidget {
  const _PhotoDots({required this.currentIndex, required this.count});
  final int currentIndex;
  final int count;
  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 14, left: 0, right: 0,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(count, (dot) => Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: 9, height: 9,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: dot == currentIndex ? kBrandPink : Colors.grey.withValues(alpha: 0.5),
          ),
        )),
      ),
    );
  }
}

class _SkeletonFeed extends StatelessWidget {
  const _SkeletonFeed();
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F14),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: const Center(
        child: SizedBox(
          width: 160,
          height: 16,
          child: ShimmerLine(height: 16, widthFactor: 0.6),
        ),
      ),
    );
  }
}

class _OutOfPeopleScrollable extends StatelessWidget {
  const _OutOfPeopleScrollable({
    required this.onAdjustFilters,
    required this.onRetry,
    required this.onExpandRadius,
  });

  final VoidCallback onAdjustFilters;
  final VoidCallback onRetry;
  final Future<void> Function(double km) onExpandRadius;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        padding: EdgeInsets.only(bottom: 12 + MediaQuery.of(context).padding.bottom),
        physics: const BouncingScrollPhysics(),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight),
            child: Align(
              alignment: Alignment.topCenter,
              child: _OutOfPeoplePage(
                onAdjustFilters: onAdjustFilters,
                onRetry: onRetry,
                onExpandRadius: onExpandRadius,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OutOfPeoplePage extends StatelessWidget {
  const _OutOfPeoplePage({
    required this.onAdjustFilters,
    required this.onRetry,
    required this.onExpandRadius,
  });

  final VoidCallback onAdjustFilters;
  final VoidCallback onRetry;
  final Future<void> Function(double km) onExpandRadius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const pink = Color(0xFFFF0F7B);
    const indigo = Color(0xFF6759FF);
    final fg = Colors.white.withValues(alpha: 0.94);
    double distance = 19;

    return StatefulBuilder(builder: (context, setLocal) {
      Future<void> handleExpand() async {
        await onExpandRadius(distance);
      }

      Future<void> handleCopyInvite() async {
        const invite = 'https://your-app.example/invite';
        await Clipboard.setData(const ClipboardData(text: invite));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Invite link copied — thanks for spreading the word!')),
          );
        }
      }

      return Container(
        padding: const EdgeInsets.fromLTRB(22, 26, 22, 20),
        decoration: BoxDecoration(
          color: const Color(0xFF0F0F14),
          borderRadius: BorderRadius.circular(28),
          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 30, offset: Offset(0, 16))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 140, height: 140,
            child: Stack(alignment: Alignment.center, children: [
              Container(
                width: 140, height: 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [pink.withValues(alpha: 0.12), Colors.transparent]),
                ),
              ),
              Container(
                width: 92, height: 92,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: pink.withValues(alpha: 0.25), width: 4),
                ),
              ),
              Container(
                width: 56, height: 56,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [indigo, pink]),
                  boxShadow: [BoxShadow(blurRadius: 16, color: Colors.black45)],
                ),
              ),
            ]),
          ),

          const SizedBox(height: 20),
          Text(
            'No more profiles (for now) 💫',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: fg),
          ),
          const SizedBox(height: 8),
          Text(
            'More people join every day. Help spread the word and check back tomorrow.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
          ),

          const SizedBox(height: 22),
          Row(children: [
            Expanded(
              child: Slider(
                value: distance,
                min: 1,
                max: 100,
                onChanged: (v) => setLocal(() => distance = v),
              ),
            ),
            const SizedBox(width: 8),
            Text('${distance.round()} km', style: theme.textTheme.bodyMedium?.copyWith(color: fg)),
          ]),
          const SizedBox(height: 18),

          SizedBox(
            width: double.infinity, height: 52,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                padding: EdgeInsets.zero,
                backgroundColor: Colors.transparent,
                elevation: 0,
              ).merge(ButtonStyle(elevation: WidgetStateProperty.all(0.0))),
              onPressed: handleExpand,
              child: Ink(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [indigo, pink]),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Center(
                  child: Text(
                    'Expand radius to ${distance.round()} km',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white, fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 12),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF14151A),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                const Icon(Icons.campaign, color: Colors.white70),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Tell a friend and grow the community',
                    style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
                  ),
                ),
                TextButton.icon(
                  onPressed: handleCopyInvite,
                  icon: const Icon(Icons.link, size: 18),
                  label: const Text('Copy link'),
                ),
              ],
            ),
          ),

          const SizedBox(height: 10),
          TextButton(onPressed: onAdjustFilters, child: const Text('Go to my settings')),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
        ]),
      );
    });
  }
}

enum _SwipeKind { left, right, up, rewind }
class _SwipeIntent extends Intent {
  final _SwipeKind kind;
  const _SwipeIntent.left() : kind = _SwipeKind.left;
  const _SwipeIntent.right() : kind = _SwipeKind.right;
  const _SwipeIntent.up() : kind = _SwipeKind.up;
  const _SwipeIntent.rewind() : kind = _SwipeKind.rewind;
}

// Host for filters sheet
class _FiltersHost extends StatelessWidget {
  const _FiltersHost();
  @override
  Widget build(BuildContext context) {
    return const Material(
      color: Colors.transparent,
      child: FilterMatchesSheet(),
    );
  }
}