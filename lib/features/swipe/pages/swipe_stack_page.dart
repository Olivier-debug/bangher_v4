// ─────────────────────────────────────────────────────────────────────────────
// lib/features/swipe/pages/test_swipe_stack_page.dart
// - Trim only on real navigation via RouteObserver (didPushNext/didPopNext)
// - Global Undo persistence (SwipeUndoStore)
// - Smooth photo switch via AnimatedSwitcher + frameBuilder fade
// - Signed URL auto-refresh with stable cache keys
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:swipable_stack/swipable_stack.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Local
import '../presentation/swipe_models.dart';
import '../presentation/controllers/swipe_controller.dart';
import '../../profile/pages/view_profile_page.dart';
import '../presentation/widgets/finding_nearby_loading.dart';
import '../data/swipe_feed_cache.dart'; // SwipeUndoStore lives here

// ── Register this in your MaterialApp:
// MaterialApp(navigatorObservers: [routeObserver], ...);
final RouteObserver<ModalRoute<void>> routeObserver = RouteObserver<ModalRoute<void>>();

// ── Local UI prefs (quick filters)
final prefGenderProvider = StateProvider<String>((_) => 'A'); // A=All, F, M
final prefAgeMinProvider = StateProvider<int>((_) => 18);
final prefAgeMaxProvider = StateProvider<int>((_) => 60);
final prefRadiusKmProvider = StateProvider<double>((_) => 50.0);

// per-user photo index (tap left/right on photo)
final photoIndexByIdProvider =
    StateProvider<Map<String, int>>((_) => <String, int>{});

// safer (non-const) cache manager
final customCacheManager = CacheManager(
  Config(
    'profileCacheKey',
    stalePeriod: const Duration(days: 7),
    maxNrOfCacheObjects: 1000,
  ),
);

class TestSwipeStackPage extends ConsumerStatefulWidget {
  const TestSwipeStackPage({super.key});

  static const String routeName = 'SwipePage';
  static const String routePath = '/swipe';

  @override
  ConsumerState<TestSwipeStackPage> createState() => _TestSwipeStackPageState();
}

class _TestSwipeStackPageState extends ConsumerState<TestSwipeStackPage>
    with
        AutomaticKeepAliveClientMixin,
        TickerProviderStateMixin,
        WidgetsBindingObserver,
        RouteAware {
  static const int _kKeepBack = 5;
  static const int _kTopUpThreshold = 3;

  late SwipableStackController _stack;

  // Overlay signal (dir, progress) without provider churn.
  final ValueNotifier<(SwipeDirection?, double)> _overlayVN =
      ValueNotifier<(SwipeDirection?, double)>((null, 0.0));

  // sizes for correct decode/precache
  double? _lastCardW, _lastCardH;

  // feed identity / controller epoch
  String? _firstCardIdSeen;
  int _stackEpoch = 0;

  // persist current index across tab switches
  int _persistedIndex = -1;

  // top-up guards
  bool _toppingUp = false;
  DateTime _lastTopUpAt = DateTime.fromMillisecondsSinceEpoch(0);

  // focus for keyboard shortcuts
  final FocusNode _focusNode = FocusNode(debugLabel: 'SwipeStackFocus');

  // ── Signed URL auto-refresh support
  final Map<String, List<String?>> _urlOverridesByCard = <String, List<String?>>{};
  final Set<String> _refreshingUrls = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _stack = SwipableStackController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(swipeControllerProvider.notifier).bootstrapAndFirstLoad();
      _focusNode.requestFocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _persistedIndex = _stack.currentIndex;
    _stack.dispose();
    _overlayVN.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // RouteAware: another route is pushed above this one.
  @override
  void didPushNext() {
    final idx = _stack.currentIndex;
    if (idx > 0) {
      ref.read(swipeControllerProvider.notifier).trimFront(count: idx);
      _persistedIndex = 0;
      _recreateController(initialIndex: 0);
    }
  }

  // RouteAware: the top route popped and we’re visible again.
  @override
  void didPopNext() {
    _topUpIfNeeded();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _topUpIfNeeded();
    }
  }

  @override
  bool get wantKeepAlive => true;

  void _recreateController({int? initialIndex}) {
    final initIdx = (initialIndex ?? _stack.currentIndex);
    _stack.dispose();
    _stack = SwipableStackController(initialIndex: initIdx);
    _stackEpoch++;
    _overlayVN.value = (null, 0.0);
    setState(() {});
  }

  // Stable cache key: strip querystring *literally* (no Uri parsing)
  String _cacheKeyForUrl(String url) {
    if (kIsWeb) return url; // browser cache is keyed by full URL (incl. query)
    final q = url.indexOf('?');      // native cache manager: stable key
    return q == -1 ? url : url.substring(0, q);
  }

  // Is this a Supabase Storage signed URL?
  bool _isSupabaseSignedUrl(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return false;
    return u.path.contains('/storage/v1/object/sign/');
  }

  // Parse bucket + object path from a signed URL we already have.
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

  // Refresh a single photo signed URL and store it in _urlOverridesByCard
  // Update _refreshSignedUrlFor(...) to cache-bust on web:
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

    // Drop any poisoned native cache entry (mobile/desktop). Harmless on web.
    final stableKey = _cacheKeyForUrl(currentUrl);
    await customCacheManager.removeFile(stableKey).catchError((_) {});

    final supa = Supabase.instance.client;
    var freshUrl = await supa.storage.from(bucket).createSignedUrl(objectPath, 55 * 60);

    // IMPORTANT: Browser caches by full URL; add a cache-buster on web.
    if (kIsWeb) {
      final sep = freshUrl.contains('?') ? '&' : '?';
      freshUrl = '$freshUrl${sep}cb=${DateTime.now().millisecondsSinceEpoch}';
    }

    final list = _urlOverridesByCard.putIfAbsent(cardId, () => <String?>[]);
    if (photoIndex >= list.length) {
      list.length = photoIndex + 1;
    }
    list[photoIndex] = freshUrl;

    if (mounted) setState(() {});
  } catch (_) {
    // ignore
  } finally {
    _refreshingUrls.remove(currentUrl);
  }
}


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
      final ctrl = ref.read(swipeControllerProvider.notifier);
      await ctrl.topUpIfNeededCorrect(
        prefs: {
          'interested_in_gender':
              ref.read(prefGenderProvider) == 'A' ? null : ref.read(prefGenderProvider),
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

  void _maybeTrimFrontIfLarge() {
    if (!mounted) return;
    final st = ref.read(swipeControllerProvider);
    final idx = _stack.currentIndex;
    if (idx <= _kKeepBack) return;
    final trimCount = idx - _kKeepBack;
    if (trimCount <= 0 || st.cards.isEmpty) return;

    final trimmedIds = st.cards.take(trimCount).map((c) => c.id).toList();
    final map = {...ref.read(photoIndexByIdProvider)};
    for (final id in trimmedIds) {
      map.remove(id);
      _urlOverridesByCard.remove(id);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(photoIndexByIdProvider.notifier).state = map;
    });

    ref.read(swipeControllerProvider.notifier).trimFront(count: trimCount);
    final int newIndex =
        (idx - trimCount).clamp(0, math.max(0, st.cards.length - 1)).toInt(); // == _kKeepBack
    _persistedIndex = newIndex;
    _recreateController(initialIndex: newIndex);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = ref.watch(swipeControllerProvider);

    if (Supabase.instance.client.auth.currentUser == null) {
      return const Center(
        child: Text('Please sign in to discover profiles', style: TextStyle(fontSize: 16)),
      );
    }

    // Recreate controller only when first-id changes.
    final newFirstId = state.cards.isNotEmpty ? state.cards.first.id : null;
    if (newFirstId != _firstCardIdSeen) {
      _firstCardIdSeen = newFirstId;
      final int clamped = state.cards.isEmpty
          ? -1
          : (_persistedIndex < 0
              ? 0
              : _persistedIndex.clamp(0, state.cards.length - 1).toInt());
      _recreateController(initialIndex: clamped);
    }

    final itemCount = state.cards.length;
    final current = _stack.currentIndex;
    final atTail = current >= itemCount - 1;
    final showEmptyNow = !state.fetching && state.exhausted && (itemCount == 0 || atTail);

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
              final total = ref.read(swipeControllerProvider).cards.length;
              final hasCard = (_stack.currentIndex + 1) < total;

              if (intent.kind == _SwipeKind.rewind) {
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
                  _openViewProfile(_topCardId());
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
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: itemCount == 0
                      ? (state.fetching
                          ? FindingNearbyLoading(avatarUrl: state.myPhoto)
                          : (state.exhausted
                              ? _OutOfPeoplePage(
                                  onAdjustFilters: _openFiltersSheet, onRetry: _bootstrap)
                              : FindingNearbyLoading(avatarUrl: state.myPhoto)))
                      : (showEmptyNow
                          ? _OutOfPeoplePage(
                              onAdjustFilters: _openFiltersSheet, onRetry: _bootstrap)
                          : _buildStack(state)),
                ),
              ),
              if (!showEmptyNow && itemCount > 0) _bottomBar(itemCount),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStack(SwipeUiState state) {
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        double target = size.width * 0.94;
        double cardW = target.clamp(280.0, 520.0).toDouble();
        if (size.width > 800) cardW = size.width * 0.6;
        final double cardH = size.height;

        final needSizeUpdate =
            (_lastCardW == null || (_lastCardW! - cardW).abs() > 0.5) ||
            (_lastCardH == null || (_lastCardH! - cardH).abs() > 0.5);
        if (needSizeUpdate) {
          _lastCardW = cardW;
          _lastCardH = cardH;
        }

        // Preload next few (use verbatim signed URL for the request; stable cacheKey)
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final i0 = _stack.currentIndex + 1;
          for (int i = i0; i < math.min(i0 + 3, state.cards.length); i++) {
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
            child: Listener(
              onPointerUp: (_) => _overlayVN.value = (null, 0.0),
              onPointerSignal: (signal) {
                // allow trackpad horizontal scroll to switch photos on top card
                if (signal is PointerScrollEvent && signal.scrollDelta.dx != 0) {
                  final st = ref.read(swipeControllerProvider);
                  final idx = _stack.currentIndex;
                  if (idx < 0 || idx >= st.cards.length) return;
                  final userId = st.cards[idx].id;
                  final photos = st.cards[idx].photos;
                  if (photos.length < 2) return;
                  final map = {...ref.read(photoIndexByIdProvider)};
                  final int current =
                      (map[userId] ?? 0).clamp(0, math.max(0, photos.length - 1)).toInt();
                  final dir = signal.scrollDelta.dx > 0 ? 1 : -1;
                  final int next = (current + dir).clamp(0, photos.length - 1).toInt();
                  if (next != current) {
                    ref.read(photoIndexByIdProvider.notifier).state = {
                      ...map,
                      userId: next,
                    };
                  }
                }
              },
              child: KeyedSubtree(
                key: ValueKey('stack_epoch_$_stackEpoch'),
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
                                          .withOpacity(p * 0.25),
                                      blurRadius: 40 * p,
                                      spreadRadius: 6 * p,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        if (dir == SwipeDirection.right && p > 0)
                          Positioned(
                            top: 24,
                            left: 18,
                            child: _swipeLabel(
                                'LIKE', Colors.greenAccent.withOpacity(p), p),
                          ),
                        if (dir == SwipeDirection.left && p > 0)
                          Positioned(
                            top: 24,
                            right: 18,
                            child: _swipeLabel(
                                'NOPE', Colors.redAccent.withOpacity(p), p),
                          ),
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
                    final cards = state.cards;
                    if (index < 0 || index >= cards.length) return false;
                    if (direction == SwipeDirection.up) {
                      _openViewProfile(cards[index].id);
                      HapticFeedback.selectionClick();
                      return false;
                    }
                    return true;
                  },
                  onSwipeCompleted: (index, direction) async {
                    final cards = state.cards;
                    if (index < 0 || index >= cards.length) return;
                    final card = cards[index];
                    final liked = direction == SwipeDirection.right;

                    // persist last swiped globally for Undo (survives route changes)
                    SwipeUndoStore.instance.push(cardMap: card.toCacheMap(), index: index);

                    _persistedIndex = _stack.currentIndex;

                    try {
                      await ref
                          .read(swipeControllerProvider.notifier)
                          .swipeCard(swipeeId: card.id, liked: liked);
                      HapticFeedback.lightImpact();
                    } finally {
                      _overlayVN.value = (null, 0.0);

                      // top-up near tail
                      final total = ref.read(swipeControllerProvider).cards.length;
                      final nextTop = _stack.currentIndex + 1;
                      final remaining = math.max(0, total - nextTop);
                      if (remaining <= _kTopUpThreshold) {
                        await _topUpIfNeeded();
                      }

                      if (mounted) {
                        _maybeTrimFrontIfLarge();
                        _persistedIndex = _stack.currentIndex;
                        setState(() {});
                      }
                    }
                  },
                  itemCount: state.cards.length,
                  builder: (context, props) {
                    final i = props.index;
                    if (i < 0 || i >= state.cards.length) {
                      return const SizedBox.shrink();
                    }
                    final card = state.cards[i];
                    return KeyedSubtree(
                      key: ValueKey(card.id),
                      child: _card(i, card, cardW, cardH),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Card
  Widget _card(int index, SwipeCard data, double cardW, double cardH) {
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
    final int currentIndex =
        (photoIndexById[userId] ?? 0).clamp(0, maxIdx).toInt();

    // Apply on-the-fly override if we recently refreshed a signed URL
    final String? rawCurrent = photos.isEmpty ? null : photos[currentIndex];
    final String? currentPhoto =
        (rawCurrent == null) ? null : _overrideUrlIfAny(userId, currentIndex, rawCurrent);

    final isTopCard = index == _stack.currentIndex;

    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        width: cardW,
        height: cardH,
        decoration: const BoxDecoration(
          boxShadow: [BoxShadow(blurRadius: 22, color: Colors.black45, offset: Offset(0, 14))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            width: cardW,
            height: cardH,
            child: LayoutBuilder(
              builder: (context, c) {
                final cw = c.maxWidth;

                // Precache neighbors with **int** indices (fix num→int diagnostics)
                if (photos.length > 1) {
                  final int nextIdx =
                      (currentIndex + 1 <= maxIdx) ? currentIndex + 1 : maxIdx;
                  final int prevIdx =
                      (currentIndex - 1 >= 0) ? currentIndex - 1 : 0;

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

                final provider = (currentPhoto == null)
                    ? null
                    : CachedNetworkImageProvider(
                        currentPhoto, // ← use signed URL exactly as provided
                        cacheManager: customCacheManager,
                        cacheKey: _cacheKeyForUrl(currentPhoto), // ← stable key (no ?token)
                      );

                final imageCore = currentPhoto == null
                    ? const ColoredBox(color: Colors.black26)
                    : Image(
                        image: provider!,
                        fit: BoxFit.cover,
                        alignment: Alignment.center,
                        width: cardW,
                        height: cardH,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.medium,
                        // fade-in without re-layout to avoid "jump"
                        frameBuilder: (ctx, child, frame, wasSync) {
                          final visible = frame != null || wasSync;
                          return AnimatedOpacity(
                            opacity: visible ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 120),
                            child: child,
                          );
                        },
                        // If a 401/403 happens (expired token), refresh the URL and rebuild.
                        errorBuilder: (_, __, ___) {
                          _refreshSignedUrlFor(
                            cardId: userId,
                            photoIndex: currentIndex,
                            currentUrl: currentPhoto,
                          );
                          return Container(
                            color: Colors.grey[850],
                            child: const Center(
                              child: Icon(Icons.image_not_supported_outlined,
                                  color: Colors.white70, size: 48),
                            ),
                          );
                        },
                      );

                final imageWidget = AnimatedSwitcher(
  duration: const Duration(milliseconds: 180),
  switchInCurve: Curves.easeOutCubic,
  switchOutCurve: Curves.easeOutCubic,
  layoutBuilder: (currentChild, previousChildren) => Stack(
    fit: StackFit.expand,
    children: <Widget>[...previousChildren, if (currentChild != null) currentChild],
  ),
  child: SizedBox(
    key: ValueKey<String>(currentPhoto ?? 'none'), // ← forces DOM img refresh on web
    width: cardW,
    height: cardH,
    child: RepaintBoundary(child: imageCore),
  ),
);

                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) {
                    if (photos.length < 2) return;
                    final isRight = details.localPosition.dx > cw / 2;
                    final int n = (currentIndex + (isRight ? 1 : -1))
                        .clamp(0, maxIdx)
                        .toInt();
                    photoIndexByIdNotifier.state = {...photoIndexById, userId: n};
                    HapticFeedback.selectionClick();
                  },
                  onLongPress: () => _openViewProfile(userId),
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
                                    final dx = (d == SwipeDirection.left
                                                ? -1
                                                : d == SwipeDirection.right
                                                    ? 1
                                                    : 0) *
                                        p *
                                        8;
                                    final dy = (d == SwipeDirection.up ? -1 : 0) * p * 8;
                                    final tilt = (d == SwipeDirection.left
                                                ? -1
                                                : d == SwipeDirection.right
                                                    ? 1
                                                    : 0) *
                                        p *
                                        0.02;
                                    return Transform(
                                      alignment: Alignment.center,
                                      transform: Matrix4.translationValues(dx, dy, 0)..rotateZ(tilt),
                                      child:
                                          Transform.scale(scale: 1.06 + p * 0.02, child: imageWidget),
                                    );
                                  },
                                ),
                              )
                            : Transform.scale(scale: 1.06, child: imageWidget),
                      ),
                      if (photos.length > 1)
                        _PhotoDots(currentIndex: currentIndex, count: photos.length),
                      _PresenceIndicator(
                        presence: _presenceInfo(
                            isOnline: data.isOnline, lastSeenRaw: data.lastSeen),
                      ),
                      _InfoGradient(
                        name: name,
                        age: age,
                        distance: distance,
                        bio: bio,
                        interests: data.interests,
                        onTap: () => _openViewProfile(userId),
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

  // Return override URL if we have a fresh one for (cardId, index); else return original.
  String _overrideUrlIfAny(String cardId, int index, String original) {
    final list = _urlOverridesByCard[cardId];
    if (list == null) return original;
    if (index < 0 || index >= list.length) return original;
    final o = list[index];
    return (o == null || o.isEmpty) ? original : o;
  }

  // Bottom controls
  Widget _bottomBar(int totalCount) {
    final cardW = (_lastCardW ?? MediaQuery.of(context).size.width * 0.94);
    final double btn = cardW < 320 ? 52 : (cardW < 360 ? 58 : 62);
    final double bigBtn = btn + 10;

    final current = _stack.currentIndex;
    final hasCard = (current + 1) < totalCount;
    final canUndo = SwipeUndoStore.instance.has; // ← global

    return Padding(
      padding: EdgeInsets.fromLTRB(12, 8, 12, 12 + MediaQuery.of(context).padding.bottom * .6),
      child: Align(
        alignment: Alignment.center,
        child: SizedBox(
          width: math.max(cardW - 8, 220),
          child: ValueListenableBuilder<(SwipeDirection?, double)>(
            valueListenable: _overlayVN,
            builder: (_, tuple, __) {
              final (dir, progress) = tuple;
              double nopeScale = 1.0, superLikeScale = 1.0, likeScale = 1.0, rewindScale = 1.0;
              Color nopeColor = Colors.red,
                  superLikeColor = Colors.blue,
                  likeColor = Colors.green,
                  rewindColor = Colors.white24,
                  boostColor = Colors.purple;

              if (dir == SwipeDirection.left) {
                nopeScale = 1 + progress * 0.3;
                nopeColor = Colors.redAccent.withOpacity(0.5 + progress * 0.5);
              } else if (dir == SwipeDirection.right) {
                likeScale = 1 + progress * 0.3;
                likeColor = Colors.greenAccent.withOpacity(0.5 + progress * 0.5);
              } else if (dir == SwipeDirection.up) {
                superLikeScale = 1 + progress * 0.3;
                superLikeColor = Colors.blueAccent.withOpacity(0.5 + progress * 0.5);
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
                      color: nopeColor,
                      size: btn,
                      scale: nopeScale,
                      onTap: hasCard
                          ? () => _stack.next(swipeDirection: SwipeDirection.left)
                          : null,
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: 'Super-like (view profile)',
                    child: _RoundAction(
                      icon: Icons.star,
                      color: superLikeColor,
                      size: bigBtn,
                      scale: superLikeScale,
                      onTap: hasCard ? () => _openViewProfile(_topCardId()) : null,
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: 'Like',
                    child: _RoundAction(
                      icon: Icons.favorite,
                      color: likeColor,
                      size: btn,
                      scale: likeScale,
                      onTap: hasCard
                          ? () => _stack.next(swipeDirection: SwipeDirection.right)
                          : null,
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: 'Boost',
                    child: _RoundAction(
                      icon: Icons.flash_on,
                      color: boostColor,
                      size: btn,
                      scale: 1.0,
                      onTap: () => ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(content: Text('Boost sent ✨'))),
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
    final snap = SwipeUndoStore.instance.take();
    if (snap == null) return;
    final map = snap.cardMap;

    final card = SwipeCard.fromJson(map.map((k, v) => MapEntry<String, dynamic>(k, v)));

    try {
      // UI first: reinsert so user immediately sees it back
      final showAt =
          _stack.currentIndex.clamp(0, ref.read(swipeControllerProvider).cards.length);
      ref.read(swipeControllerProvider.notifier).reinsertForUndo(card, index: showAt);

      // reset controller pinned to that index
      _recreateController(initialIndex: showAt);

      // server consistency
      await ref.read(swipeControllerProvider.notifier).undo(swipeeId: card.id);
      HapticFeedback.selectionClick();
    } catch (_) {
      // keep UI optimistic even if RPC fails
    } finally {
      _persistedIndex = _stack.currentIndex;
      if (!mounted) return;
      setState(() {});
    }
  }

  String? _topCardId() {
    final st = ref.read(swipeControllerProvider);
    final idx = _stack.currentIndex;
    if (idx < 0 || idx >= st.cards.length) return null;
    return st.cards[idx].id;
  }

  void _openViewProfile(String? userId) {
    if (userId == null || userId.isEmpty) return;
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, __, ___) => ViewProfilePage(userId: userId),
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

  Widget _swipeLabel(String text, Color color, double opacity) => Transform.rotate(
        angle: -math.pi / 14,
        child: Text(
          text,
          style: TextStyle(
            letterSpacing: 2,
            fontWeight: FontWeight.w800,
            fontSize: 20,
            color: color.withOpacity(opacity),
          ),
        ),
      );

  Future<void> _openFiltersSheet() async {
    await _openFiltersSheetModal(context, ref, () async {
      await ref.read(swipeControllerProvider.notifier).bootstrapAndFirstLoad();
      await _topUpIfNeeded();
    });
  }
}

// ───────────────────────────── Helper widgets (semantics-friendly)

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.color,
    required this.size,
    this.scale = 1.0,
    this.onTap,
  });

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
          child: AnimatedScale(
            scale: scale.clamp(0.8, 1.35),
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: bg,
                shape: BoxShape.circle,
                boxShadow: const [
                  BoxShadow(blurRadius: 10, color: Colors.black38, offset: Offset(0, 4))
                ],
                border: Border.all(color: color.withOpacity(0.25), width: 1),
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

// Presence / footer

enum _PresenceBucket { active, recent, offline }

class _PresenceInfo {
  final _PresenceBucket bucket;
  final String label;
  final Color color;
  const _PresenceInfo(this.bucket, this.label, this.color);
}

_PresenceInfo _presenceInfo({required bool isOnline, required dynamic lastSeenRaw}) {
  if (isOnline) {
    return const _PresenceInfo(_PresenceBucket.active, 'Active now', Color(0xFF00E676));
  }
  final lastSeen = _toDateTimeOrNull(lastSeenRaw);
  if (lastSeen == null) {
    return const _PresenceInfo(_PresenceBucket.offline, 'Offline', Colors.white24);
  }

  final now = DateTime.now().toUtc();
  final dt = lastSeen.isUtc ? lastSeen : lastSeen.toUtc();
  final diff = now.difference(dt);
  if (diff.inMinutes <= 10) {
    return const _PresenceInfo(_PresenceBucket.recent, 'Recently active', Color(0xFFFFC107));
  }
  String fmt() {
    if (diff.inMinutes < 60) return 'Last seen ${diff.inMinutes} m';
    if (diff.inHours < 24) return 'Last seen ${diff.inHours} h';
    return 'Last seen ${diff.inDays} d';
  }

  return _PresenceInfo(_PresenceBucket.offline, fmt(), Colors.white24);
}

DateTime? _toDateTimeOrNull(dynamic v) {
  try {
    if (v == null) return null;
    if (v is DateTime) return v;
    final s = v.toString();
    if (s.isEmpty) return null;
    return DateTime.tryParse(s);
  } catch (_) {
    return null;
  }
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
        color: Colors.black.withOpacity(0.35),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
        ],
      ),
    );
  }
}

class _PresenceIndicator extends StatelessWidget {
  const _PresenceIndicator({required this.presence});
  final _PresenceInfo presence;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (presence.bucket == _PresenceBucket.active)
          const Positioned(
            top: 14,
            left: 14,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Color(0xFF00E676),
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Color(0x8000E676), blurRadius: 8)],
              ),
              child: SizedBox(width: 12, height: 12),
            ),
          ),
        Positioned(top: 12, left: 34, child: _StatusChip(text: presence.label, color: presence.color)),
      ],
    );
  }
}

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
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                Color.fromARGB(230, 0, 0, 0),
                Color.fromARGB(150, 0, 0, 0),
                Color.fromARGB(60, 0, 0, 0),
              ],
              stops: [0.0, 0.5, 1.0],
            ),
            borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                age > 0 ? '$name, $age' : name,
                style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600),
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
                  children: interests!
                      .take(3)
                      .map(
                        (t) => Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: Colors.white.withOpacity(0.12)),
                          ),
                          child: Text(t, style: const TextStyle(fontSize: 12)),
                        ),
                      )
                      .toList(),
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
      top: 14,
      left: 0,
      right: 0,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(
          count,
          (dot) => Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dot == currentIndex ? Colors.pink : Colors.grey.withOpacity(0.5),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────── Filters (quick + lightweight, stays local to this page)
Future<void> _openFiltersSheetModal(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function() onApply,
) async {
  String g = ref.read(prefGenderProvider);
  RangeValues ages =
      RangeValues(ref.read(prefAgeMinProvider).toDouble(), ref.read(prefAgeMaxProvider).toDouble());
  double radius = ref.read(prefRadiusKmProvider);

  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF16181C),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (ctx) {
      return Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 + MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: StatefulBuilder(builder: (ctx, setM) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration:
                    BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
              const Text('Adjust Filters', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text('Gender: $g', style: const TextStyle(color: Colors.white)),
                  const Spacer(),
                  Text('Age: ${ages.start.toInt()} - ${ages.end.toInt()}',
                      style: const TextStyle(color: Colors.white)),
                  const Spacer(),
                  Text('Radius: ${radius.toInt()} km', style: const TextStyle(color: Colors.white)),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('Age range', style: TextStyle(fontSize: 14)),
                  const Spacer(),
                  Text('${ages.start.round()}–${ages.end.round()}'),
                ],
              ),
              RangeSlider(
                values: ages,
                min: 18,
                max: 80,
                divisions: 62,
                labels: RangeLabels(ages.start.round().toString(), ages.end.round().toString()),
                onChanged: (v) => setM(() => ages = v),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Distance radius', style: TextStyle(fontSize: 14)),
                  const Spacer(),
                  Text('${radius.round()} km'),
                ],
              ),
              Slider(value: radius, min: 5, max: 200, divisions: 39, onChanged: (v) => setM(() => radius = v)),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    if (context.mounted) Navigator.of(ctx).maybePop();
                    ref.read(prefGenderProvider.notifier).state = g;
                    ref.read(prefAgeMinProvider.notifier).state = ages.start.round();
                    ref.read(prefAgeMaxProvider.notifier).state = ages.end.round();
                    ref.read(prefRadiusKmProvider.notifier).state = radius;
                    await onApply();
                  },
                  child: const Text('Apply Filters'),
                ),
              ),
              const SizedBox(height: 6),
            ],
          );
        }),
      );
    },
  );
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
    final fg = Colors.white.withOpacity(.94);
    double distance = 19;

    return StatefulBuilder(
      builder: (context, setLocal) {
        return Container(
          padding: const EdgeInsets.fromLTRB(22, 26, 22, 20),
          decoration: BoxDecoration(
            color: const Color(0xFF0F0F14),
            borderRadius: BorderRadius.circular(28),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 30, offset: Offset(0, 16))],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 140,
                height: 140,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 140,
                      height: 140,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(colors: [pink.withOpacity(.12), Colors.transparent]),
                      ),
                    ),
                    Container(
                      width: 92,
                      height: 92,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: pink.withOpacity(.25), width: 4),
                      ),
                    ),
                    Container(
                      width: 56,
                      height: 56,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(colors: [indigo, pink]),
                        boxShadow: [BoxShadow(blurRadius: 16, color: Colors.black45)],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text('You ran out of people.',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: fg)),
              const SizedBox(height: 8),
              Text(
                'Expand your distance settings to see more people in your area.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: distance,
                      min: 1,
                      max: 100,
                      onChanged: (v) => setLocal(() => distance = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${distance.round()} mi.', style: theme.textTheme.bodyMedium?.copyWith(color: fg)),
                ],
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                    padding: EdgeInsets.zero,
                    backgroundColor: Colors.transparent,
                  ).merge(ButtonStyle(elevation: WidgetStateProperty.all(0))),
                  onPressed: onAdjustFilters,
                  child: Ink(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [indigo, pink]),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Center(
                      child: Text(
                        'Done',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(onPressed: onAdjustFilters, child: const Text('Go to my settings')),
              const SizedBox(height: 10),
              OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
        );
      },
    );
  }
}

// ───────────────────────────── Keyboard actions

enum _SwipeKind { left, right, up, rewind }

class _SwipeIntent extends Intent {
  final _SwipeKind kind;
  const _SwipeIntent.left() : kind = _SwipeKind.left;
  const _SwipeIntent.right() : kind = _SwipeKind.right;
  const _SwipeIntent.up() : kind = _SwipeKind.up;
  const _SwipeIntent.rewind() : kind = _SwipeKind.rewind;
}
