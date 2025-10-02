// ignore_for_file: library_private_types_in_public_api

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../../core/images/peer_avatar_resolver.dart';
import '../../chat/widgets/peer_avatar.dart';

/// Tiny lightweight profile used by the overlay.
class ProfileLite {
  const ProfileLite({
    required this.id,
    required this.name,
    this.photoUrl,
    this.subtitle, // e.g. "23 • 3km away"
    this.bio,
  });

  final String id;
  final String name;
  final String? photoUrl;
  final String? subtitle;
  final String? bio;
}

/// “It’s a match!” overlay — **no animations**.
/// Now with avatar **fail-safe + cache prewarm** using PeerAvatarResolver.
class MatchOverlay {
  static Future<void> show(
    BuildContext context, {
    required ProfileLite me,
    required ProfileLite other,
    required VoidCallback onMessage,
    required VoidCallback onDismiss,
  }) async {
    // Best-effort prewarm of signed/normalized URLs so first paint has data.
    // We DO NOT block for long; if it takes too long, we still show the dialog
    // and the PeerAvatar widgets resolve/cached themselves.
    String? otherBgUrl;
    try {
      // Prewarm both (don’t care about result for "me" because we don’t show
      // a full-bleed BG for self, but it seeds cache for later).
      final f1 = PeerAvatarResolver.instance.getAvatarUrl(me.id);
      final f2 = PeerAvatarResolver.instance.getAvatarUrl(other.id);
      final res = await Future.wait<String?>([f1, f2]).timeout(const Duration(milliseconds: 800));
      otherBgUrl = res.elementAt(1);
      // Note: PeerAvatarResolver also persists to PeerProfileCache.
    } catch (_) {
      // If prewarm times out/fails, we still render and PeerAvatar will resolve.
      otherBgUrl = null;
    }

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: Duration.zero, // no open animation
      pageBuilder: (context, _, __) {
        return _MatchDialog(
          me: me,
          other: other,
          otherBackgroundUrl: otherBgUrl ?? other.photoUrl,
          onMessage: onMessage,
          onDismiss: onDismiss,
        );
      },
      transitionBuilder: (context, anim, _, child) => child, // no transition
    );
  }
}

class _MatchDialog extends StatelessWidget {
  const _MatchDialog({
    required this.me,
    required this.other,
    required this.otherBackgroundUrl,
    required this.onMessage,
    required this.onDismiss,
  });

  final ProfileLite me;
  final ProfileLite other;
  final String? otherBackgroundUrl;
  final VoidCallback onMessage;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          // Dim background
          Positioned.fill(
            child: Container(color: Colors.black.withValues(alpha: 0.60)),
          ),

          // Full-bleed OTHER user's photo behind the card (resolved/normalized if possible)
          if (otherBackgroundUrl != null && otherBackgroundUrl!.isNotEmpty)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  image: DecorationImage(
                    image: NetworkImage(otherBackgroundUrl!),
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),

          // Soft vignette
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.75),
                      Colors.black.withValues(alpha: 0.25),
                      Colors.transparent,
                    ],
                    stops: const [0, .35, 1],
                  ),
                ),
              ),
            ),
          ),

          // Foreground card
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                bottom: math.max(16, MediaQuery.of(context).padding.bottom + 12),
              ),
              child: _GlassCard(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: math.min(520, size.width - 32),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Avatars row (now using PeerAvatar, which resolves + caches)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            PeerAvatar(
                              userId: me.id,
                              size: 44,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.35),
                                width: 2,
                              ),
                            ),
                            const SizedBox(width: 10),
                            const Icon(Icons.favorite, color: Color(0xFFFF0F7B)),
                            const SizedBox(width: 10),
                            PeerAvatar(
                              userId: other.id,
                              size: 44,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.35),
                                width: 2,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),

                        // Headline
                        const Text(
                          "It's a match!",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 6),

                        // Name + optional subtitle
                        Text(
                          other.subtitle == null
                              ? other.name
                              : '${other.name} • ${other.subtitle}',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.white.withValues(alpha: 0.95),
                            fontWeight: FontWeight.w600,
                          ),
                        ),

                        if ((other.bio ?? '').trim().isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            (other.bio ?? '').trim(),
                            textAlign: TextAlign.center,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.white.withValues(alpha: 0.85),
                            ),
                          ),
                        ],

                        const SizedBox(height: 16),

                        // Buttons
                        Row(
                          children: [
                            Expanded(
                              child: _PrimaryBtn(
                                label: 'Say Hello',
                                onTap: () {
                                  Navigator.of(context).maybePop();
                                  onMessage();
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _GhostBtn(
                          label: 'Keep swiping',
                          onTap: () {
                            Navigator.of(context).maybePop();
                            onDismiss();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Close tap area (top-right)
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
        ],
      ),
    );
  }
}

/// -------------------- visuals --------------------

class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF121217).withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        boxShadow: const [
          BoxShadow(blurRadius: 40, color: Colors.black54, offset: Offset(0, 16)),
        ],
      ),
      child: child,
    );
  }
}

class _PrimaryBtn extends StatelessWidget {
  const _PrimaryBtn({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          padding: EdgeInsets.zero,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          backgroundColor: Colors.transparent,
        ),
        onPressed: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: const LinearGradient(
              colors: [Color(0xFF6759FF), Color(0xFFFF0F7B)],
            ),
          ),
          child: const Center(
            child: Text(
              'Say Hello',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 16,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GhostBtn extends StatelessWidget {
  const _GhostBtn({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: BorderSide(color: Colors.white.withValues(alpha: 0.65)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      onPressed: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }
}
