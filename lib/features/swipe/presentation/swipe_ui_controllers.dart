// lib/features/swipe/presentation/swipe_ui_controllers.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:swipable_stack/swipable_stack.dart';

final swipeStackControllerProvider = Provider<SwipableStackController>((ref) {
  final ctrl = SwipableStackController();
  ref.onDispose(ctrl.dispose);
  return ctrl;
});
