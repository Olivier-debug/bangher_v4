// =========================
// FILE: lib/widgets/app_bottom_nav.dart
// Reusable 4-tab bottom navigation used by router shell.
// Style: near-black background, subtle top border, AppTheme primary for active.
// =========================

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/app_theme.dart';

class NavItem {
  const NavItem({
    required this.icon,
    required this.label,
    required this.path,
    this.selectedStartsWith = const <String>[],
  });
  final IconData icon;
  final String label;
  final String path;
  final List<String> selectedStartsWith; // paths that should highlight this tab
}

class AppBottomNav extends StatelessWidget {
  const AppBottomNav({
    super.key,
    required this.items,
    required this.currentPath,
    this.background,
  });

  final List<NavItem> items;
  final String currentPath;
  final Color? background;

  int _activeIndex() {
    for (int i = 0; i < items.length; i++) {
      final it = items[i];
      final prefixes = it.selectedStartsWith.isEmpty ? <String>[it.path] : it.selectedStartsWith;
      if (prefixes.any((p) => currentPath.startsWith(p))) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final idx = _activeIndex();
    final bg = background ?? const Color.fromARGB(255, 0, 0, 0); // near-black grey
    final border = Colors.white;

    return Material(
      color: const Color.fromARGB(255, 0, 0, 0),
      child: SafeArea(
        top: false,
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            color: bg,
            border: Border(top: BorderSide(color: border, width: 1)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: List.generate(
              items.length,
              (i) => Expanded(child: _NavButton(item: items[i], selected: i == idx)),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.item, required this.selected});
  final NavItem item;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final active = AppTheme.ffPrimary;
    const inactive = Color.fromARGB(255, 255, 255, 255);

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        final prefixes = item.selectedStartsWith.isEmpty ? <String>[item.path] : item.selectedStartsWith;
        final current = GoRouterState.of(context).uri.toString();
        if (prefixes.any((p) => current.startsWith(p))) return; // already here
        try {
          context.go(item.path);
        } catch (_) {
          // Why: If a placeholder path is used (e.g., '/matches' before it's implemented)
          // we avoid crashing and simply nudge the user.
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Coming soon')), 
          );
        }
      },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(item.icon, size: 22, color: selected ? active : inactive),
          const SizedBox(height: 4),
          Text(
            item.label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected ? active : inactive,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
