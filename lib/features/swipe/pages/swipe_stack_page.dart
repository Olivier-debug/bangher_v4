// ============================================================================
// lib/features/swipe/pages/swipe_stack_page.dart
// Stable bottom bar (no jumping) + robust undo state + empty deck fixes.
// Prefill profile open (uses the same SwipeCard + photos; no re-fetch).
// Fuller, stable card width on mobile. Replaced withOpacity -> withValues.
// NOTE: Minimal change: add resolved_photos (rotated) to prefill so images
//       don't reload/flicker on ViewProfilePage first paint.
// ============================================================================

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

import '../presentation/swipe_models.dart'; // defines SwipeCard (feed model)
import '../presentation/controllers/swipe_controller.dart';
import '../presentation/swipe_ui_controllers.dart';
// Import only what we need from profile page to avoid symbol clashes.
import '../../profile/pages/view_profile_page.dart' show ViewProfilePage;
import '../../swipe/data/swipe_feed_cache.dart';
import '../../../filters/filter_matches_sheet.dart';

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
  Config('profileCacheKey', stalePeriod: const Duration(days: 7), maxNrOfCacheObjects: 1000),
);

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

  // Global controller so index persists between navigations.
  SwipableStackController get _stack => ref.read(swipeStackControllerProvider);

  final ValueNotifier<(SwipeDirection?, double)> _overlayVN =
      ValueNotifier<(SwipeDirection?, double)>((null, 0.0));

  double? _lastCardW, _lastCardH;

  String? _firstCardIdSeen;
  String? _lastTopCardId;

  bool _toppingUp = false;
  DateTime _lastTopUpAt = DateTime.fromMillisecondsSinceEpoch(0);

  final FocusNode _focusNode = FocusNode(debugLabel: 'SwipeStackFocus');

  final Map<String, List<String?>> _urlOverridesByCard = <String, List<String?>>{};
  final Set<String> _refreshingUrls = <String>{};

  int _lastIndexSeen = -1;
  late final VoidCallback _stackListener;

  // Fixed bottom bar height so layout never jumps.
  static const double _kBottomBarHeight = 88;

  @override
  void initState() {
    super.initState();
    logSwipe('initState()');
    WidgetsBinding.instance.addObserver(this);
    _stackListener = _onStackChanged;
    _stack.addListener(_stackListener);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      logSwipe('postFrame -> bootstrapIfNeeded()');
      ref.read(swipeControllerProvider.notifier).bootstrapIfNeeded();
      _focusNode.requestFocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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
    super.dispose();
  }

  void _onStackChanged() {
    final cur = _stack.currentIndex;
    if (cur != _lastIndexSeen) {
      _lastIndexSeen = cur;
      _overlayVN.value = (null, 0.0);

      final st = ref.read(swipeControllerProvider);
      if (cur >= 0 && cur < st.cards.length) {
        final id = st.cards[cur].id;
        _lastTopCardId = id;
        ref.read(swipeControllerProvider.notifier).markTopCardId(id);
        logSwipe('_onStackChanged: cur=$cur total=${st.cards.length}');
        logSwipe('_onStackChanged: topId=$id');
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
      _topUpIfNeeded();
    }
  }

  @override
  bool get wantKeepAlive => true;

  // ── Cache helpers ──────────────────────────────────────────────────────────

  String _cacheKeyForUrl(String url) {
    if (kIsWeb) return url;
    final q = url.indexOf('?');
    return q == -1 ? url : url.substring(0, q);
  }

  bool _isSupabaseSignedUrl(String url) {
    final u = Uri.tryParse(url);
    return u != null && u.path.contains('/storage/v1/object/sign/');
  }

  (String, String)? _parseBucketAndPathFromSignedUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final segs = uri.pathSegments;
    final signIdx = segs.indexOf('sign');
    if (signIdx < 0 || signIdx + 1 >= segs.length) return null;
    final bucket = segs[signIdx + 1];
    final rest = segs.sublist(signIdx + 2);
    if (bucket.isEmpty || rest.isEmpty) return null;
    final objectPath = rest.map(Uri.decodeComponent).join('/');
    return (bucket, objectPath);
  }

  Future<void> _refreshSignedUrlFor({
    required String cardId,
    required int photoIndex,
    required String currentUrl,
  }) async {
    if (!_isSupabaseSignedUrl(currentUrl)) return;
    if (!_refreshingUrls.add(currentUrl)) return;
    try {
      final parsed = _parseBucketAndPathFromSignedUrl(currentUrl);
      if (parsed == null) return;
      final (bucket, objectPath) = parsed;

      final stableKey = _cacheKeyForUrl(currentUrl);
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

  // ── Data bootstrap / top-up ────────────────────────────────────────────────

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

  // ── Build ──────────────────────────────────────────────────────────────────

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

    return Focus(
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
                    _openViewProfileWithPrefill(state.cards[idx]); // open with same data/photos
                  }
                  break;
                case _SwipeKind.rewind:
                  break;
              }
              return null;
            }),
          },
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  // Tighter gutters so the card feels "full" on mobile.
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: (totalCards == 0 || showEmptyNow)
                      ? (state.fetching
                          ? const _SkeletonFeed()
                          : _OutOfPeopleScrollable(
                              onAdjustFilters: _openFiltersScreen,
                              onRetry: _bootstrap,
                            ))
                      : _buildStack(state, totalCards),
                ),
              ),
              // Only hide the bar on the "no more matches" screen.
              if (!showEmptyNow) _bottomBar(totalCards, enabled: true),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStack(SwipeUiState state, int totalCards) {
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;

        // Stable, full card width on phones: 8px gutters.
        // On wide screens, keep it at ~66% to avoid over-stretching.
        double cardW;
        if (size.width <= 700) {
          cardW = (size.width - 16).clamp(280.0, 720.0); // stable across swipes
        } else {
          cardW = (size.width * 0.66).clamp(560.0, 920.0);
        }
        final double cardH = size.height;

        final needSizeUpdate = (_lastCardW == null || (_lastCardW! - cardW).abs() > 0.5) ||
            (_lastCardH == null || (_lastCardH! - cardH).abs() > 0.5);
        if (needSizeUpdate) {
          _lastCardW = cardW;
          _lastCardH = cardH;
        }

        // Preload a few ahead
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final base = _stack.currentIndex + 1;
          for (int i = base; i < math.min(base + 3, state.cards.length); i++) {
            final photos = state.cards[i].photos;
            if (photos.isEmpty) continue;
            final url = _overrideUrlIfAny(state.cards[i].id, 0, photos.first);
            if (url.isEmpty) continue;
            final prov = CachedNetworkImageProvider(
              url,
              cacheManager: customCacheManager,
              cacheKey: _cacheKeyForUrl(url),
            );
            precacheImage(prov, context).catchError((_) {});
          }
        });

        return Center(
          child: SizedBox(
            width: cardW,
            height: cardH,
            child: SwipableStack(
              controller: _stack,
              detectableSwipeDirections: const {
                SwipeDirection.left,
                SwipeDirection.right,
                SwipeDirection.up,
              },
              horizontalSwipeThreshold: 0.28,
              verticalSwipeThreshold: 0.28,
              overlayBuilder: (context, props) {
                final dir = props.direction;
                final raw = props.swipeProgress;
                final p = raw.isNaN ? 0.0 : raw.clamp(0.0, 1.0).toDouble();

                final prev = _overlayVN.value;
                if (prev.$1 != dir || prev.$2 != p) {
                  scheduleMicrotask(() {
                    if (mounted) _overlayVN.value = (dir, p);
                  });
                }

                return Stack(
                  children: [
                    if (p > 0)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              boxShadow: [
                                BoxShadow(
                                  color: (dir == SwipeDirection.right
                                          ? Colors.greenAccent
                                          : dir == SwipeDirection.left
                                              ? Colors.redAccent
                                              : Colors.lightBlueAccent)
                                      .withValues(alpha: p * 0.25),
                                  blurRadius: 40 * p,
                                  spreadRadius: 6 * p,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (dir == SwipeDirection.right && p > 0)
                      Positioned(top: 24, left: 18, child: _swipeLabel('LIKE', Colors.greenAccent.withValues(alpha: p), p)),
                    if (dir == SwipeDirection.left && p > 0)
                      Positioned(top: 24, right: 18, child: _swipeLabel('NOPE', Colors.redAccent.withValues(alpha: p), p)),
                    if (dir == SwipeDirection.up && p > 0)
                      const Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [Color(0x6600C6FF), Color(0x0000C6FF)],
                                stops: [0.0, 0.7],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
              onWillMoveNext: (index, direction) {
                // index is real index into cards (itemCount is total)
                final cards = state.cards;
                if (index < 0 || index >= cards.length) return false;
                if (index < _stack.currentIndex) return false; // ignore stale callbacks

                logSwipe('onWillMoveNext: index=$index dir=$direction cur=${_stack.currentIndex}');
                if (direction == SwipeDirection.up) {
                  _openViewProfileWithPrefill(cards[index]); // use prefill (no re-fetch)
                  HapticFeedback.selectionClick();
                  return false;
                }
                return true;
              },
              onSwipeCompleted: (index, direction) async {
                final cards = ref.read(swipeControllerProvider).cards;
                if (index < 0 || index >= cards.length) return;
                if (index < _stack.currentIndex - 1) return; // guard

                final card = cards[index];
                final liked = direction == SwipeDirection.right;

                logSwipe('onSwipeCompleted: idx=$index dir=$direction curBefore=${_stack.currentIndex} '
                    'totalBefore=${cards.length} id=${card.id}');
                SwipeUndoStore.instance.push(cardMap: card.toCacheMap(), index: index);

                try {
                  logCtrl('swipeCard: id=${card.id} liked=$liked pendingBefore=0');
                  await ref.read(swipeControllerProvider.notifier).swipeCard(swipeeId: card.id, liked: liked);
                  HapticFeedback.lightImpact();
                } finally {
                  _overlayVN.value = (null, 0.0);

                  // Compact cache (keep top, last 3 swiped, next 20)
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

                  // Top-up logic
                  final stillTotal = ref.read(swipeControllerProvider).cards.length;
                  final remainingAhead = math.max(0, stillTotal - (_stack.currentIndex + 1));
                  logSwipe('onSwipeCompleted: DONE curAfter=${_stack.currentIndex} totalAfter=$stillTotal');
                  logSwipe('topupCheck: remainingAhead=$remainingAhead threshold=$_kTopUpThreshold');

                  if (remainingAhead <= _kTopUpThreshold) {
                    logSwipe('topup: _topUpIfNeeded()');
                    await _topUpIfNeeded();
                  }

                  final topIdNow = _topCardId();
                  ref.read(swipeControllerProvider.notifier).markTopCardId(topIdNow);
                  logCtrl('markTopCardId: $topIdNow');

                  final visibleNow = math.max(0, stillTotal - _stack.currentIndex);
                  if (visibleNow == 0) {
                    await ref.read(swipeControllerProvider.notifier).markExhaustedIfDepleted(visibleCount: 0);
                  }
                  if (mounted) setState(() {}); // refresh undo button etc.
                }
              },
              // keep total itemCount constant
              itemCount: totalCards,
              builder: (context, props) {
                final i = props.index;

                // Skip past cards; never shrink itemCount during swipe.
                if (i < _stack.currentIndex) return const SizedBox.shrink();

                if (i < 0 || i >= state.cards.length) return const SizedBox.shrink();
                final card = state.cards[i];
                final isTopCard = (i == _stack.currentIndex);

                return KeyedSubtree(
                  key: ValueKey(card.id),
                  child: _card(isTopCard, i, card, _lastCardW ?? 0, _lastCardH ?? 0),
                );
              },
            ),
          ),
        );
      },
    );
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
    photoIndexById.putIfAbsent(userId, () => 0);

    final maxIdx = photos.isEmpty ? 0 : photos.length - 1;
    final int currentIndex = (photoIndexById[userId] ?? 0).clamp(0, maxIdx).toInt();

    final String? rawCurrent = photos.isEmpty ? null : photos[currentIndex];
    final String? currentPhoto = (rawCurrent == null) ? null : _overrideUrlIfAny(userId, currentIndex, rawCurrent);

    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        width: _lastCardW ?? cardW,
        height: _lastCardH ?? cardH,
        decoration: const BoxDecoration(
          boxShadow: [BoxShadow(blurRadius: 22, color: Colors.black45, offset: Offset(0, 14))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            width: _lastCardW ?? cardW,
            height: _lastCardH ?? cardH,
            child: LayoutBuilder(
              builder: (context, c) {
                final cw = c.maxWidth;

                if (photos.length > 1) {
                  final int nextIdx = (currentIndex + 1 <= maxIdx) ? currentIndex + 1 : maxIdx;
                  final int prevIdx = (currentIndex - 1 >= 0) ? currentIndex - 1 : 0;
                  for (final int idx in <int>{nextIdx, prevIdx}) {
                    final orig = photos[idx];
                    final url = _overrideUrlIfAny(userId, idx, orig);
                    if (url.isEmpty) continue;
                    final provider = CachedNetworkImageProvider(
                      url,
                      cacheManager: customCacheManager,
                      cacheKey: _cacheKeyForUrl(url),
                    );
                    precacheImage(provider, context).catchError((_) {});
                  }
                }

                final imageCore = currentPhoto == null
                    ? const ColoredBox(color: Colors.black26)
                    : Image(
                        image: CachedNetworkImageProvider(
                          currentPhoto,
                          cacheManager: customCacheManager,
                          cacheKey: _cacheKeyForUrl(currentPhoto),
                        ),
                        fit: BoxFit.cover,
                        alignment: Alignment.center,
                        width: _lastCardW ?? cardW,
                        height: _lastCardH ?? cardH,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.medium,
                        frameBuilder: (ctx, child, frame, wasSync) {
                          final visible = frame != null || wasSync;
                          return AnimatedOpacity(opacity: visible ? 1.0 : 0.0, duration: const Duration(milliseconds: 120), child: child);
                        },
                        errorBuilder: (_, __, ___) {
                          _refreshSignedUrlFor(cardId: userId, photoIndex: currentIndex, currentUrl: currentPhoto);
                          return Container(
                            color: Colors.grey[850],
                            child: const Center(
                              child: Icon(Icons.image_not_supported_outlined, color: Colors.white70, size: 48),
                            ),
                          );
                        },
                      );

                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) {
                    if (photos.length < 2) return;
                    final isRight = details.localPosition.dx > cw / 2;
                    final int n = (currentIndex + (isRight ? 1 : -1)).clamp(0, maxIdx).toInt();
                    photoIndexByIdNotifier.state = {...photoIndexById, userId: n};
                    HapticFeedback.selectionClick();
                  },
                  onLongPress: () => _openViewProfileWithPrefill(data), // open with same data/photos
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: isTopCard
                            ? Hero(
                                tag: 'public_profile_photo_$userId',
                                child: AnimatedBuilder(
                                  animation: Listenable.merge([_stack, _overlayVN]),
                                  builder: (_, __) {
                                    final (d, p) = _overlayVN.value;
                                    final dx = (d == SwipeDirection.left ? -1 : d == SwipeDirection.right ? 1 : 0) * p * 8;
                                    final dy = (d == SwipeDirection.up ? -1 : 0) * p * 8;
                                    final tilt = (d == SwipeDirection.left ? -1 : d == SwipeDirection.right ? 1 : 0) * p * 0.02;
                                    return Transform(
                                      alignment: Alignment.center,
                                      transform: Matrix4.translationValues(dx, dy, 0)..rotateZ(tilt),
                                      child: Transform.scale(
                                        scale: 1.06 + p * 0.02,
                                        child: imageCore,
                                      ),
                                    );
                                  },
                                ),
                              )
                            : Transform.scale(scale: 1.06, child: imageCore),
                      ),
                      if (photos.length > 1) _PhotoDots(currentIndex: currentIndex, count: photos.length),
                      _PresenceIndicator(presence: _presenceInfo(isOnline: data.isOnline, lastSeenRaw: data.lastSeen)),
                      _InfoGradient(
                        name: name,
                        age: age,
                        distance: distance,
                        bio: bio,
                        interests: data.interests,
                        onTap: () => _openViewProfileWithPrefill(data), // same data/photos
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  String _overrideUrlIfAny(String cardId, int index, String original) {
    final list = _urlOverridesByCard[cardId];
    if (list == null) return original;
    if (index < 0 || index >= list.length) return original;
    final o = list[index];
    return (o == null || o.isEmpty) ? original : o;
  }

  // ── Bottom bar ─────────────────────────────────────────────────────────────

  // Use the same sizing logic as the stack before _lastCardW is known.
  double _projectedCardWidth(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    if (w <= 700) {
      return (w - 16).clamp(280.0, 720.0);
    } else {
      return (w * 0.66).clamp(560.0, 920.0);
    }
  }

  Widget _bottomBar(int totalCards, {required bool enabled}) {
    // Keep a stable footprint.
    final bottomPadding = 12 + MediaQuery.of(context).padding.bottom * .6;

    // Stable from the first frame (even before _lastCardW is measured).
    final double cardW = _lastCardW ?? _projectedCardWidth(context);
    final barWidth = math.max(cardW - 8, 220.0);

    // Button sizes derived from card width but don't affect fixed height.
    final double btn = cardW < 320 ? 52 : (cardW < 360 ? 58 : 62);
    final double bigBtn = btn + 10;

    final hasCard = enabled && _stack.currentIndex >= 0 && _stack.currentIndex < totalCards;
    // Accurate undo: only when there is an item in the undo store
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
              final (dir, pRaw) = tuple;
              final p = enabled ? pRaw.clamp(0.0, 1.0) : 0.0;

              double nopeScale = 1.0, superLikeScale = 1.0, likeScale = 1.0, rewindScale = 1.0;
              Color nopeColor = Colors.redAccent,
                  superLikeColor = Colors.blueAccent,
                  likeColor = Colors.greenAccent,
                  rewindColor = Colors.white24,
                  boostColor = Colors.purple;

              if (enabled) {
                if (dir == SwipeDirection.left) {
                  nopeScale = 1 + p * 0.3;
                  nopeColor = Colors.redAccent.withValues(alpha: 0.5 + p * 0.5);
                } else if (dir == SwipeDirection.right) {
                  likeScale = 1 + p * 0.3;
                  likeColor = Colors.greenAccent.withValues(alpha: 0.5 + p * 0.5);
                } else if (dir == SwipeDirection.up) {
                  superLikeScale = 1 + p * 0.3;
                  superLikeColor = Colors.blueAccent.withValues(alpha: 0.5 + p * 0.5);
                }
              }

              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Semantics(
                    button: true,
                    label: 'Rewind last',
                    enabled: canUndo,
                    child: _RoundAction(
                      icon: Icons.rotate_left,
                      color: canUndo ? Colors.white : rewindColor,
                      size: btn,
                      scale: rewindScale,
                      onTap: canUndo ? _undoLast : null,
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: 'Nope',
                    child: _RoundAction(
                      icon: Icons.cancel,
                      color: hasCard ? nopeColor : Colors.white24,
                      size: btn,
                      scale: nopeScale,
                      onTap: hasCard ? () => _stack.next(swipeDirection: SwipeDirection.left) : null,
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: 'Super-like (view profile)',
                    child: _RoundAction(
                      icon: Icons.star,
                      color: hasCard ? superLikeColor : Colors.white24,
                      size: bigBtn,
                      scale: superLikeScale,
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
                  Semantics(
                    button: true,
                    label: 'Like',
                    child: _RoundAction(
                      icon: Icons.favorite,
                      color: hasCard ? likeColor : Colors.white24,
                      size: btn,
                      scale: likeScale,
                      onTap: hasCard ? () => _stack.next(swipeDirection: SwipeDirection.right) : null,
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: 'Boost',
                    child: _RoundAction(
                      icon: Icons.flash_on,
                      color: enabled ? boostColor : Colors.white24,
                      size: btn,
                      scale: 1.0,
                      onTap: enabled ? () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Boost sent ✨'))) : null,
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
    if (_stack.currentIndex > 0) {
      _stack.rewind(); // visual only; list never mutated
    }
    final snap = SwipeUndoStore.instance.take();
    final id = snap?.cardMap['potential_match_id']?.toString();
    if (id != null && id.isNotEmpty) {
      try {
        logCtrl('undo: $id');
        await ref.read(swipeControllerProvider.notifier).undo(swipeeId: id);
        HapticFeedback.selectionClick();
      } catch (_) {/* ignore */}
    }
    ref.read(swipeControllerProvider.notifier).markTopCardId(_topCardId());
    if (mounted) setState(() {}); // refresh undo button state
  }

  String? _topCardId() {
    final st = ref.read(swipeControllerProvider);
    final idx = _stack.currentIndex;
    if (idx < 0 || idx >= st.cards.length) return null;
    return st.cards[idx].id;
  }

  // New: open profile page using the SAME SwipeCard (no re-fetch for initial render).
  void _openViewProfileWithPrefill(SwipeCard card) {
    if (card.id.isEmpty) return;

    // Build a plain map with keys the profile page understands.
    // Only include fields that exist on SwipeCard to avoid undefined getter errors.
    final prefill = <String, dynamic>{
      'user_id': card.id,
      'name': card.name,
      'age': card.age,
      'bio': card.bio,
      'profile_pictures': card.photos, // reuse exact storage/URLs
      'interests': card.interests,
      'distance': card.distance,
      'is_online': card.isOnline,
      'last_seen': card.lastSeen,
    }..removeWhere((_, v) => v == null);

    // Ensure types are exact and current photo leads
    final List<String> photos = card.photos;
    if (photos.isNotEmpty) {
      final idxMap = ref.read(photoIndexByIdProvider);
      final int cur = (idxMap[card.id] ?? 0)
          .clamp(0, math.max(0, photos.length - 1))
          .toInt();

      final effective = <String>[];
      for (int i = 0; i < photos.length; i++) {
        final raw = photos[i];
        final u = _overrideUrlIfAny(card.id, i, raw);
        if (u.isNotEmpty) effective.add(u);
      }

      if (effective.isNotEmpty) {
        final rotated = <String>[
          ...effective.skip(cur),
          ...effective.take(cur),
        ];
        prefill['resolved_photos'] = rotated;
      }
    }

    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, __, ___) => ViewProfilePage(
          userId: card.id,
          prefill: prefill, // Map<String, dynamic> prefill
        ),
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

  // Wrap FilterMatchesSheet with a Material ancestor to satisfy Ink widgets.
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

  Widget _swipeLabel(String text, Color color, double opacity) => Transform.rotate(
        angle: -math.pi / 14,
        child: Text(
          text,
          style: TextStyle(
            letterSpacing: 2,
            fontWeight: FontWeight.w800,
            fontSize: 20,
            color: color.withValues(alpha: opacity),
          ),
        ),
      );
}

// ────────────────────────────────────────────────────────────────────────────
// Small UI bits reused above

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
            // visual pulse only; outer box footprint is constant
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

class _InfoGradient extends StatelessWidget {
  const _InfoGradient({required this.name, required this.age, required this.distance, required this.bio, required this.onTap, this.interests});
  final String name;
  final int age;
  final String distance;
  final String bio;
  final VoidCallback onTap;
  final List<String>? interests;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0, right: 0, bottom: 0,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter, end: Alignment.topCenter,
              colors: [Color.fromARGB(230, 0, 0, 0), Color.fromARGB(150, 0, 0, 0), Color.fromARGB(60, 0, 0, 0)],
              stops: [0.0, 0.5, 1.0],
            ),
            borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(age > 0 ? '$name, $age' : name, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            if (distance.isNotEmpty)
              Row(children: [
                const Icon(Icons.place_outlined, size: 16, color: Colors.white70),
                const SizedBox(width: 6),
                Flexible(child: Text(distance, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 14))),
              ]),
            if (bio.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(bio, maxLines: 4, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 14)),
            ],
            if ((interests?.isNotEmpty ?? false)) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6, runSpacing: -6,
                children: interests!.take(3).map((t) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                  ),
                  child: Text(t, style: const TextStyle(fontSize: 12)),
                )).toList(),
              ),
            ],
          ]),
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
            color: dot == currentIndex ? Colors.pink : Colors.grey.withValues(alpha: 0.5),
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
        border: Border.all(color: Colors.white.withValues(alpha: .10)),
      ),
      child: const Center(child: SizedBox(width: 160, height: 16, child: _ShimmerLine(height: 16, widthFactor: .6))),
    );
  }
}

// Scrollable wrapper to avoid overflow on short devices when deck is empty.
class _OutOfPeopleScrollable extends StatelessWidget {
  const _OutOfPeopleScrollable({required this.onAdjustFilters, required this.onRetry});
  final VoidCallback onAdjustFilters;
  final VoidCallback onRetry;

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
              child: _OutOfPeoplePage(onAdjustFilters: onAdjustFilters, onRetry: onRetry),
            ),
          ),
        ),
      ),
    );
  }
}

class _OutOfPeoplePage extends StatelessWidget {
  const _OutOfPeoplePage({required this.onAdjustFilters, required this.onRetry});
  final VoidCallback onAdjustFilters;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const pink = Color(0xFFFF0F7B);
    const indigo = Color(0xFF6759FF);
    final fg = Colors.white.withValues(alpha: .94);
    double distance = 19;

    return StatefulBuilder(builder: (context, setLocal) {
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
                decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [pink.withValues(alpha: .12), Colors.transparent])),
              ),
              Container(width: 92, height: 92, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: pink.withValues(alpha: .25), width: 4))),
              Container(width: 56, height: 56, decoration: const BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [indigo, pink]), boxShadow: [BoxShadow(blurRadius: 16, color: Colors.black45)])),
            ]),
          ),
          const SizedBox(height: 20),
          Text('You ran out of people.', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: fg)),
          const SizedBox(height: 8),
          Text('Expand your distance settings to see more people in your area.', textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70)),
          const SizedBox(height: 22),
          Row(children: [
            Expanded(child: Slider(value: distance, min: 1, max: 100, onChanged: (v) => setLocal(() => distance = v))),
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
              onPressed: onAdjustFilters,
              child: Ink(
                decoration: BoxDecoration(gradient: const LinearGradient(colors: [indigo, pink]), borderRadius: BorderRadius.circular(22)),
                child: Center(child: Text('Done', style: theme.textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800))),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(onPressed: onAdjustFilters, child: const Text('Go to my settings')),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
        ]),
      );
    });
  }
}

class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.child});
  final Widget child;
  @override
  State<_Shimmer> createState() => _ShimmerState();
}
class _ShimmerState extends State<_Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    const Color base = Color(0xFF2A2C31);
    const Color highlight = Color(0xFF3A3D44);
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final t = _ctrl.value;
        return ShaderMask(
          shaderCallback: (rect) {
            final dx = rect.width;
            final double x = (2 * dx) * t - dx;
            return const LinearGradient(
              begin: Alignment.centerLeft, end: Alignment.centerRight,
              colors: [base, highlight, base], stops: [0.35, 0.50, 0.65],
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
class _ShimmerLine extends StatelessWidget {
  const _ShimmerLine({required this.height, this.widthFactor});
  final double height;
  final double? widthFactor;
  @override
  Widget build(BuildContext context) {
    Widget box = const _ShimmerBox(height: 16, radius: 6);
    if (widthFactor != null) box = FractionallySizedBox(widthFactor: widthFactor, child: box);
    return box;
  }
}
class _ShimmerBox extends StatelessWidget {
  const _ShimmerBox({this.height, this.radius = 8});
  final double? height;
  final double radius;
  @override
  Widget build(BuildContext context) {
    return _Shimmer(
      child: Container(height: height, decoration: BoxDecoration(color: const Color(0xFF2A2C31), borderRadius: BorderRadius.circular(radius))),
    );
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

// ────────────────────────────────────────────────────────────────────────────
// Host that provides a Material ancestor for the filters sheet (fixes Ink).
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
