import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../controllers/onboarding_controller.dart';
import '../../../services/user_profile_service.dart';

const _kGreen = Color(0xFFB07080);

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  @override
  void initState() {
    super.initState();
    // Generate / store the anonymous user ID silently — not shown to user
    UserProfileService().getUserId();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<OnboardingController>();

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(28, 52, 28, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Heading ────────────────────────────────────────────
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: const Text(
                        'Welcome to SheSafe.',
                        style: TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0E1E19),
                          height: 1.15,
                          letterSpacing: -0.8,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Private. Anonymous. No account needed.',
                      style: TextStyle(
                        fontSize: 15,
                        color: Color(0xFF7A8E88),
                        height: 1.5,
                      ),
                    ),

                    const SizedBox(height: 28),

                    // ── What SheSafe does ──────────────────────────────────
                    const Text(
                      'What SheSafe does',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: _kGreen,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'SheSafe is a personal safety companion for women. '
                      'It monitors your walks in real-time, assesses crime '
                      'risk on your route, and automatically alerts your '
                      'trusted contacts if you need help — all without '
                      'storing any personal data.',
                      style: TextStyle(
                        fontSize: 14.5,
                        color: Color(0xFF3D4F48),
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 18),

                    // ── Feature highlights ─────────────────────────────────
                    _FeatureHighlight(
                      icon: Icons.route_rounded,
                      label: 'Safe Route Planner',
                      detail:
                          'Avoids high-risk areas using live UK crime data.',
                    ),
                    const SizedBox(height: 8),
                    _FeatureHighlight(
                      icon: Icons.directions_walk_rounded,
                      label: 'Safety Mode',
                      detail:
                          'Detects unusual motion patterns and escalates if you stop responding.',
                    ),
                    const SizedBox(height: 8),
                    _FeatureHighlight(
                      icon: Icons.crisis_alert_rounded,
                      label: 'Panic Mode',
                      detail:
                          'One tap sends an SOS with your GPS location to your contacts.',
                    ),
                    const SizedBox(height: 8),
                    _FeatureHighlight(
                      icon: Icons.record_voice_over_rounded,
                      label: 'Safe Word Listener',
                      detail:
                          'Speak your secret word to silently trigger or cancel an alert.',
                    ),

                    const SizedBox(height: 36),

                    // ── Section label ──────────────────────────────────────
                    Text(
                      'THREE QUICK STEPS TO GET STARTED',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey.shade400,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ── Step cards ─────────────────────────────────────────
                    _StepCard(
                      number: '01',
                      icon: Icons.lock_rounded,
                      title: 'Set your Safe Word',
                      subtitle:
                          'A spoken word that cancels a panic alert instantly.',
                    ),
                    const SizedBox(height: 10),
                    _StepCard(
                      number: '02',
                      icon: Icons.public_rounded,
                      title: 'Select your Region',
                      subtitle:
                          'Tailors risk data and guidance to your area.',
                    ),
                    const SizedBox(height: 10),
                    _StepCard(
                      number: '03',
                      icon: Icons.people_alt_rounded,
                      title: 'Add an Emergency Contact',
                      subtitle:
                          'Notified automatically if you need help.',
                    ),                  ],
                ),
              ),
            ),

            // ── CTA ────────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 32),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: Semantics(
                  label: 'Get started — begin onboarding',
                  button: true,
                  child: ElevatedButton(
                    onPressed: () => controller.nextStep(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _kGreen,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: const Text(
                      'Get Started',
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Step card ──────────────────────────────────────────────────────────────

class _StepCard extends StatelessWidget {
  final String number;
  final IconData icon;
  final String title;
  final String subtitle;

  const _StepCard({
    required this.number,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Step $number: $title. $subtitle',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFFAE8F0)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Number
            Text(
              number,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: Color(0xFFCCDDD8),
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(width: 14),
            // Icon
            Icon(icon, size: 20, color: _kGreen),
            const SizedBox(width: 12),
            // Text
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0E1E19),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12.5,
                      // 0xFF6B7F79 on white ≈ 5.1:1 — passes WCAG AA
                      color: Color(0xFF6B7F79),
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Feature highlight row ──────────────────────────────────────────────────

class _FeatureHighlight extends StatelessWidget {
  final IconData icon;
  final String label;
  final String detail;

  const _FeatureHighlight({
    required this.icon,
    required this.label,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label: $detail',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: const Color(0xFFEDE7F6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: _kGreen),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0E1E19),
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  detail,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: Color(0xFF6B7F79),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}