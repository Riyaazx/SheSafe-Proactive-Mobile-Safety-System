import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../controllers/onboarding_controller.dart';
import '../../../models/onboarding_data.dart';

class SafeWordSetupScreen extends StatefulWidget {
  const SafeWordSetupScreen({super.key});

  @override
  State<SafeWordSetupScreen> createState() => _SafeWordSetupScreenState();
}

class _SafeWordSetupScreenState extends State<SafeWordSetupScreen> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _initialized = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<OnboardingController>();
    final data = controller.data;

    // Populate text field with existing safe word on first build
    if (!_initialized && data.safeWord != null) {
      _controller.text = data.safeWord!;
      _initialized = true;
    }

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => controller.previousStep(),
        ),
        title: const Text('Safe Word'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Choose Your Safe Word',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Speak this word during Panic Mode to silently cancel the alert if you\'re safe.',
                    style: TextStyle(fontSize: 16, color: Color(0xFF5C4A55)),
                  ),
                  const SizedBox(height: 20),

                  // ── How the safe word protects you ───────────────────────
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8D7E3),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFF0B8CC)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Row(
                          children: [
                            Icon(Icons.shield_rounded,
                                size: 18, color: Color(0xFFB07080)),
                            SizedBox(width: 8),
                            Text(
                              'How the safe word works',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFB07080),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 10),
                        Text(
                          'When Panic Mode activates, SheSafe listens for your safe word. Say it and the alert cancels silently — no message is sent. Stay quiet and your contacts are notified with your location after the countdown.',
                          style: TextStyle(fontSize: 13.5, height: 1.6),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Audio is never recorded or stored.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFFA0406A),
                            fontStyle: FontStyle.italic,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: _controller,
                    decoration: InputDecoration(
                      labelText: 'Your Safe Word',
                      hintText: 'e.g., "pineapple"',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.lock, color: Color(0xFFB07080)),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.info_outline,
                            color: Color(0xFF9B72CB)),
                        tooltip: 'Tips for choosing',
                        onPressed: () => _showTipsSheet(context),
                      ),
                    ),
                    textCapitalization: TextCapitalization.none,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Please enter a safe word';
                      }
                      final wordCount = value.trim().split(' ').length;
                      if (wordCount > 3) {
                        return 'Maximum 3 words';
                      }
                      final commonWords = ['hello', 'ok', 'yes', 'no', 'the', 'a', 'an'];
                      if (commonWords.contains(value.trim().toLowerCase())) {
                        return 'Please choose a less common word';
                      }
                      return null;
                    },
                  ),
                  if (data.safeWord != null) ...[
                    const SizedBox(height: 16),
                    Card(
                      color: const Color(0xFFF8D7E3),
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle, color: Color(0xFFB07080)),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Safe word saved',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFFB07080),
                                    ),
                                  ),
                                  Text(
                                    '"${data.safeWord}"',
                                    style: const TextStyle(
                                      color: Color(0xFFB07080),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (controller.error != null) ...[
                    const SizedBox(height: 16),
                    Card(
                      color: Colors.red.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Row(
                          children: [
                            Icon(Icons.error, color: Colors.red.shade700),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                controller.error!,
                                style: TextStyle(color: Colors.red.shade700),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: controller.isLoading
                        ? null
                        : () async {
                            if (_formKey.currentState!.validate()) {
                              await controller.setSafeWord(_controller.text);
                              if (controller.error == null) {
                                controller.nextStep();
                              }
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: const Color(0xFFB07080),
                      foregroundColor: Colors.white,
                    ),
                    child: controller.isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : const Text(
                            'Save & Continue',
                            style: TextStyle(fontSize: 18),
                          ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () =>
                        // Skip both safeWordSetup and safeWordTest
                        controller.goToStep(OnboardingStep.regionSelection),
                    child: Text(
                      'Not now',
                      style: TextStyle(color: Colors.grey.shade500),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showTipsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEDE7F6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.tips_and_updates,
                        color: Color(0xFF9B72CB)),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Tips for Choosing',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildTip('✓  Use 1–3 words maximum'),
              _buildTip('✓  Choose something memorable'),
              _buildTip('✓  Easy to pronounce clearly'),
              _buildTip('✗  Avoid common words (hello, ok)'),
              _buildTip('✗  Don\'t use names or locations'),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTip(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 6),
      child: Text(
        text,
        style: const TextStyle(fontSize: 14, height: 1.5),
      ),
    );
  }
}
