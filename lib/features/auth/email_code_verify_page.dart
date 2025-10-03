// FILE: lib/features/auth/email_code_verify_page.dart
// Standalone email OTP verify screen for Supabase email sign-up.
// After successful verify, it ensures 'profiles' and 'preferences' rows exist
// using the authenticated session (so it passes RLS), then navigates.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ---- Local UI tokens (kept minimal to avoid cross-file coupling)
const Color _kScaffold = Colors.black;
const Color _kPrimaryText = Colors.white;
const Color _kSecondaryText = Color(0xFFB0B0B0);
const Color _kSecondaryBg = Color(0xFF1E1E1E);
const double _kMaxContentWidth = 560;
const double _kFieldRadius = 12;
const double _kGap = 16;
const double _kButtonHeight = 52;

// Public route constants (used by router)
class EmailCodeVerifyPage extends StatefulWidget {
  const EmailCodeVerifyPage({
    super.key,
    required this.email,
    this.fresh = true,
  });

  static const String routeName = 'verifyEmail';
  static const String routePath = '/verify-email';

  final String email;
  final bool fresh;

  @override
  State<EmailCodeVerifyPage> createState() => _EmailCodeVerifyPageState();
}

class _Txt {
  static final h1 = GoogleFonts.roboto(fontSize: 28, fontWeight: FontWeight.w700, color: Colors.white);
  static final body = GoogleFonts.roboto(fontSize: 16, color: Colors.white);
  static final label = GoogleFonts.roboto(fontSize: 15, color: _kSecondaryText);
  static final small = GoogleFonts.roboto(fontSize: 14, color: _kSecondaryText);
  static final btn = GoogleFonts.roboto(fontSize: 18, fontWeight: FontWeight.w600, fontStyle: FontStyle.italic, color: Colors.black);
}

class _EmailCodeVerifyPageState extends State<EmailCodeVerifyPage> {
  final _formKey = GlobalKey<FormState>();
  final _codeCtrl = TextEditingController();
  final _codeFocus = FocusNode();

  bool _submitting = false;
  bool _resending = false;
  int _cooldown = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) FocusScope.of(context).requestFocus(_codeFocus);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _codeCtrl.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  InputDecoration _inputDecoration(String label) => InputDecoration(
        labelText: label,
        labelStyle: _Txt.label,
        enabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: _kSecondaryText, width: 1.5),
          borderRadius: BorderRadius.circular(_kFieldRadius),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: _kPrimaryText, width: 2),
          borderRadius: BorderRadius.circular(_kFieldRadius),
        ),
        errorBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: Colors.redAccent, width: 2),
          borderRadius: BorderRadius.circular(_kFieldRadius),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: Colors.redAccent, width: 2),
          borderRadius: BorderRadius.circular(_kFieldRadius),
        ),
        errorStyle: GoogleFonts.roboto(fontSize: 13, color: Colors.redAccent),
        filled: true,
        fillColor: _kSecondaryBg,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      );

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), behavior: SnackBarBehavior.floating));
  }

  void _startCooldown(int seconds) {
    setState(() => _cooldown = seconds);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (_cooldown <= 1) {
        t.cancel();
        setState(() => _cooldown = 0);
      } else {
        setState(() => _cooldown -= 1);
      }
    });
  }

  // === helper: ensure rows exist AFTER we have a session (passes RLS)
  Future<void> _ensureRowByUserId(String table, String userId) async {
    final supabase = Supabase.instance.client;
    await supabase.from(table).upsert(
      {'user_id': userId},
      onConflict: 'user_id',
      ignoreDuplicates: true,
    );
  }

  Future<void> _verify() async {
    final form = _formKey.currentState;
    if (form == null || !form.validate()) {
      _showSnack('Enter the 6-digit code.');
      return;
    }
    if (_submitting) return;

    setState(() => _submitting = true);
    HapticFeedback.lightImpact();

    try {
      final code = _codeCtrl.text.trim();
      final email = widget.email.trim();
      final client = Supabase.instance.client;

      // 1) Verify OTP for signup – returns AuthResponse (may include session/user)
      final AuthResponse res = await client.auth.verifyOTP(
        type: OtpType.signup,
        token: code,
        email: email,
      );

      // Prefer the response; fall back to current user/session
      final user = res.user ?? client.auth.currentUser;
      final session = res.session ?? client.auth.currentSession;

      if (!mounted) return;

      if (user == null || session == null) {
        // No session: don’t attempt RLS-protected inserts. Ask user to sign in.
        _showSnack('Verified. Please sign in to continue.');
        context.go('/loginPage');
        return;
      }

      // 2) With the signed-in JWT, create your rows (passes RLS)
      final uid = user.id;
      await _ensureRowByUserId('profiles', uid);
      await _ensureRowByUserId('preferences', uid);

      // 3) Navigate to the fresh profile-complete flow
      if (!mounted) return; // <-- guard across async gap to satisfy lint
      context.go('/create-or-complete-profile?fresh=1', extra: {'fresh': true});
    } on AuthException catch (e) {
      _showSnack(e.message);
    } on PostgrestException catch (e) {
      _showSnack(e.message);
    } catch (e) {
      _showSnack('Could not verify code: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _resend() async {
    if (_resending || _cooldown > 0) return;
    setState(() => _resending = true);
    try {
      await Supabase.instance.client.auth.resend(
        type: OtpType.signup,
        email: widget.email.trim(),
      );
      _showSnack('Code sent. Check your email.');
      _startCooldown(30);
    } on AuthException catch (e) {
      _showSnack(e.message);
    } catch (e) {
      _showSnack('Could not resend code: $e');
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = widget.email;

    return Scaffold(
      backgroundColor: _kScaffold,
      appBar: AppBar(
        backgroundColor: _kScaffold,
        elevation: 0,
        iconTheme: const IconThemeData(color: _kPrimaryText),
        title: Text('Verify your email', style: _Txt.body),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _kMaxContentWidth),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Enter the 6-digit code', style: _Txt.h1),
                      const SizedBox(height: 6),
                      Text('We sent a code to $email', style: _Txt.small),
                      const SizedBox(height: _kGap),
                      TextFormField(
                        controller: _codeCtrl,
                        focusNode: _codeFocus,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.oneTimeCode],
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(6),
                        ],
                        style: _Txt.body,
                        cursorColor: _kPrimaryText,
                        decoration: _inputDecoration('6-digit code'),
                        validator: (v) {
                          final s = (v ?? '').trim();
                          if (s.length != 6) return 'Enter the 6-digit code';
                          return null;
                        },
                        onFieldSubmitted: (_) => _verify(),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        height: _kButtonHeight,
                        child: ElevatedButton(
                          onPressed: _submitting ? null : _verify,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _kPrimaryText,
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            minimumSize: const Size.fromHeight(_kButtonHeight),
                          ),
                          child: _submitting
                              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                              : Text('Verify', style: _Txt.btn),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          TextButton(
                            onPressed: (_resending || _cooldown > 0) ? null : _resend,
                            child: Text(
                              _cooldown > 0 ? 'Resend in $_cooldown s' : 'Resend code',
                              style: GoogleFonts.roboto(fontSize: 15, color: Colors.white),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: Text('Check spam/junk if you don’t see it.', style: _Txt.small)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
