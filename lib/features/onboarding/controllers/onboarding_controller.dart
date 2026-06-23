import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'dart:async';
import '../../../models/onboarding_data.dart';
import '../../../models/trusted_contact.dart';
import '../../../services/secure_storage_service.dart';
import '../../../services/permission_service.dart';

class OnboardingController extends ChangeNotifier {
  final SecureStorageService _storageService;
  final PermissionService _permissionService;

  OnboardingData _data = OnboardingData();
  bool _isLoading = false;
  String? _error;

  // For speech recognition
  final SpeechToText _speechToText = SpeechToText();
  bool _speechAvailable = false;

  OnboardingController({
    SecureStorageService? storageService,
    PermissionService? permissionService,
  })  : _storageService = storageService ?? SecureStorageService(),
        _permissionService = permissionService ?? PermissionService();

  OnboardingData get data => _data;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get speechAvailable => _speechAvailable;

  // Initialize
  Future<void> initialize() async {
    _isLoading = true;
    notifyListeners();

    try {
      await _storageService.init();
      await _permissionService.initNotifications();
      
      // Initialize speech recognition
      _speechAvailable = await _speechToText.initialize();
    } catch (e) {
      _error = 'Failed to initialize: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Navigate to next step
  void nextStep() {
    final steps = OnboardingStep.values;
    final currentIndex = steps.indexOf(_data.currentStep);
    if (currentIndex < steps.length - 1) {
      _data = _data.copyWith(currentStep: steps[currentIndex + 1]);
      notifyListeners();
    }
  }

  // Navigate to previous step
  void previousStep() {
    final steps = OnboardingStep.values;
    final currentIndex = steps.indexOf(_data.currentStep);
    if (currentIndex > 0) {
      _data = _data.copyWith(currentStep: steps[currentIndex - 1]);
      notifyListeners();
    }
  }

  // Skip to specific step
  void goToStep(OnboardingStep step) {
    _data = _data.copyWith(currentStep: step);
    notifyListeners();
  }

  // ========== Permission Methods ==========

  Future<void> requestLocationPermission() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final status = await _permissionService.requestLocationPermission();
      _data = _data.copyWith(locationGranted: status.isGranted);
      
      // Save permission status
      await _storageService.savePermissionsStatus({
        'location': status.isGranted,
        'microphone': _data.microphoneGranted,
        'notification': _data.notificationGranted,
      });
    } catch (e) {
      _error = 'Failed to request location permission: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> requestMicrophonePermission() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final status = await _permissionService.requestMicrophonePermission();
      _data = _data.copyWith(microphoneGranted: status.isGranted);
      
      await _storageService.savePermissionsStatus({
        'location': _data.locationGranted,
        'microphone': status.isGranted,
        'notification': _data.notificationGranted,
      });
    } catch (e) {
      _error = 'Failed to request microphone permission: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> requestNotificationPermission() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final status = await _permissionService.requestNotificationPermission();
      _data = _data.copyWith(notificationGranted: status.isGranted);
      
      await _storageService.savePermissionsStatus({
        'location': _data.locationGranted,
        'microphone': _data.microphoneGranted,
        'notification': status.isGranted,
      });
    } catch (e) {
      _error = 'Failed to request notification permission: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> requestAllPermissions() async {
    await requestLocationPermission();
    await requestNotificationPermission();
  }

  Future<void> openSettings() async {
    await openAppSettings();
  }

  // ========== Safe Word Methods ==========

  Future<void> setSafeWord(String word) async {
    _error = null;
    
    // Validate safe word
    if (word.trim().isEmpty) {
      _error = 'Safe word cannot be empty';
      notifyListeners();
      return;
    }

    final wordCount = word.trim().split(' ').length;
    if (wordCount > 3) {
      _error = 'Safe word must be 1-3 words maximum';
      notifyListeners();
      return;
    }

    // Check for very common words
    final commonWords = ['hello', 'ok', 'yes', 'no', 'the', 'a', 'an'];
    if (commonWords.contains(word.trim().toLowerCase())) {
      _error = 'Please choose a less common word';
      notifyListeners();
      return;
    }

    try {
      await _storageService.saveSafeWord(word.trim().toLowerCase());
      _data = _data.copyWith(safeWord: word.trim().toLowerCase());
      notifyListeners();
    } catch (e) {
      _error = 'Failed to save safe word: $e';
      notifyListeners();
    }
  }

  Future<bool> testSafeWord() async {
    if (_data.safeWord == null) {
      _error = 'Please set a safe word first';
      notifyListeners();
      return false;
    }

    if (!_speechAvailable) {
      _error = 'Speech recognition not available';
      notifyListeners();
      return false;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // Start listening
      bool recognized = false;
      
      await _speechToText.listen(
        onResult: (result) {
          if (result.recognizedWords
              .toLowerCase()
              .contains(_data.safeWord!.toLowerCase())) {
            recognized = true;
          }
        },
      );

      // Listen for 5 seconds
      await Future.delayed(const Duration(seconds: 5));
      await _speechToText.stop();

      if (recognized) {
        await _storageService.setSafeWordVerified(true);
        _data = _data.copyWith(safeWordVerified: true);
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _error = 'Safe word not recognized. Please try again.';
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _error = 'Speech recognition failed: $e';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  // ========== Trusted Contacts Methods ==========

  void addContact(TrustedContact contact) {
    final contacts = List<Map<String, dynamic>>.from(_data.trustedContacts);
    contacts.add(contact.toJson());
    _data = _data.copyWith(trustedContacts: contacts);
    _saveContacts();
    notifyListeners();
  }

  void removeContact(String contactId) {
    final contacts = _data.trustedContacts
        .where((c) => c['id'] != contactId)
        .toList();
    _data = _data.copyWith(trustedContacts: contacts);
    _saveContacts();
    notifyListeners();
  }

  void updateContact(TrustedContact contact) {
    final contacts = _data.trustedContacts.map((c) {
      if (c['id'] == contact.id) {
        return contact.toJson();
      }
      return c;
    }).toList();
    _data = _data.copyWith(trustedContacts: contacts);
    _saveContacts();
    notifyListeners();
  }

  Future<void> _saveContacts() async {
    try {
      await _storageService.saveTrustedContacts(_data.trustedContacts);
    } catch (e) {
      _error = 'Failed to save contacts: $e';
    }
  }

  // ========== Complete Onboarding ==========

  Future<bool> completeOnboarding() async {
    if (!_data.hasMinimumRequirements) {
      _error = 'Please complete all required steps';
      notifyListeners();
      return false;
    }

    _isLoading = true;
    notifyListeners();

    try {
      await _storageService.setOnboardingCompleted(true);
      _data = _data.copyWith(isComplete: true);
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Failed to complete onboarding: $e';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  // Mark motion calibration as complete
  void markCalibrationComplete() {
    _data = _data.copyWith(motionBaselineCalibrated: true);
    notifyListeners();
  }

  // Clear error
  void clearError() {
    _error = null;
    notifyListeners();
  }

  // Reset onboarding (for testing)
  Future<void> resetOnboarding() async {
    await _storageService.clearOnboardingData();
    _data = OnboardingData();
    notifyListeners();
  }
}
