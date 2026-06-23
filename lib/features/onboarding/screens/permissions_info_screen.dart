import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../controllers/onboarding_controller.dart';

class PermissionsInfoScreen extends StatelessWidget {
  const PermissionsInfoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<OnboardingController>();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => controller.previousStep(),
        ),
        title: const Text('Permissions'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Why we need permissions',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'SheSafe works entirely on your device — no cloud account, '
                'no personal data is uploaded. The permissions below let the '
                'app monitor your safety in real time and contact your trusted '
                'people when it matters. Here is exactly what each one is used for:',
                style: TextStyle(fontSize: 15, height: 1.55),
              ),
              const SizedBox(height: 32),
              Expanded(
                child: ListView(
                  children: [
                    _buildPermissionCard(
                      icon: Icons.location_on,
                      title: 'Location Access',
                      description: 'Required for Safety Mode',
                      details: [
                        '• Used only when Safety Mode is active',
                        '• Helps detect unusual movement patterns',
                        '• Allows sending your location to trusted contacts',
                        '• We don\'t store raw tracking logs',
                      ],
                      isRequired: true,
                    ),
                    const SizedBox(height: 16),
                    _buildPermissionCard(
                      icon: Icons.notifications,
                      title: 'Notifications',
                      description: 'Recommended for alerts',
                      details: [
                        '• Receive safety alerts and warnings',
                        '• Get updates during escalation',
                        '• Stay informed about your safety status',
                      ],
                      isRequired: false,
                    ),
                    const SizedBox(height: 16),
                    _buildPermissionCard(
                      icon: Icons.mic,
                      title: 'Microphone Access',
                      description: 'For safe word detection',
                      details: [
                        '• Only used during Panic Mode',
                        '• Detects your safe word to cancel alerts',
                        '• Will be requested when needed',
                        '• Audio is not recorded or stored',
                      ],
                      isRequired: false,
                      subtitle: 'Will request later',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  controller.nextStep();
                },
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: const Color(0xFFB07080),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text(
                  'Enable Permissions',
                  style: TextStyle(fontSize: 18),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPermissionCard({
    required IconData icon,
    required String title,
    required String description,
    required List<String> details,
    required bool isRequired,
    String? subtitle,
  }) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 32, color: const Color(0xFF9B72CB)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        description,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isRequired)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.red.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Required',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.red.shade700,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            ...details.map((detail) => Padding(
                  padding: const EdgeInsets.only(left: 8, bottom: 4),
                  child: Text(
                    detail,
                    style: const TextStyle(fontSize: 14),
                  ),
                )),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFEDE7F6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF9B72CB),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
