import 'package:flutter/material.dart';

import 'package:adaptive_360_capture_app/features/sitewise_sync/data/cloud/sitewise_auth.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';

/// The minimum sign-in the capture app needs to upload under its own identity.
///
/// ## Why this exists at all
///
/// The standalone capture app had no authentication: it captured, stitched and
/// exported locally. Uploading to a property folder needs a Supabase session,
/// because every Storage and `pano_jobs` policy is written in terms of
/// `auth.uid()`. This screen is the handoff — it signs in against **Supabase
/// Auth**, the same provider the SiteWise web app uses, and creates no accounts,
/// no tokens and no second identity store.
///
/// It is deliberately not a registration flow: accounts are provisioned by the
/// existing SiteWise process, and the default role for a new registration stays
/// `entrepreneur` in the database, not here.
class SitewiseSignInScreen extends StatefulWidget {
  const SitewiseSignInScreen({super.key, required this.auth, this.reason});

  final SitewiseAuth auth;

  /// Why the screen was opened, shown above the form (e.g. "the sign-in
  /// expired"). Kept as a parameter so the caller explains the context.
  final String? reason;

  @override
  State<SitewiseSignInScreen> createState() => _SitewiseSignInScreenState();
}

class _SitewiseSignInScreenState extends State<SitewiseSignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final account = await widget.auth.signInWithPassword(
        email: _email.text,
        password: _password.text,
      );
      if (!mounted) return;
      Navigator.of(context).pop(account);
    } on SitewiseAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'The sign-in failed: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: CaptureColors.cameraChrome,
    appBar: AppBar(
      backgroundColor: CaptureColors.cameraChrome,
      foregroundColor: Colors.white,
      title: const Text('SiteWise account'),
    ),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Sign in to upload panoramas',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.reason ??
                    'Capturing and stitching work without an account. Signing in '
                        'lets a finished panorama upload to the property it '
                        'belongs to.',
                style: const TextStyle(
                  color: CaptureColors.mutedOnDark,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 22),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                enabled: !_busy,
                style: const TextStyle(color: Colors.white),
                decoration: _decoration('Email'),
                validator: (String? value) {
                  final text = value?.trim() ?? '';
                  if (text.isEmpty) return 'Enter the email for your account.';
                  if (!text.contains('@')) return 'That does not look like an email address.';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                obscureText: true,
                enabled: !_busy,
                style: const TextStyle(color: Colors.white),
                decoration: _decoration('Password'),
                onFieldSubmitted: (_) => _submit(),
                validator: (String? value) =>
                    (value == null || value.isEmpty) ? 'Enter your password.' : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: CaptureColors.danger.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: CaptureColors.danger.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: CaptureColors.danger,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: CaptureColors.accent,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(50),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : const Text(
                        'Sign in',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Accounts and roles are managed in SiteWise. This screen cannot '
                'create an account or change a role.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: CaptureColors.mutedOnDark,
                  fontSize: 11,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  InputDecoration _decoration(String label) => InputDecoration(
    labelText: label,
    labelStyle: const TextStyle(color: CaptureColors.mutedOnDark),
    filled: true,
    fillColor: Colors.white.withValues(alpha: 0.06),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: CaptureColors.hairlineOnDark),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: CaptureColors.accentOnDark),
    ),
  );
}
