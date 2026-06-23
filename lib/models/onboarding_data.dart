enum OnboardingStep {
  welcome,
  profileSetup,
  permissionsInfo,
  permissionsRequest,
  motionBaselineCalibration,
  safeWordSetup,
  safeWordTest,
  regionSelection,
  trustedContacts,
  review,
}

class OnboardingData {
  // Permissions
  bool locationGranted;
  bool microphoneGranted;
  bool notificationGranted;

  // Calibration
  bool motionBaselineCalibrated;

  // Safe word
  String? safeWord;
  bool safeWordVerified;

  // Contacts
  List<Map<String, dynamic>> trustedContacts;

  // Progress
  OnboardingStep currentStep;
  bool isComplete;

  OnboardingData({
    this.locationGranted = false,
    this.microphoneGranted = false,
    this.notificationGranted = false,
    this.motionBaselineCalibrated = false,
    this.safeWord,
    this.safeWordVerified = false,
    this.trustedContacts = const [],
    this.currentStep = OnboardingStep.welcome,
    this.isComplete = false,
  });

  bool get canProceedToNextStep {
    switch (currentStep) {
      case OnboardingStep.welcome:
        return true;
      case OnboardingStep.profileSetup:
        return true; // Validated in-screen — name + age required before CTA enables
      case OnboardingStep.permissionsInfo:
        return true;
      case OnboardingStep.permissionsRequest:
        return locationGranted; // Minimum requirement
      case OnboardingStep.motionBaselineCalibration:
        return true; // Optional but recommended
      case OnboardingStep.safeWordSetup:
        return safeWord != null && safeWord!.isNotEmpty;
      case OnboardingStep.safeWordTest:
        return safeWordVerified;
      case OnboardingStep.regionSelection:
        return true; // Optional — user can skip region selection
      case OnboardingStep.trustedContacts:
        return true; // Contacts are optional
      case OnboardingStep.review:
        return true;
    }
  }

  bool get hasMinimumRequirements {
    return locationGranted;
    // Safe word, contacts and region are all optional — user can set them later in My Safety Profile
  }

  OnboardingData copyWith({
    bool? locationGranted,
    bool? microphoneGranted,
    bool? notificationGranted,
    bool? motionBaselineCalibrated,
    String? safeWord,
    bool? safeWordVerified,
    List<Map<String, dynamic>>? trustedContacts,
    OnboardingStep? currentStep,
    bool? isComplete,
  }) {
    return OnboardingData(
      locationGranted: locationGranted ?? this.locationGranted,
      microphoneGranted: microphoneGranted ?? this.microphoneGranted,
      notificationGranted: notificationGranted ?? this.notificationGranted,
      motionBaselineCalibrated: motionBaselineCalibrated ?? this.motionBaselineCalibrated,
      safeWord: safeWord ?? this.safeWord,
      safeWordVerified: safeWordVerified ?? this.safeWordVerified,
      trustedContacts: trustedContacts ?? this.trustedContacts,
      currentStep: currentStep ?? this.currentStep,
      isComplete: isComplete ?? this.isComplete,
    );
  }
}
