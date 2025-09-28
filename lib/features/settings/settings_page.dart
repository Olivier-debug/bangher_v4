// lib/features/settings/settings_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/painting.dart' as painting show PaintingBinding; // image cache clear
import 'package:flutter_cache_manager/flutter_cache_manager.dart'; // disk image cache
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme/app_theme.dart';
import '../profile/pages/edit_profile_page.dart';
import '../paywall/paywall_page.dart';
import '../auth/login_page_widget.dart';

// If you added a central wiper, keep this import. If you don't have it yet, remove this line.
import '../../core/cache_wiper.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  static const String routeName = 'settings';
  static const String routePath = '/settings';

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _supa = Supabase.instance.client;

  // ---- Discovery prefs
  String _gender = 'F'; // 'F','M','B'
  double _distanceKm = 50;
  RangeValues _age = const RangeValues(18, 60);

  // ---- Optional extras
  Map<String, dynamic> _extra = {
    'notify_likes': true,
    'notify_matches': true,
    'notify_messages': true,
    'show_online': true,
    'read_receipts': false,
    'hide_age': false,
    'hide_distance': false,
    'incognito_mode': false,
  };
  bool _preferencesHasExtraColumn = false;

  bool _loading = true;
  bool _saving = false;
  Timer? _debounce;

  String _version = '';
  String _buildNumber = '';

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await Future.wait([
      _loadPrefs(),
      _loadAppInfo(),
    ]);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadAppInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _version = info.version;
      _buildNumber = info.buildNumber;
    } catch (_) {
      _version = '1.0.0';
      _buildNumber = '';
    }
  }

  Future<void> _loadPrefs() async {
    try {
      final uid = _supa.auth.currentUser?.id;
      if (uid == null) return;

      final row = await _supa
          .from('preferences')
          .select('interested_in_gender, age_min, age_max, distance_radius, extra')
          .eq('user_id', uid)
          .maybeSingle();

      if (row != null) {
        if (!mounted) return;
        setState(() {
          _gender = (row['interested_in_gender'] as String?)?.isNotEmpty == true
              ? row['interested_in_gender'] as String
              : _gender;

          final aMin = (row['age_min'] is int) ? row['age_min'] as int : 18;
          final aMax = (row['age_max'] is int) ? row['age_max'] as int : 60;
          _age = RangeValues(aMin.toDouble(), aMax.toDouble());

          final dr = row['distance_radius'];
          _distanceKm = (dr is num) ? dr.toDouble() : _distanceKm;

          if (row.containsKey('extra')) {
            _preferencesHasExtraColumn = true;
            final ex = row['extra'];
            if (ex is Map) {
              _extra = {
                ..._extra,
                ...ex.map((k, v) => MapEntry(k.toString(), v)),
              };
            }
          }
        });
      }
    } catch (e) {
      debugPrint('Settings load error: $e');
    }
  }

  void _queueSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _savePrefs);
  }

  Future<void> _savePrefs() async {
    if (!mounted) return;
    setState(() => _saving = true);

    try {
      final uid = _supa.auth.currentUser?.id;
      if (uid == null) return;

      final values = <String, dynamic>{
        'user_id': uid,
        'interested_in_gender': _gender,
        'age_min': _age.start.round(),
        'age_max': _age.end.round(),
        'distance_radius': _distanceKm,
      };

      if (_preferencesHasExtraColumn) {
        values['extra'] = _extra;
      }

      await _smartUpsertPreferences(values);
    } catch (e) {
      debugPrint('Settings save error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save settings')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _smartUpsertPreferences(Map<String, dynamic> values) async {
    final uid = values['user_id'];
    final existing = await _supa
        .from('preferences')
        .select('user_id')
        .eq('user_id', uid)
        .maybeSingle();

    if (existing == null) {
      await _supa.from('preferences').insert(values);
    } else {
      final copy = Map<String, dynamic>.from(values)..remove('user_id');
      await _supa.from('preferences').update(copy).eq('user_id', uid);
    }
  }

  // ---------------------------------------------------------------------------
  // HARD CACHE NUKE (run before signOut and for "Reset cache")
  Future<void> _nukeAllCaches({String? userId}) async {
  // If you have a central wiper, call it first. It's safe if it’s a no-op.
  try {
    await CacheWiper.wipeAll(supa: _supa);
  } catch (_) {
    // Ignore if CacheWiper isn't available for some reason.
  }

  // 1) In-memory image cache
  try {
    final cache = painting.PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
  } catch (e) {
    debugPrint('Image cache clear failed: $e');
  }

  // 2) Disk image/file caches (CachedNetworkImage / DefaultCacheManager)
  try {
    await DefaultCacheManager().emptyCache();
  } catch (e) {
    debugPrint('DefaultCacheManager empty failed: $e');
  }

  // 3) SharedPreferences (wipe everything)
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  } catch (e) {
    debugPrint('SharedPreferences clear failed: $e');
  }

  // 4) Supabase realtime—close channels so nothing leaks
  try {
    await _supa.removeAllChannels();
  } catch (e) {
    debugPrint('Supabase removeAllChannels failed: $e');
  }
}

  // Standalone "Reset cache" action (does NOT sign the user out).
  Future<void> _resetCache() async {
    // quick, non-dismissible progress
    showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => const _SigningOutDialog(), // reuse tiny spinner UI
    );

    try {
      await _nukeAllCaches(userId: _supa.auth.currentUser?.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cache cleared')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not clear cache')),
        );
      }
    } finally {
      if (mounted) {
        final rootNav = Navigator.of(context, rootNavigator: true);
        if (rootNav.canPop()) rootNav.pop();
      }
    }
  }

  // ---------- CLEAN, FAST LOGOUT ----------
  Future<void> _preLogoutCleanup() async {
    FocusManager.instance.primaryFocus?.unfocus();

    // Reset local UI state (so nothing flashes post-logout navigation)
    setState(() {
      _gender = 'F';
      _distanceKm = 50;
      _age = const RangeValues(18, 60);
      _extra = {
        'notify_likes': true,
        'notify_matches': true,
        'notify_messages': true,
        'show_online': true,
        'read_receipts': false,
        'hide_age': false,
        'hide_distance': false,
        'incognito_mode': false,
      };
    });

    await _nukeAllCaches(userId: _supa.auth.currentUser?.id);

    // tiny pause to let the UI breathe
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text('You can log back in anytime.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    // Show non-dismissible spinner
    showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => const _SigningOutDialog(),
    );

    try {
      // 1) Purge caches first
      await _preLogoutCleanup();

      // 2) Then sign out (removes session from secure storage)
      await _supa.auth.signOut();
    } catch (_) {
      // Ignore sign-out errors
    } finally {
      if (mounted) {
        // 3) Dismiss spinner
        final rootNav = Navigator.of(context, rootNavigator: true);
        if (rootNav.canPop()) {
          rootNav.pop();
        }

        // 4) Navigate AFTER the pop completes to avoid _debugLocked
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;

          // Ensure a fresh tree (prevents any zombied widgets holding onto old state).
          // go() already replaces the stack; this post-frame makes sure the dialog pop fully finished.
          context.go(LoginPageWidget.routePath);
        });
      }
    }
  }

  Future<void> _requestAccountDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'This will permanently remove your profile, photos, swipes, and matches. This action cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await _supa.rpc('request_account_delete', params: {
        'user_id_arg': _supa.auth.currentUser?.id,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Deletion requested. We’ll email you shortly.')),
      );
    } catch (_) {
      try {
        final me = _supa.auth.currentUser?.id;
        if (me != null) {
          await _supa.from('profiles').update({'delete_requested': true}).eq('user_id', me);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Deletion request sent.')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not request deletion.')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final savingDot = _saving
        ? Padding(
            padding: const EdgeInsets.only(left: 10),
            child: SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppTheme.ffPrimary,
              ),
            ),
          )
        : const SizedBox.shrink();

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Settings'),
            savingDot,
          ],
        ),
      ),
      body: SafeArea(
        child: _loading
            ? const _SettingsSkeleton()
            : ListView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                children: [
                  _SectionCard(
                    title: 'Account',
                    children: [
                      _NavTile(
                        icon: Icons.person_outline,
                        title: 'Edit profile',
                        subtitle: 'Photos, bio, and prompts',
                        onTap: () => context.push(EditProfilePage.routePath),
                      ),
                      _NavTile(
                        icon: Icons.block,
                        title: 'Blocked users',
                        subtitle: 'Manage who you’ve blocked',
                        onTap: () => _toast('Blocked users coming soon'),
                      ),
                      _DangerTile(
                        icon: Icons.delete_forever_outlined,
                        title: 'Delete account',
                        onTap: _requestAccountDelete,
                      ),
                    ],
                  ),
                  _SectionCard(
                    title: 'Discovery',
                    children: [
                      _SegTile(
                        title: 'Show me',
                        value: _gender,
                        segments: const {'F': 'Women', 'M': 'Men', 'B': 'Everyone'},
                        onChanged: (v) {
                          setState(() => _gender = v);
                          _queueSave();
                        },
                      ),
                      _SliderTile(
                        icon: Icons.place_outlined,
                        title: 'Maximum distance',
                        value: _distanceKm,
                        min: 1,
                        max: 160,
                        unit: 'km',
                        onChanged: (v) => setState(() => _distanceKm = v),
                        onChangeEnd: (_) => _queueSave(),
                      ),
                      _RangeTile(
                        icon: Icons.cake_outlined,
                        title: 'Age range',
                        values: _age,
                        min: 18,
                        max: 60,
                        onChanged: (v) => setState(() => _age = v),
                        onChangeEnd: (_) => _queueSave(),
                      ),
                    ],
                  ),
                  _SectionCard(
                    title: 'Notifications',
                    children: [
                      _SwitchTile(
                        icon: Icons.favorite_border,
                        title: 'Likes',
                        value: _extra['notify_likes'] == true,
                        onChanged: (v) {
                          setState(() => _extra['notify_likes'] = v);
                          _queueSave();
                        },
                      ),
                      _SwitchTile(
                        icon: Icons.emoji_events_outlined,
                        title: 'Matches',
                        value: _extra['notify_matches'] == true,
                        onChanged: (v) {
                          setState(() => _extra['notify_matches'] = v);
                          _queueSave();
                        },
                      ),
                      _SwitchTile(
                        icon: Icons.chat_bubble_outline,
                        title: 'Messages',
                        value: _extra['notify_messages'] == true,
                        onChanged: (v) {
                          setState(() => _extra['notify_messages'] = v);
                          _queueSave();
                        },
                      ),
                    ],
                  ),
                  _SectionCard(
                    title: 'Privacy & Safety',
                    children: [
                      _SwitchTile(
                        icon: Icons.visibility_outlined,
                        title: 'Show online status',
                        value: _extra['show_online'] == true,
                        onChanged: (v) {
                          setState(() => _extra['show_online'] = v);
                          _queueSave();
                        },
                      ),
                      _SwitchTile(
                        icon: Icons.mark_chat_read_outlined,
                        title: 'Read receipts',
                        value: _extra['read_receipts'] == true,
                        onChanged: (v) {
                          setState(() => _extra['read_receipts'] = v);
                          _queueSave();
                        },
                      ),
                      _SwitchTile(
                        icon: Icons.remove_red_eye_outlined,
                        title: 'Hide my age',
                        value: _extra['hide_age'] == true,
                        onChanged: (v) {
                          setState(() => _extra['hide_age'] = v);
                          _queueSave();
                        },
                      ),
                      _SwitchTile(
                        icon: Icons.place_outlined,
                        title: 'Hide my distance',
                        value: _extra['hide_distance'] == true,
                        onChanged: (v) {
                          setState(() => _extra['hide_distance'] = v);
                          _queueSave();
                        },
                      ),
                      _SwitchTile(
                        icon: Icons.visibility_off_outlined,
                        title: 'Incognito mode',
                        subtitle: 'Only people you like can see you',
                        value: _extra['incognito_mode'] == true,
                        onChanged: (v) {
                          setState(() => _extra['incognito_mode'] = v);
                          _queueSave();
                        },
                      ),
                      _NavTile(
                        icon: Icons.report_gmailerrorred_outlined,
                        title: 'Report a problem',
                        onTap: () => _toast('Open support flow here'),
                      ),
                    ],
                  ),
                  _SectionCard(
                    title: 'Subscription',
                    children: [
                      _NavTile(
                        icon: Icons.star_rounded,
                        title: 'Manage Plus',
                        subtitle: 'Boosts, rewinds & more',
                        onTap: () => context.push(PaywallPage.routePath),
                      ),
                      _NavTile(
                        icon: Icons.refresh_outlined,
                        title: 'Restore purchases',
                        onTap: () => _toast('Attempting restore…'),
                      ),
                    ],
                  ),
                  _SectionCard(
                    title: 'App',
                    children: [
                      // NEW: Full reset cache tile
                      _NavTile(
                        icon: Icons.cleaning_services_outlined,
                        title: 'Reset cache',
                        subtitle: 'Clear images, storage & prefs',
                        onTap: _resetCache,
                      ),
                      _NavTile(
                        icon: Icons.translate_outlined,
                        title: 'Language',
                        subtitle: 'System default',
                        onTap: () => _toast('Language selector coming soon'),
                      ),
                      _NavTile(
                        icon: Icons.description_outlined,
                        title: 'Terms of Service',
                        onTap: () => _openUrl('https://example.com/terms'),
                      ),
                      _NavTile(
                        icon: Icons.privacy_tip_outlined,
                        title: 'Privacy Policy',
                        onTap: () => _openUrl('https://example.com/privacy'),
                      ),
                      ListTile(
                        leading: const Icon(Icons.info_outline),
                        title: const Text('Version'),
                        subtitle: Text(_buildNumber.isEmpty ? _version : '$_version ($_buildNumber)'),
                        onTap: () {},
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _LogoutButton(onPressed: _logout),
                ],
              ),
      ),
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}

// ──────────────────────────────────────────────────────────────
// Simple non-dismissible signing-out overlay
class _SigningOutDialog extends StatelessWidget {
  const _SigningOutDialog();

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: const Color(0xFF111318),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Text('Working…', style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// SKELETON UI (single ticker, zero deps)
class _SettingsSkeleton extends StatelessWidget {
  const _SettingsSkeleton();

  @override
  Widget build(BuildContext context) {
    return _PulseAll(
      child: RepaintBoundary(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: const [
            _SectionSkeletonCard(lines: 3),
            _SectionSkeletonCard(lines: 3),
            _SectionSkeletonCard(lines: 6),
            _SectionSkeletonCard(lines: 4),
            _ButtonSkeleton(),
          ],
        ),
      ),
    );
  }
}

/// One animation driving the whole subtree (cheapest possible pulse).
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

class _SectionSkeletonCard extends StatelessWidget {
  const _SectionSkeletonCard({required this.lines});
  final int lines;

  @override
  Widget build(BuildContext context) {
    final Color outline = Theme.of(context).dividerColor.withValues(alpha: 0.2);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF16181C),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: outline),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, 6))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: _SkeletonBox(width: 100, height: 12, radius: 6),
          ),
          const Divider(height: 1),
          for (int i = 0; i < lines; i++) ...[
            const _TileSkeleton(),
            if (i != lines - 1) const Divider(height: 1),
          ],
        ],
      ),
    );
  }
}

class _TileSkeleton extends StatelessWidget {
  const _TileSkeleton();

  @override
  Widget build(BuildContext context) {
    return const ListTile(
      leading: _SkeletonCircle(d: 24),
      title: _SkeletonBox(width: 160, height: 12, radius: 6),
      subtitle: Padding(
        padding: EdgeInsets.only(top: 6),
        child: _SkeletonBox(width: 110, height: 10, radius: 6),
      ),
      trailing: _SkeletonBox(width: 18, height: 18, radius: 4),
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    );
  }
}

class _ButtonSkeleton extends StatelessWidget {
  const _ButtonSkeleton();

  @override
  Widget build(BuildContext context) {
    return const _SkeletonBox(height: 52, radius: 12);
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
        color: const Color(0xFF202227),
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
        color: Color(0xFF202227),
        shape: BoxShape.circle,
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// UI bits
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final Color outline = Theme.of(context).dividerColor.withValues(alpha: 0.2);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF16181C),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: outline),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, 6))],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Colors.white70,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .3,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ..._withDividers(children),
        ],
      ),
    );
  }

  List<Widget> _withDividers(List<Widget> tiles) {
    final out = <Widget>[];
    for (var i = 0; i < tiles.length; i++) {
      out.add(tiles[i]);
      if (i != tiles.length - 1) out.add(const Divider(height: 1));
    }
    return out;
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Colors.white),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: subtitle == null ? null : Text(subtitle!, style: const TextStyle(color: Colors.white70)),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
  }
}

class _DangerTile extends StatelessWidget {
  const _DangerTile({required this.icon, required this.title, required this.onTap});

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Colors.redAccent),
      title: Text(title, style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600)),
      onTap: onTap,
    );
  }
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      value: value,
      onChanged: onChanged,
      secondary: Icon(icon, color: Colors.white),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: subtitle == null ? null : Text(subtitle!, style: const TextStyle(color: Colors.white70)),
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return AppTheme.ffPrimary;
        return null;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return AppTheme.ffPrimary.withValues(alpha: 0.35);
        }
        return null;
      }),
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final IconData icon;
  final String title;
  final double value;
  final double min;
  final double max;
  final String unit;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      leading: Icon(icon, color: Colors.white),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Slider(
            value: value.clamp(min, max).toDouble(),
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
            min: min,
            max: max,
            label: '${value.round()} $unit',
            activeColor: AppTheme.ffPrimary,
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('${value.round()} $unit', style: const TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }
}

class _RangeTile extends StatelessWidget {
  const _RangeTile({
    required this.icon,
    required this.title,
    required this.values,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final IconData icon;
  final String title;
  final RangeValues values;
  final double min;
  final double max;
  final ValueChanged<RangeValues> onChanged;
  final ValueChanged<RangeValues> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      leading: Icon(icon, color: Colors.white),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RangeSlider(
            min: min,
            max: max,
            values: RangeValues(
              values.start.clamp(min, max).toDouble(),
              values.end.clamp(min, max).toDouble(),
            ),
            divisions: (max - min).round(),
            labels: RangeLabels(values.start.round().toString(), values.end.round().toString()),
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
            activeColor: AppTheme.ffPrimary,
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('${values.start.round()} – ${values.end.round()} yrs', style: const TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }
}

class _SegTile extends StatelessWidget {
  const _SegTile({
    required this.title,
    required this.value,
    required this.segments,
    required this.onChanged,
  });

  final String title;
  final String value;
  final Map<String, String> segments;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 6),
        child: LayoutBuilder(
          builder: (ctx, c) {
            final buttons = segments.entries.map((e) {
              final isSel = e.key == value;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: OutlinedButton(
                    onPressed: isSel ? null : () => onChanged(e.key),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: isSel ? AppTheme.ffPrimary : Colors.white24),
                      foregroundColor: isSel ? Colors.white : Colors.white70,
                      backgroundColor: isSel ? AppTheme.ffPrimary.withValues(alpha: 0.15) : Colors.transparent,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(e.value),
                  ),
                ),
              );
            }).toList();
            return Row(children: buttons);
          },
        ),
      ),
    );
  }
}

class _LogoutButton extends StatelessWidget {
  const _LogoutButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: Colors.redAccent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: const Text('Log out', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      ),
    );
  }
}
