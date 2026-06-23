import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../controllers/onboarding_controller.dart';
import '../../../services/secure_storage_service.dart';

const _kAccent = Color(0xFFB07080);

/// Onboarding step — collects the user's name and age (optional, skippable).
class ProfileSetupScreen extends StatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();
  bool _saving = false;
  bool _triedSubmit = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _ageCtrl.dispose();
    super.dispose();
  }

  bool get _canProceed {
    final name = _nameCtrl.text.trim();
    final age = int.tryParse(_ageCtrl.text.trim());
    return name.length >= 2 && age != null && age >= 13 && age <= 120;
  }

  Future<void> _continue() async {
    setState(() => _triedSubmit = true);
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final storage = SecureStorageService();
    await storage.saveUserName(_nameCtrl.text.trim());
    await storage.saveUserAge(int.parse(_ageCtrl.text.trim()));
    if (!mounted) return;
    setState(() => _saving = false);
    context.read<OnboardingController>().nextStep();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF1A1A1A)),
          onPressed: () => context.read<OnboardingController>().previousStep(),
        ),
      ),
      body: SafeArea(
        child: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 32),
            child: Form(
              key: _formKey,
              autovalidateMode: _triedSubmit
                  ? AutovalidateMode.onUserInteraction
                  : AutovalidateMode.disabled,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Header ────────────────────────────────────────────────
                  const Icon(Icons.person_outline, size: 42, color: _kAccent),
                  const SizedBox(height: 20),
                  const Text(
                    'Tell us about you',
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0E1E19),
                      height: 1.15,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Your name will appear in emergency alerts sent to your trusted contacts. '
                    'Your age helps personalise your safety experience.',
                    style: TextStyle(
                      fontSize: 14.5,
                      color: Color(0xFF7A8E88),
                      height: 1.55,
                    ),
                  ),
                  const SizedBox(height: 34),

                  // ── Name field ────────────────────────────────────────────
                  TextFormField(
                    controller: _nameCtrl,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Your name',
                      hintText: 'e.g. Emma',
                      prefixIcon:
                          const Icon(Icons.badge_outlined, color: _kAccent),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            const BorderSide(color: _kAccent, width: 2),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey.shade300),
                      ),
                      errorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            const BorderSide(color: Colors.red, width: 1.5),
                      ),
                      focusedErrorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            const BorderSide(color: Colors.red, width: 2),
                      ),
                      filled: true,
                      fillColor: const Color(0xFFFFF5F8),
                    ),
                    validator: (v) {
                      if (v == null || v.trim().length < 2) {
                        return 'Please enter your name (at least 2 characters)';
                      }
                      return null;
                    },
                  ),

                  const SizedBox(height: 18),

                  // ── Age field ─────────────────────────────────────────────
                  TextFormField(
                    controller: _ageCtrl,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(3),
                    ],
                    onChanged: (_) => setState(() {}),
                    onFieldSubmitted: (_) {
                      if (_canProceed) _continue();
                    },
                    decoration: InputDecoration(
                      labelText: 'Your age',
                      hintText: 'e.g. 22',
                      prefixIcon:
                          const Icon(Icons.cake_outlined, color: _kAccent),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            const BorderSide(color: _kAccent, width: 2),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey.shade300),
                      ),
                      errorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            const BorderSide(color: Colors.red, width: 1.5),
                      ),
                      focusedErrorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            const BorderSide(color: Colors.red, width: 2),
                      ),
                      filled: true,
                      fillColor: const Color(0xFFFFF5F8),
                    ),
                    validator: (v) {
                      final age = int.tryParse(v?.trim() ?? '');
                      if (age == null) return 'Please enter your age';
                      if (age < 13) {
                        return 'You must be at least 13 to use this app';
                      }
                      if (age > 120) return 'Please enter a valid age';
                      return null;
                    },
                  ),

                  const SizedBox(height: 40),

                  // ── CTA ───────────────────────────────────────────────────
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      onPressed: _saving ? null : _continue,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _kAccent,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.grey.shade300,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      child: _saving
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2.5),
                            )
                          : const Text(
                              'Continue',
                              style: TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w700),
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // ── Skip ──────────────────────────────────────────────────
                  Center(
                    child: TextButton(
                      onPressed: _saving
                          ? null
                          : () => context
                              .read<OnboardingController>()
                              .nextStep(),
                      child: Text(
                        'Skip for now',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade500,
                          fontWeight: FontWeight.w500,
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
    );
  }
}
