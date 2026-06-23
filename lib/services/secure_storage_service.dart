import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

class SecureStorageService {
  static final SecureStorageService _instance = SecureStorageService._internal();
  factory SecureStorageService() => _instance;
  SecureStorageService._internal();

  final _secureStorage = const FlutterSecureStorage();
  SharedPreferences? _prefs;

  Future<SharedPreferences> _ensurePrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  // Initialize shared preferences
  Future<void> init() async {
    await _ensurePrefs();
  }

  // Secure storage keys
  static const String _safeWordKey = 'safe_word';
  static const String _safeWordVerifiedKey = 'safe_word_verified';
  static const String _paceMeanKey = 'pace_mean';
  static const String _paceStdKey = 'pace_std';
  static const String _calibrationTimestampKey = 'calibration_timestamp';
  static const String _trustedContactsKey = 'trusted_contacts_json';

  // Shared preferences keys
  static const String _onboardingCompletedKey = 'onboarding_completed';
  static const String _hasSeenPermissionExplainerKey = 'has_seen_permission_explainer';
  static const String _permissionsStatusKey = 'permissions_status_json';
  static const String _userDisplayNameKey = 'user_display_name';
  static const String _userAgeKey = 'user_age';

  // ========== Secure Storage Methods ==========

  // Safe word
  Future<void> saveSafeWord(String safeWord) async {
    await _secureStorage.write(key: _safeWordKey, value: safeWord);
  }

  Future<String?> getSafeWord() async {
    return await _secureStorage.read(key: _safeWordKey);
  }

  Future<void> setSafeWordVerified(bool verified) async {
    await _secureStorage.write(key: _safeWordVerifiedKey, value: verified.toString());
  }

  Future<bool> isSafeWordVerified() async {
    final value = await _secureStorage.read(key: _safeWordVerifiedKey);
    return value == 'true';
  }

  // Walking pace calibration
  Future<void> savePaceCalibration({
    required double paceMean,
    required double paceStd,
  }) async {
    await _secureStorage.write(key: _paceMeanKey, value: paceMean.toString());
    await _secureStorage.write(key: _paceStdKey, value: paceStd.toString());
    await _secureStorage.write(
      key: _calibrationTimestampKey,
      value: DateTime.now().toIso8601String(),
    );
  }

  Future<Map<String, dynamic>?> getPaceCalibration() async {
    final paceMean = await _secureStorage.read(key: _paceMeanKey);
    final paceStd = await _secureStorage.read(key: _paceStdKey);
    final timestamp = await _secureStorage.read(key: _calibrationTimestampKey);

    if (paceMean == null || paceStd == null) return null;

    return {
      'paceMean': double.parse(paceMean),
      'paceStd': double.parse(paceStd),
      'timestamp': timestamp != null ? DateTime.parse(timestamp) : null,
    };
  }

  // Trusted contacts
  Future<void> saveTrustedContacts(List<Map<String, dynamic>> contacts) async {
    await _secureStorage.write(
      key: _trustedContactsKey,
      value: jsonEncode(contacts),
    );
  }

  Future<List<Map<String, dynamic>>> getTrustedContacts() async {
    final contactsJson = await _secureStorage.read(key: _trustedContactsKey);
    if (contactsJson == null) return [];
    
    final List<dynamic> decoded = jsonDecode(contactsJson);
    return decoded.cast<Map<String, dynamic>>();
  }

  // ========== Shared Preferences Methods ==========

  // Onboarding status
  Future<void> setOnboardingCompleted(bool completed) async {
    final prefs = await _ensurePrefs();
    await prefs.setBool(_onboardingCompletedKey, completed);
  }

  bool isOnboardingCompleted() {
    return _prefs?.getBool(_onboardingCompletedKey) ?? false;
  }

  // Permission explainer
  Future<void> setHasSeenPermissionExplainer(bool seen) async {
    final prefs = await _ensurePrefs();
    await prefs.setBool(_hasSeenPermissionExplainerKey, seen);
  }

  bool hasSeenPermissionExplainer() {
    return _prefs?.getBool(_hasSeenPermissionExplainerKey) ?? false;
  }

  // Permissions status
  Future<void> savePermissionsStatus(Map<String, dynamic> status) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_permissionsStatusKey, jsonEncode(status));
  }

  Map<String, dynamic>? getPermissionsStatus() {
    final statusJson = _prefs?.getString(_permissionsStatusKey);
    if (statusJson == null) return null;
    return jsonDecode(statusJson);
  }

  // User display name (used in arrival SMS and notifications)
  Future<void> saveUserName(String name) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_userDisplayNameKey, name);
  }

  String getUserName() {
    return _prefs?.getString(_userDisplayNameKey) ?? '';
  }

  Future<String> getUserNameAsync() async {
    final prefs = await _ensurePrefs();
    return prefs.getString(_userDisplayNameKey) ?? '';
  }

  // User age
  Future<void> saveUserAge(int age) async {
    final prefs = await _ensurePrefs();
    await prefs.setInt(_userAgeKey, age);
  }

  int? getUserAge() {
    return _prefs?.getInt(_userAgeKey);
  }

  Future<int?> getUserAgeAsync() async {
    final prefs = await _ensurePrefs();
    return prefs.getInt(_userAgeKey);
  }

  // Clear all data
  Future<void> clearAll() async {
    await _secureStorage.deleteAll();
    final prefs = await _ensurePrefs();
    await prefs.clear();
  }

  // Clear only onboarding data (for testing)
  Future<void> clearOnboardingData() async {
    await _secureStorage.delete(key: _safeWordKey);
    await _secureStorage.delete(key: _safeWordVerifiedKey);
    await _secureStorage.delete(key: _paceMeanKey);
    await _secureStorage.delete(key: _paceStdKey);
    await _secureStorage.delete(key: _calibrationTimestampKey);
    await _secureStorage.delete(key: _trustedContactsKey);
    final prefs = await _ensurePrefs();
    await prefs.remove(_onboardingCompletedKey);
    await prefs.remove(_hasSeenPermissionExplainerKey);
    await prefs.remove(_permissionsStatusKey);
  }
}
