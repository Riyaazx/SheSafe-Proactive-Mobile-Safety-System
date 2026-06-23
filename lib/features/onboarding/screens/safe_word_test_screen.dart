import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../controllers/onboarding_controller.dart';
import '../../../models/onboarding_data.dart';

class SafeWordTestScreen extends StatefulWidget {
  const SafeWordTestScreen({super.key});

  @override
  State<SafeWordTestScreen> createState() => _SafeWordTestScreenState();
}

class _SafeWordTestScreenState extends State<SafeWordTestScreen> {
  bool _isTesting = false;

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
        title: const Text('Test Safe Word'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Test Your Safe Word',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Let\'s make sure speech recognition can detect your safe word.',
                style: TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 32),
              Center(
                child: data.safeWordVerified
                    ? _buildSuccessView(data)
                    : _isTesting
                        ? _buildTestingView(data)
                        : _buildReadyView(data),
              ),
              const SizedBox(height: 16),
              if (controller.error != null)
                Card(
                  color: const Color(0xFFFCE4EC),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.warning, color: Color(0xFFB07080)),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                controller.error!,
                                style: const TextStyle(
                                  color: Color(0xFFB07080),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Text('Tips:'),
                        const Text('• Speak clearly and loudly'),
                        const Text('• Reduce background noise'),
                        const Text('• Hold phone closer to mouth'),
                        const Text('• Try choosing an easier word'),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              if (data.safeWordVerified)
                ElevatedButton(
                  onPressed: () => controller.nextStep(),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: const Color(0xFFB07080),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text(
                    'Continue',
                    style: TextStyle(fontSize: 18),
                  ),
                )
              else if (!_isTesting)
                Column(
                  children: [
                    ElevatedButton(
                      onPressed: controller.isLoading
                          ? null
                          : () async {
                              if (!controller.speechAvailable) {
                                await controller.requestMicrophonePermission();
                                if (!controller.data.microphoneGranted) {
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Microphone permission is required',
                                      ),
                                    ),
                                  );
                                  return;
                                }
                              }

                              setState(() => _isTesting = true);
                              controller.clearError();
                              
                              final success = await controller.testSafeWord();

                              if (!context.mounted) return;
                              setState(() => _isTesting = false);

                              if (success) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Safe word recognized!'),
                                      backgroundColor: Color(0xFFB07080),
                                    ),
                                  );
                              }
                            },
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        backgroundColor: const Color(0xFFB07080),
                        foregroundColor: Colors.white,
                      ),
                      child: const Text(
                        'Start Test',
                        style: TextStyle(fontSize: 18),
                      ),
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: () => controller
                          .goToStep(OnboardingStep.regionSelection),
                      child: Text(
                        'Skip for now',
                        style: TextStyle(color: Colors.grey.shade500),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReadyView(dynamic data) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(
          Icons.mic,
          size: 120,
          color: Color(0xFF9B72CB),
        ),
        const SizedBox(height: 24),
        const Text(
          'Ready to test',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              children: [
                const Text(
                  'Your safe word:',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '"${data.safeWord}"',
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            'When you press "Start Test", speak your safe word clearly within 5 seconds.',
            style: TextStyle(fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  Widget _buildTestingView(dynamic data) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 200,
              height: 200,
              child: CircularProgressIndicator(
                strokeWidth: 8,
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF9B72CB)),
              ),
            ),
            Icon(
              Icons.mic,
              size: 80,
              color: Colors.red.shade400,
            ),
          ],
        ),
        const SizedBox(height: 32),
        const Text(
          'Listening...',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Text(
              'Say: "${data.safeWord}"',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Color(0xFF9B72CB),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSuccessView(dynamic data) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(
          Icons.check_circle,
          size: 120,
          color: Color(0xFFB07080),
        ),
        const SizedBox(height: 24),
        const Text(
          'Success!',
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            color: Color(0xFFB07080),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Your safe word was recognized',
          style: TextStyle(
            fontSize: 18,
            color: Colors.grey,
          ),
        ),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              children: [
                const Icon(Icons.check, color: Color(0xFFB07080), size: 40),
                const SizedBox(height: 12),
                Text(
                  '"${data.safeWord}"',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'will silently cancel a Panic Mode alert',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
