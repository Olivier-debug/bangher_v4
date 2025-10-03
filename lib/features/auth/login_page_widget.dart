// lib/features/auth/login_page_widget.dart
// 2025 Mobile-first, a11y-first refactor with minimal visual drift.
// - Signup ⇒ if email confirmation enabled, go to /verify-email
// - OAuth signup ⇒ mark fresh intent; on signedIn ⇒ auto-route to fresh flow
// - Login ⇒ router handles; fallback ensures profiles/preferences + routes
// - Mounted/context-safe post-frame and nav guards

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:google_fonts/google_fonts.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Color kScaffold = Colors.black;
const Color kPrimaryText = Colors.white;
const Color kSecondaryText = Color(0xFFB0B0B0);
const Color kSecondaryBg = Color(0xFF1E1E1E);
const Color kAlternate = Color(0xFF2C2C2C);
const Color kPrimary = Color(0xFFFF1493);

const double kMaxContentWidth = 560;
const double kFieldRadius = 12;
const double kGap = 16;
const double kButtonHeight = 52;
const double kIconButtonSize = 48;

const String kRouteCreateOrCompleteName = 'createOrCompleteProfile';
const String kRouteCreateOrCompletePath = '/create-or-complete-profile';
const String kRouteAfterSignInFallback = '/swipe';

// NEW: verify-email route constants (router already whitelists & defines the route)
const String kRouteVerifyEmailName = 'verifyEmail';
const String kRouteVerifyEmailPath = '/verify-email';

const String kOAuthRedirectUrlMobile = 'io.supabase.flutter://login-callback/';
const String kPasswordResetRedirectUrl = 'io.supabase.flutter://reset-callback/';

const String kFreshIntentKey = 'oauth_fresh_intent';

class Txt {
  static final h1 = GoogleFonts.roboto(fontSize: 28, fontWeight: FontWeight.w700, color: Colors.white);
  static final sub = GoogleFonts.roboto(fontSize: 15, fontStyle: FontStyle.italic, color: Colors.white);
  static final label = GoogleFonts.roboto(fontSize: 15, color: kSecondaryText);
  static final body = GoogleFonts.roboto(fontSize: 16, color: Colors.white);
  static final tab = GoogleFonts.roboto(fontSize: 16, fontWeight: FontWeight.w600);
  static final btn = GoogleFonts.roboto(fontSize: 18, fontWeight: FontWeight.w600, fontStyle: FontStyle.italic, color: Colors.black);
  static final small = GoogleFonts.roboto(fontSize: 14, color: kSecondaryText);
}

class LoginPageWidget extends StatefulWidget {
  const LoginPageWidget({super.key});
  static String routeName = 'LoginPage';
  static String routePath = '/loginPage';

  @override
  State<LoginPageWidget> createState() => LoginPageWidgetState();
}

class LoginPageWidgetState extends State<LoginPageWidget> with TickerProviderStateMixin {
  late final TabController _tab;

  final _formKeyCreate = GlobalKey<FormState>();
  final _formKeyLogin = GlobalKey<FormState>();

  final emailCreateCtrl = TextEditingController();
  final passCreateCtrl = TextEditingController();
  final emailCreateFocus = FocusNode();
  final passCreateFocus = FocusNode();

  final emailCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  final emailFocus = FocusNode();
  final passFocus = FocusNode();

  bool passCreateVisible = false;
  bool passVisible = false;

  bool _isSubmittingCreate = false;
  bool _isSubmittingSignIn = false;
  bool _isOauthLaunching = false;

  // Post-sign-in control
  bool _handledPostSignIn = false;     // prevent duplicate nav from stream + handler
  bool _oauthWasSignup = false;        // differentiate signup vs login OAuth
  StreamSubscription<AuthState>? _authSub;

  late final AnimationController _containerFade;
  late final Animation<double> _containerOpacity;
  late final AnimationController _createAnim;
  late final Animation<double> _createOpacity;
  late final Animation<Offset> _createOffset;
  late final AnimationController _loginAnim;
  late final Animation<double> _loginOpacity;
  late final Animation<Offset> _loginOffset;

  @override
  void initState() {
    super.initState();

    _tab = TabController(length: 2, vsync: this);

    _containerFade = AnimationController(vsync: this, duration: const Duration(milliseconds: 250));
    _containerOpacity = CurvedAnimation(parent: _containerFade, curve: Curves.easeInOut);

    _createAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 250));
    _createOpacity = CurvedAnimation(parent: _createAnim, curve: Curves.easeInOut);
    _createOffset = Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero).animate(_createAnim);

    _loginAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 250));
    _loginOpacity = CurvedAnimation(parent: _loginAnim, curve: Curves.easeInOut);
    _loginOffset = Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero).animate(_loginAnim);

    // Safe post-frame anim start
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final reduceMotion = MediaQuery.maybeOf(context)?.accessibleNavigation == true;
      if (reduceMotion) {
        _containerFade.value = 1;
        _createAnim.value = 1;
        _loginAnim.value = 1;
        return;
      }
      _containerFade.forward();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!mounted) return;
      _createAnim.forward();
      _loginAnim.forward();
    });

    // Auth stream fallback router + provisioning
    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((e) async {
      if (e.event == AuthChangeEvent.signedIn) {
        await _maybeHandlePostSignInRedirect(fromOAuth: _oauthWasSignup);
      } else if (e.event == AuthChangeEvent.signedOut) {
        _handledPostSignIn = false;     // allow future logins to route again
        _oauthWasSignup = false;
      }
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();

    _tab.dispose();

    emailCreateCtrl.dispose();
    passCreateCtrl.dispose();
    emailCreateFocus.dispose();
    passCreateFocus.dispose();

    emailCtrl.dispose();
    passCtrl.dispose();
    emailFocus.dispose();
    passFocus.dispose();

    _containerFade.dispose();
    _createAnim.dispose();
    _loginAnim.dispose();
    super.dispose();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  // Mounted-safe, context-free nav helper
  Future<void> _goToCreateOrComplete({
    required GoRouter router,
    required NavigatorState navigator,
    bool fresh = false,
  }) async {
    final path = fresh ? '$kRouteCreateOrCompletePath?fresh=1' : kRouteCreateOrCompletePath;

    try {
      router.go(path, extra: {'fresh': fresh});
      return;
    } catch (_) {
      // fall-through
    }
    try {
      navigator.pushReplacementNamed(path);
    } catch (e) {
      debugPrint('Navigation error: "$kRouteCreateOrCompleteName" / "$kRouteCreateOrCompletePath" not found. $e');
    }
  }

  // NEW: navigate to verify-email with email param
  Future<void> _goToVerifyEmail({
    required GoRouter router,
    required NavigatorState navigator,
    required String email,
  }) async {
    final path = '$kRouteVerifyEmailPath?email=${Uri.encodeComponent(email)}';
    try {
      router.go(path, extra: {'email': email, 'fresh': true});
      return;
    } catch (_) {
      // fall-through
    }
    try {
      // NOTE: pushNamed here uses a path; if you only use GoRouter, go() above will handle it.
      navigator.pushNamed(path);
    } catch (e) {
      debugPrint('Navigation error: "$kRouteVerifyEmailName" / "$kRouteVerifyEmailPath" not found. $e');
    }
  }

  bool _validEmail(String input) {
    final v = input.trim();
    if (v.isEmpty) return false;
    const pattern = r'^[^@\s]+@[^@\s]+\.[^@\s]+$';
    return RegExp(pattern).hasMatch(v);
  }

  Future<void> _markFreshIntent() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kFreshIntentKey, true);
  }

  Future<void> _clearFreshIntent() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(kFreshIntentKey);
  }

  Future<bool> _hasFreshIntent() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(kFreshIntentKey) == true;
  }

  /// Wait (briefly) for a real authenticated session; avoids anon writes.
  Future<Session?> _waitForSession({Duration timeout = const Duration(seconds: 3)}) async {
    final client = Supabase.instance.client;
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      final s = client.auth.currentSession;
      if (s != null) return s;
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    return client.auth.currentSession;
  }

  Future<void> _ensureRowByUserId(String table, String userId) async {
    final supabase = Supabase.instance.client;
    await supabase.from(table).upsert(
      {'user_id': userId},
      onConflict: 'user_id',
      ignoreDuplicates: true,
    );
  }

  // -------------------- AUTH ACTIONS --------------------
  Future<void> _handleCreateAccount() async {
    final form = _formKeyCreate.currentState;
    if (form == null || !form.validate()) {
      _showSnack('Please fix the highlighted fields.');
      return;
    }

    final router = GoRouter.of(context);
    final navigator = Navigator.of(context);

    final email = emailCreateCtrl.text.trim();
    final password = passCreateCtrl.text;
    if (_isSubmittingCreate) return;

    setState(() => _isSubmittingCreate = true);
    HapticFeedback.lightImpact();
    try {
      final supabase = Supabase.instance.client;
      final AuthResponse res = await supabase.auth.signUp(
        email: email,
        password: password,
        // For OTP email-code flow, redirect is optional; leaving it is harmless.
        emailRedirectTo: kIsWeb ? null : kOAuthRedirectUrlMobile,
      );

      // ✅ If confirmations are ON, you'll get NO session yet ⇒ go to verify.
      // (Some projects return user but still no session until confirm.)
      if (res.session == null || res.user == null) {
        _showSnack('We emailed you a 6-digit code.');
        await _goToVerifyEmail(router: router, navigator: navigator, email: email);
        return;
      }

      // If confirmations are OFF: do NOT write immediately (race risk).
      // Provision after the signedIn event (auth stream), when the session is fully active.
      _showSnack('Account created! Finalizing setup…');
      // Nothing else to do here; _maybeHandlePostSignInRedirect will run.
    } on AuthException catch (e) {
      final msg = e.message;
      if (msg.toLowerCase().contains('already registered')) {
        _showSnack('Email already registered. Try signing in.');
        _tab.animateTo(1);
      } else {
        _showSnack(msg);
      }
    } on PostgrestException catch (e) {
      _showSnack(e.message);
    } catch (e) {
      _showSnack('Sign up error: $e');
    } finally {
      if (mounted) setState(() => _isSubmittingCreate = false);
    }
  }

  Future<void> _handleSignIn() async {
    final form = _formKeyLogin.currentState;
    if (form == null || !form.validate()) {
      _showSnack('Please fix the highlighted fields.');
      return;
    }

    final email = emailCtrl.text.trim();
    final password = passCtrl.text;
    if (_isSubmittingSignIn) return;

    setState(() => _isSubmittingSignIn = true);
    HapticFeedback.lightImpact();
    try {
      final supabase = Supabase.instance.client;
      final AuthResponse res = await supabase.auth.signInWithPassword(email: email, password: password);

      final user = res.user;
      if (user == null) {
        _showSnack('Sign-in succeeded but no user returned. Verify your email or try again.');
        return;
      }
      // No explicit nav here; stream fallback will route + provision if needed.
    } on AuthException catch (e) {
      _showSnack(e.message);
    } catch (e) {
      _showSnack('Sign-in error: $e');
    } finally {
      if (mounted) setState(() => _isSubmittingSignIn = false);
    }
  }

  Future<void> _startOAuth(OAuthProvider provider) async {
    final supabase = Supabase.instance.client;
    await supabase.auth.signInWithOAuth(
      provider,
      redirectTo: kIsWeb ? null : kOAuthRedirectUrlMobile,
      queryParams: provider == OAuthProvider.google ? const {'prompt': 'select_account'} : null,
    );
  }

  // OAuth from Create tab ⇒ treat as register flow
  Future<void> _handleGoogleSignUp() async {
    if (_isOauthLaunching) return;
    setState(() => _isOauthLaunching = true);
    try {
      _oauthWasSignup = true;
      await _markFreshIntent(); // signal fresh intent for router/stream fallback
      await _startOAuth(OAuthProvider.google);
    } on AuthException catch (e) {
      _showSnack(e.message);
    } catch (e) {
      _showSnack('Could not start Google sign-up: $e');
    } finally {
      if (mounted) setState(() => _isOauthLaunching = false);
    }
  }

  Future<void> _handleAppleSignUp() async {
    if (_isOauthLaunching) return;
    setState(() => _isOauthLaunching = true);
    try {
      _oauthWasSignup = true;
      await _markFreshIntent();
      await _startOAuth(OAuthProvider.apple);
    } on AuthException catch (e) {
      _showSnack(e.message);
    } catch (e) {
      _showSnack('Could not start Apple sign-up: $e');
    } finally {
      if (mounted) setState(() => _isOauthLaunching = false);
    }
  }

  // OAuth from Login tab ⇒ NOT fresh
  Future<void> _handleGoogleLogin() async {
    if (_isOauthLaunching) return;
    setState(() => _isOauthLaunching = true);
    try {
      _oauthWasSignup = false;
      await _startOAuth(OAuthProvider.google);
    } on AuthException catch (e) {
      _showSnack(e.message);
    } catch (e) {
      _showSnack('Could not start Google sign-in: $e');
    } finally {
      if (mounted) setState(() => _isOauthLaunching = false);
    }
  }

  Future<void> _handleAppleLogin() async {
    if (_isOauthLaunching) return;
    setState(() => _isOauthLaunching = true);
    try {
      _oauthWasSignup = false;
      await _startOAuth(OAuthProvider.apple);
    } on AuthException catch (e) {
      _showSnack(e.message);
    } catch (e) {
      _showSnack('Could not start Apple sign-in: $e');
    } finally {
      if (mounted) setState(() => _isOauthLaunching = false);
    }
  }

  Future<void> _handleForgotPassword() async {
    final email = emailCtrl.text.trim();
    if (email.isEmpty || !_validEmail(email)) {
      _showSnack('Enter a valid email first.');
      return;
    }
    try {
      final supabase = Supabase.instance.client;
      await supabase.auth.resetPasswordForEmail(email, redirectTo: kIsWeb ? null : kPasswordResetRedirectUrl);
      _showSnack('Password reset link sent if the email exists.');
    } on AuthException catch (e) {
      _showSnack(e.message);
    } catch (e) {
      _showSnack('Could not send reset link: $e.');
    }
  }

  // ---------- Post sign-in redirect + provisioning fallback ----------
  Future<void> _maybeHandlePostSignInRedirect({required bool fromOAuth}) async {
    if (_handledPostSignIn) return;

    final client = Supabase.instance.client;

    // Ensure we actually have a non-anon session (important on Web).
    final session = await _waitForSession();
    if (session == null) return;

    final me = client.auth.currentUser;
    if (me == null) return;

    final router = mounted ? GoRouter.of(context) : null;
    final navigator = mounted ? Navigator.of(context) : null;

    try {
      // Fresh OAuth signup intent: go straight to create/complete after provisioning
      final bool treatAsFresh = fromOAuth && await _hasFreshIntent();
      if (treatAsFresh) {
        await _clearFreshIntent();
      }

      // Idempotent provisioning (safe whether rows exist or not)
      try {
        await _ensureRowByUserId('profiles', me.id);
        await _ensureRowByUserId('preferences', me.id);
      } on PostgrestException catch (e) {
        debugPrint('Provisioning failed: ${e.message}');
      }

      if (router != null && navigator != null) {
        // Decide where to go based on profile completeness (best-effort)
        bool isComplete = false;
        try {
          final row = await client
              .from('profiles')
              .select('complete')
              .eq('user_id', me.id)
              .maybeSingle();
          isComplete = (row?['complete'] as bool?) ?? false;
        } catch (_) {
          // ignore — route to create/complete by default if unsure
        }

        if (treatAsFresh) {
          await _goToCreateOrComplete(router: router, navigator: navigator, fresh: true);
        } else if (isComplete) {
          router.go(kRouteAfterSignInFallback);
        } else {
          await _goToCreateOrComplete(router: router, navigator: navigator, fresh: true);
        }
        _handledPostSignIn = true;
        _oauthWasSignup = false;
      }
    } catch (_) {
      // Silent: router may already be handling it via its own auth redirect.
    }
  }

  // ----------------------------------------------------------------------
  InputDecoration _inputDecoration(String label) => InputDecoration(
        labelText: label,
        labelStyle: Txt.label,
        enabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: kSecondaryText, width: 1.5),
          borderRadius: BorderRadius.circular(kFieldRadius),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: kPrimaryText, width: 2),
          borderRadius: BorderRadius.circular(kFieldRadius),
        ),
        errorBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: Colors.redAccent, width: 2),
          borderRadius: BorderRadius.circular(kFieldRadius),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: Colors.redAccent, width: 2),
          borderRadius: BorderRadius.circular(kFieldRadius),
        ),
        errorStyle: GoogleFonts.roboto(fontSize: 13, color: Colors.redAccent),
        filled: true,
        fillColor: kSecondaryBg,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      );

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final platform = Theme.of(context).platform;
    final canUseApple = platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        FocusScope.of(context).unfocus();
        FocusManager.instance.primaryFocus?.unfocus();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent),
        child: Scaffold(
          backgroundColor: kScaffold,
          resizeToAvoidBottomInset: true,
          body: SafeArea(
            top: true,
            bottom: true,
            child: AnimatedPadding(
              padding: EdgeInsets.only(bottom: viewInsets > 0 ? 8 : 0),
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
                  child: Column(
                    children: [
                      const SizedBox(height: 24),
                      Semantics(label: 'Brand logo', child: const BrandLogo()),
                      const SizedBox(height: 8),
                      Expanded(
                        child: FadeTransition(
                          opacity: _containerOpacity,
                          child: Material(
                            color: Colors.transparent,
                            elevation: 1,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            child: Column(
                              children: [
                                const SizedBox(height: 8),
                                TabBar(
                                  controller: _tab,
                                  labelColor: Colors.white,
                                  unselectedLabelColor: kSecondaryText,
                                  labelStyle: Txt.tab,
                                  unselectedLabelStyle: Txt.tab,
                                  indicatorColor: kPrimary,
                                  indicatorWeight: 2,
                                  tabs: const [Tab(text: 'Create Account'), Tab(text: 'Log In')],
                                ),
                                Expanded(
                                  child: TabBarView(
                                    controller: _tab,
                                    children: [
                                      KeepAliveWrapper(
                                        child: SlideTransition(
                                          position: _createOffset,
                                          child: FadeTransition(
                                            opacity: _createOpacity,
                                            child: CreateAccountForm(
                                              formKey: _formKeyCreate,
                                              emailCtrl: emailCreateCtrl,
                                              passCtrl: passCreateCtrl,
                                              emailFocus: emailCreateFocus,
                                              passFocus: passCreateFocus,
                                              passVisible: passCreateVisible,
                                              isSubmitting: _isSubmittingCreate || _isOauthLaunching,
                                              onToggleVisibility: () => setState(() => passCreateVisible = !passCreateVisible),
                                              onSubmit: _handleCreateAccount,           // email signup
                                              onGoogle: _handleGoogleSignUp,            // OAuth signup
                                              onApple: canUseApple ? _handleAppleSignUp : null,
                                              inputDecoration: _inputDecoration,
                                            ),
                                          ),
                                        ),
                                      ),
                                      KeepAliveWrapper(
                                        child: SlideTransition(
                                          position: _loginOffset,
                                          child: FadeTransition(
                                            opacity: _loginOpacity,
                                            child: LoginForm(
                                              formKey: _formKeyLogin,
                                              emailCtrl: emailCtrl,
                                              passCtrl: passCtrl,
                                              emailFocus: emailFocus,
                                              passFocus: passFocus,
                                              passVisible: passVisible,
                                              isSubmitting: _isSubmittingSignIn || _isOauthLaunching,
                                              onToggleVisibility: () => setState(() => passVisible = !passVisible),
                                              onSubmit: _handleSignIn,
                                              onGoogle: _handleGoogleLogin,
                                              onApple: canUseApple ? _handleAppleLogin : null,
                                              onForgot: _handleForgotPassword,
                                              inputDecoration: _inputDecoration,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
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
        ),
      ),
    );
  }
}

class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key});
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(0),
      child: Image.asset(
        'assets/images/Bangher_Logo.png',
        width: 220,
        height: 88,
        fit: BoxFit.contain,
        alignment: Alignment.center,
      ),
    );
  }
}

class CreateAccountForm extends StatelessWidget {
  const CreateAccountForm({
    super.key,
    required this.formKey,
    required this.emailCtrl,
    required this.passCtrl,
    required this.emailFocus,
    required this.passFocus,
    required this.passVisible,
    required this.isSubmitting,
    required this.onToggleVisibility,
    required this.onSubmit,
    required this.inputDecoration,
    this.onGoogle,
    this.onApple,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController emailCtrl;
  final TextEditingController passCtrl;
  final FocusNode emailFocus;
  final FocusNode passFocus;
  final bool passVisible;
  final bool isSubmitting;
  final VoidCallback onToggleVisibility;
  final VoidCallback onSubmit;
  final VoidCallback? onGoogle;
  final VoidCallback? onApple;
  final InputDecoration Function(String) inputDecoration;

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: const NoGlowScrollBehavior(),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Form(
          key: formKey,
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Create Account', style: Txt.h1),
                const SizedBox(height: 6),
                Text('Get started by filling out the form below.', style: Txt.sub),
                const SizedBox(height: kGap),
                TextFormField(
                  controller: emailCtrl,
                  focusNode: emailFocus,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.email],
                  textCapitalization: TextCapitalization.none,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 100,
                  maxLengthEnforcement: MaxLengthEnforcement.enforced,
                  buildCounter: (_, {required int currentLength, required bool isFocused, int? maxLength}) => null,
                  style: Txt.body,
                  cursorColor: kPrimary,
                  decoration: inputDecoration('Email'),
                  onFieldSubmitted: (_) => FocusScope.of(context).requestFocus(passFocus),
                  validator: (v) {
                    final val = v?.trim() ?? '';
                    if (val.isEmpty) return 'Email is required';
                    const pattern = r'^[^@\s]+@[^@\s]+\.[^@\s]+$';
                    if (!RegExp(pattern).hasMatch(val)) return 'Enter a valid email';
                    return null;
                  },
                ),
                const SizedBox(height: kGap),
                TextFormField(
                  controller: passCtrl,
                  focusNode: passFocus,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.newPassword],
                  obscureText: !passVisible,
                  enableSuggestions: false,
                  autocorrect: false,
                  style: Txt.body,
                  cursorColor: kPrimary,
                  decoration: inputDecoration('Password').copyWith(
                    suffixIcon: Semantics(
                      label: passVisible ? 'Hide password' : 'Show password',
                      button: true,
                      child: IconButton(
                        tooltip: passVisible ? 'Hide password' : 'Show password',
                        onPressed: onToggleVisibility,
                        icon: Icon(passVisible ? Icons.visibility_off_outlined : Icons.visibility_outlined, color: kSecondaryText),
                        splashRadius: kIconButtonSize / 2,
                      ),
                    ),
                  ),
                  onFieldSubmitted: (_) => onSubmit(),
                  validator: (v) {
                    final val = v ?? '';
                    if (val.isEmpty) return 'Password is required';
                    if (val.length < 7) return 'Use at least 7 characters';
                    return null;
                  },
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 12),
                  child: SizedBox(
                    width: double.infinity,
                    height: kButtonHeight,
                    child: ElevatedButton(
                      onPressed: isSubmitting ? null : onSubmit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kPrimaryText,
                        foregroundColor: Colors.black,
                        elevation: 1,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        minimumSize: const Size.fromHeight(kButtonHeight),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        tapTargetSize: MaterialTapTargetSize.padded,
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 150),
                        child: isSubmitting
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : Text('Get Started', style: Txt.btn, key: const ValueKey('create_text')),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: const OrDivider(text: 'Or sign up with'),
                  ),
                ),
                const SizedBox(height: 8),
                AuthSocialButtons(isSubmitting: isSubmitting, onGoogle: onGoogle, onApple: onApple),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class LoginForm extends StatelessWidget {
  const LoginForm({
    super.key,
    required this.formKey,
    required this.emailCtrl,
    required this.passCtrl,
    required this.emailFocus,
    required this.passFocus,
    required this.passVisible,
    required this.isSubmitting,
    required this.onToggleVisibility,
    required this.onSubmit,
    required this.inputDecoration,
    this.onGoogle,
    this.onApple,
    this.onForgot,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController emailCtrl;
  final TextEditingController passCtrl;
  final FocusNode emailFocus;
  final FocusNode passFocus;
  final bool passVisible;
  final bool isSubmitting;
  final VoidCallback onToggleVisibility;
  final VoidCallback onSubmit;
  final VoidCallback? onGoogle;
  final VoidCallback? onApple;
  final VoidCallback? onForgot;
  final InputDecoration Function(String) inputDecoration;

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: const NoGlowScrollBehavior(),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Welcome Back', style: Txt.h1),
              const SizedBox(height: 6),
              Text('Enter your details below to log in to your account.', style: Txt.sub),
              const SizedBox(height: kGap),
              TextFormField(
                controller: emailCtrl,
                focusNode: emailFocus,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                textCapitalization: TextCapitalization.none,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                enableSuggestions: false,
                style: Txt.body,
                cursorColor: kPrimary,
                decoration: inputDecoration('Email'),
                onFieldSubmitted: (_) => FocusScope.of(context).requestFocus(passFocus),
                validator: (v) {
                  final val = v?.trim() ?? '';
                  if (val.isEmpty) return 'Email is required';
                  const pattern = r'^[^@\s]+@[^@\s]+\.[^@\s]+$';
                  if (!RegExp(pattern).hasMatch(val)) return 'Enter a valid email';
                  return null;
                },
              ),
              const SizedBox(height: kGap),
              TextFormField(
                controller: passCtrl,
                focusNode: passFocus,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.password],
                obscureText: !passVisible,
                enableSuggestions: false,
                autocorrect: false,
                style: Txt.body,
                cursorColor: kPrimary,
                decoration: inputDecoration('Password').copyWith(
                  suffixIcon: Semantics(
                    label: passVisible ? 'Hide password' : 'Show password',
                    button: true,
                    child: IconButton(
                      tooltip: passVisible ? 'Hide password' : 'Show password',
                      onPressed: onToggleVisibility,
                      icon: Icon(passVisible ? Icons.visibility_off_outlined : Icons.visibility_outlined, color: kSecondaryText),
                      splashRadius: kIconButtonSize / 2,
                    ),
                  ),
                ),
                onFieldSubmitted: (_) => onSubmit(),
                validator: (v) {
                  final val = v ?? '';
                  if (val.isEmpty) return 'Password is required';
                  if (val.length < 7) return 'Use at least 7 characters';
                  return null;
                },
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: kButtonHeight,
                child: ElevatedButton(
                  onPressed: isSubmitting ? null : onSubmit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kPrimaryText,
                    foregroundColor: Colors.black,
                    elevation: 2,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    minimumSize: const Size.fromHeight(kButtonHeight),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: isSubmitting
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text('Sign In', style: Txt.btn, key: const ValueKey('signin_text')),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: const OrDivider(text: 'Or sign in with'),
                ),
              ),
              const SizedBox(height: 8),
              AuthSocialButtons(isSubmitting: isSubmitting, onGoogle: onGoogle, onApple: onApple),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.center,
                child: SizedBox(
                  height: kButtonHeight,
                  child: OutlinedButton(
                    onPressed: isSubmitting ? null : onForgot,
                    style: OutlinedButton.styleFrom(
                      backgroundColor: kSecondaryText.withValues(alpha: 0.18),
                      side: const BorderSide(color: kSecondaryBg, width: 2),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                    ),
                    child: Text('Forgot Password?', style: Txt.btn),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AuthSocialButtons extends StatelessWidget {
  const AuthSocialButtons({super.key, required this.isSubmitting, this.onGoogle, this.onApple});
  final bool isSubmitting;
  final VoidCallback? onGoogle;
  final VoidCallback? onApple;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final hasApple = onApple != null;
            final isWide = constraints.maxWidth >= 420 && hasApple;

            final googleBtn = SocialButton(
              label: 'Continue with Google',
              icon: const FaIcon(FontAwesomeIcons.google, size: 20),
              onPressed: isSubmitting ? null : onGoogle,
            );
            final appleBtn = hasApple
                ? SocialButton(
                    label: 'Continue with Apple',
                    icon: const FaIcon(FontAwesomeIcons.apple, size: 24),
                    onPressed: isSubmitting ? null : onApple,
                  )
                : null;

            if (isWide && appleBtn != null) {
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [Expanded(child: googleBtn), const SizedBox(width: 12), Expanded(child: appleBtn)],
              );
            }

            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(width: double.infinity, child: googleBtn),
                if (appleBtn != null) ...[
                  const SizedBox(height: 12),
                  SizedBox(width: double.infinity, child: appleBtn),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class SocialButton extends StatelessWidget {
  const SocialButton({super.key, required this.label, required this.icon, required this.onPressed});
  final String label;
  final Widget icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kButtonHeight,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: IconTheme.merge(data: const IconThemeData(color: kSecondaryText), child: icon),
        label: Text(label, style: Txt.small),
        style: OutlinedButton.styleFrom(
          backgroundColor: kSecondaryBg,
          foregroundColor: Colors.white,
          side: const BorderSide(color: kAlternate, width: 2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          minimumSize: const Size.fromHeight(kButtonHeight),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
      ),
    );
  }
}

class OrDivider extends StatelessWidget {
  const OrDivider({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: SizedBox(
        width: double.infinity,
        height: 24,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(child: Align(alignment: Alignment.center, child: Container(height: 1, color: kAlternate))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              color: kScaffold,
              child: Text(text, textAlign: TextAlign.center, style: GoogleFonts.roboto(fontSize: 15, color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
}

class KeepAliveWrapper extends StatefulWidget {
  const KeepAliveWrapper({super.key, required this.child});
  final Widget child;
  @override
  State<KeepAliveWrapper> createState() => KeepAliveWrapperState();
}

class KeepAliveWrapperState extends State<KeepAliveWrapper> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class NoGlowScrollBehavior extends ScrollBehavior {
  const NoGlowScrollBehavior();
  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) => child;
}
