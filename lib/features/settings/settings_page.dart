import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme/app_theme.dart';
import '../profile/pages/edit_profile_page.dart';
import '../paywall/paywall_page.dart';
import '../auth/login_page_widget.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  static const String routeName = 'settings';
  static const String routePath = '/settings';

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _supa = Supabase.instance.client;

  // ---- Discovery prefs (these columns already exist in your DB)
  String _gender = 'F'; // 'F','M','B'
  double _distanceKm = 50;
  RangeValues _age = const RangeValues(18, 60);

  // ---- Optional extras (saved to preferences.extra if present, otherwise just local)
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
              // merge, keep defaults for missing keys
              _extra = {
                ..._extra,
                ...ex.map((k, v) => MapEntry(k.toString(), v)),
              };
            }
          }
        });
      } else {
        // No row yet; will be created on first save
      }
    } catch (e) {
      // Swallow silently; page still renders with defaults
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

  /// Avoids `on_conflict` 400 by updating if row exists, else inserting.
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
    if (ok != true) return;

    try {
      await _supa.auth.signOut();
    } catch (_) {}
    if (!mounted) return;
    context.go(LoginPageWidget.routePath);
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
      // If you have a secured RPC, this will handle it
      await _supa.rpc('request_account_delete', params: {
        'user_id_arg': _supa.auth.currentUser?.id,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Deletion requested. We’ll email you shortly.')),
      );
    } catch (_) {
      // Fallback: flag on profile
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
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
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
                        segments: const {
                          'F': 'Women',
                          'M': 'Men',
                          'B': 'Everyone',
                        },
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
                        onChanged: (v) {
                          setState(() => _distanceKm = v);
                        },
                        onChangeEnd: (_) => _queueSave(),
                      ),
                      _RangeTile(
                        icon: Icons.cake_outlined,
                        title: 'Age range',
                        values: _age,
                        min: 18,
                        max: 60,
                        onChanged: (v) {
                          setState(() => _age = v);
                        },
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
                        icon: Icons.visibility_off_outlined, // fixed icon
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
                Text(title, style: const TextStyle(fontSize: 13, color: Colors.white70, fontWeight: FontWeight.w700, letterSpacing: .3)),
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
      // Replaces deprecated `activeColor`
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
            value: value.clamp(min, max),
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
              values.start.clamp(min, max),
              values.end.clamp(min, max),
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
