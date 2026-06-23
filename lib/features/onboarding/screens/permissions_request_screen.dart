import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../controllers/onboarding_controller.dart';
import '../../../services/permission_service.dart';

class PermissionsRequestScreen extends StatefulWidget {
  const PermissionsRequestScreen({super.key});

  @override
  State<PermissionsRequestScreen> createState() =>
      _PermissionsRequestScreenState();
}

class _PermissionsRequestScreenState extends State<PermissionsRequestScreen> {
  bool _locationRequested = false;
  bool _notificationRequested = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _requestPermissions());
  }

  Future<void> _requestPermissions() async {
    final controller = context.read<OnboardingController>();

    // Request location first
    await controller.requestLocationPermission();
    setState(() => _locationRequested = true);

    // Small delay for better UX
    await Future.delayed(const Duration(milliseconds: 500));

    // Request notification
    await controller.requestNotificationPermission();
    setState(() => _notificationRequested = true);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<OnboardingController>();
    final data = controller.data;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => controller.previousStep(),
        ),
        title: const Text('Enable Permissions'),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Scrollable content ────────────────────────────────────────
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Setting up permissions',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Please allow the following permissions when prompted:',
                      style: TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 32),
                    _buildPermissionStatus(
                      icon: Icons.location_on,
                      title: 'Location Access',
                      isGranted: data.locationGranted,
                      isRequested: _locationRequested,
                      isRequired: true,
                    ),
                    const SizedBox(height: 16),
                    _buildPermissionStatus(
                      icon: Icons.notifications,
                      title: 'Notifications',
                      isGranted: data.notificationGranted,
                      isRequested: _notificationRequested,
                      isRequired: false,
                    ),
                    if (!data.locationGranted && _locationRequested) ...[  
                      const SizedBox(height: 24),
                      _buildLocationDeniedCard(controller),
                    ],
                  ],
                ),
              ),
            ),
            // ── Sticky bottom button ──────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: controller.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : ElevatedButton(
                      onPressed: _locationRequested && _notificationRequested
                          ? () {
                              if (data.locationGranted) {
                                controller.nextStep();
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Location permission is required to continue',
                                    ),
                                  ),
                                );
                              }
                            }
                          : null,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        backgroundColor: const Color(0xFFB07080),
                        foregroundColor: Colors.white,
                      ),
                      child: const Text(
                        'Continue',
                        style: TextStyle(fontSize: 18),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Shows a contextual card when location permission has been denied.
  ///
  /// If the user permanently denied the permission (i.e. the system dialog
  /// will no longer appear), the card directs them to device Settings.
  /// Otherwise it offers a "Try Again" button to re-prompt the system dialog.
  Widget _buildLocationDeniedCard(OnboardingController controller) {
    return FutureBuilder<PermissionStatus>(
      future: Permission.location.status,
      builder: (context, snapshot) {
        final isPermanent =
            snapshot.data?.isPermanentlyDenied ?? false;

        return Card(
          color: Colors.orange.shade50,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                const Icon(Icons.warning, color: Colors.orange, size: 40),
                const SizedBox(height: 8),
                Text(
                  isPermanent
                      ? 'Location permission blocked'
                      : 'Location permission is required',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  isPermanent
                      ? 'You\'ve permanently declined location access. '
                        'Please open Settings and enable Location for SheSafe '
                        'so that Safety Mode can protect you.'
                      : 'Without location, Safety Mode can\'t work. '
                        'You can enable it later in Settings.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                if (isPermanent)
                  ElevatedButton.icon(
                    onPressed: () => PermissionService().openAppSettings(),
                    icon: const Icon(Icons.settings),
                    label: const Text('Open Settings'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE8956D),
                      foregroundColor: Colors.white,
                    ),
                  )
                else ...[
                  ElevatedButton.icon(
                    onPressed: () async {
                      await controller.requestLocationPermission();
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Try Again'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE8956D),
                      foregroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => PermissionService().openAppSettings(),
                    child: const Text('Open Settings'),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPermissionStatus({
    required IconData icon,
    required String title,
    required bool isGranted,
    required bool isRequested,
    required bool isRequired,
  }) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            Icon(icon, size: 32, color: const Color(0xFF9B72CB)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (isRequired)
                    Text(
                      'Required',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.red.shade700,
                      ),
                    ),
                ],
              ),
            ),
            if (!isRequested)
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (isGranted)
              const Icon(Icons.check_circle, color: Color(0xFFB07080), size: 32)
            else
              const Icon(Icons.cancel, color: Colors.red, size: 32),
          ],
        ),
      ),
    );
  }
}
