import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../controllers/onboarding_controller.dart';
import '../../../models/onboarding_data.dart';
import 'welcome_screen.dart';
import 'profile_setup_screen.dart';
import 'permissions_info_screen.dart';
import 'permissions_request_screen.dart';
import 'motion_baseline_calibration_screen.dart';
import 'safe_word_setup_screen.dart';
import 'safe_word_test_screen.dart';
import 'region_selection_screen.dart';
import 'trusted_contacts_screen.dart';
import 'onboarding_review_screen.dart';

class OnboardingFlow extends StatelessWidget {
  const OnboardingFlow({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => OnboardingController()..initialize(),
      child: Consumer<OnboardingController>(
        builder: (context, controller, _) {
          if (controller.isLoading && controller.data.currentStep == OnboardingStep.welcome) {
            return const Scaffold(
              body: Center(
                child: CircularProgressIndicator(),
              ),
            );
          }

          return _getScreenForStep(controller.data.currentStep);
        },
      ),
    );
  }

  Widget _getScreenForStep(OnboardingStep step) {
    switch (step) {
      case OnboardingStep.welcome:
        return const WelcomeScreen();
      case OnboardingStep.profileSetup:
        return const ProfileSetupScreen();
      case OnboardingStep.permissionsInfo:
        return const PermissionsInfoScreen();
      case OnboardingStep.permissionsRequest:
        return const PermissionsRequestScreen();
      case OnboardingStep.motionBaselineCalibration:
        return Builder(
          builder: (context) {
            final controller = context.read<OnboardingController>();
            return MotionBaselineCalibrationScreen(
              isOnboarding: true,
              onComplete: () {
                controller.markCalibrationComplete();
                controller.nextStep();
              },
              onBack: () => controller.previousStep(),
            );
          },
        );
      case OnboardingStep.safeWordSetup:
        return const SafeWordSetupScreen();
      case OnboardingStep.safeWordTest:
        return const SafeWordTestScreen();
      case OnboardingStep.regionSelection:
        return const RegionSelectionScreen();
      case OnboardingStep.trustedContacts:
        return const TrustedContactsScreen();
      case OnboardingStep.review:
        return const OnboardingReviewScreen();
    }
  }
}
