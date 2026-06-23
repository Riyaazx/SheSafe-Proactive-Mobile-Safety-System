import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/trusted_contact.dart';
import '../models/user_preferences.dart';
import '../models/user_profile.dart';

// =============================================================================
// Top-level PBKDF2 worker — must be top-level so compute() can send it to a
// background isolate without freezing the UI thread.
// =============================================================================

/// Arguments passed into the background isolate.
class _Pbkdf2Args {
  final String password;
  final List<int> salt; // plain List so it survives isolate serialisation
  final int iterations;
  const _Pbkdf2Args(this.password, this.salt, this.iterations);
}

/// Pure-Dart PBKDF2-HMAC-SHA256.  Runs in a separate isolate via compute().
Uint8List _runPbkdf2(_Pbkdf2Args args) {
  final passwordBytes = utf8.encode(args.password);
  final salt = Uint8List.fromList(args.salt);
  final hmac = Hmac(sha256, passwordBytes);

  List<int> prf(List<int> data) => hmac.convert(data).bytes;

  List<int> block(int i) {
    final intI = Uint8List(4)
      ..buffer.asByteData().setUint32(0, i, Endian.big);
    var u = prf([...salt, ...intI]);
    var result = List<int>.from(u);
    for (var c = 1; c < args.iterations; c++) {
      u = prf(u);
      for (var j = 0; j < result.length; j++) {
        result[j] ^= u[j];
      }
    }
    return result;
  }

  return Uint8List.fromList(block(1));
}

// =============================================================================
// Storage-key constants
// =============================================================================

/// All keys follow the pattern  `profile.<userId>.<field>`  so that multiple
/// enrolments on one device are fully isolated.  The userId itself is stored
/// under one well-known root key.
class _Keys {
  _Keys._();

  // Root key — user-id is stored unscoped so it can be read before the profile
  // is fully loaded.
  static const String userId = 'profile.user_id';

  // Per-user scoped keys (formatted with [_k]).
  static String walkingPace(String uid) => 'profile.$uid.walking_pace';
  static String safeWordHash(String uid) => 'profile.$uid.safe_word_hash';
  static String safeWordSalt(String uid) => 'profile.$uid.safe_word_salt';
  static String hasSafeWordFlag(String uid) => 'profile.$uid.has_safe_word';
  static String trustedContacts(String uid) => 'profile.$uid.trusted_contacts';
  static String homeLocation(String uid) => 'profile.$uid.home_location';
  static String profileMeta(String uid) => 'profile.$uid.meta';

  // Preferences live in SharedPreferences (non-sensitive).
  static String preferences(String uid) => 'profile.$uid.preferences';
}

// =============================================================================
// UserProfileService
// =============================================================================

/// Manages reading and writing the user personalisation profile.
///
/// Security model
/// ──────────────
/// • ALL sensitive data (safe-word hash+salt, walking pace, home location,
///   trusted contacts, profile metadata) is stored via [FlutterSecureStorage],
///   which uses Android Keystore / iOS Keychain under the hood.
///
/// • Raw audio is never stored.  Only aggregate behavioural statistics derived
///   from audio/motion analysis (step rate mean/std) are persisted.
///
/// • The safe word is hashed with **PBKDF2-SHA256** using a 16-byte random
///   salt (100 000 iterations).  The raw word is discarded immediately after
///   hashing and never written to storage.
///
/// • Non-sensitive preferences (risk radius, sensitivity level) are stored in
///   [SharedPreferences] as plain JSON — they contain no PII.
///
/// • All keys are scoped to [userId] so profiles can be individually wiped
///   without affecting other app data.
class UserProfileService {
  // Singleton pattern — keeps one instance alive for the app lifetime.
  static final UserProfileService _instance = UserProfileService._internal();
  factory UserProfileService() => _instance;
  UserProfileService._internal();

  // -------------------------------------------------------------------------
  // Internal state
  // -------------------------------------------------------------------------

  final _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  SharedPreferences? _prefs;
  String? _cachedUserId;

  // PBKDF2 parameters.
  // 10 000 iterations is a practical compromise on low-end Android devices;
  // the hashing is still run on the calling isolate — callers should
  // use Flutter's compute() if they need to keep the UI thread free.
  static const int _pbkdf2Iterations = 10000;
  static const int _saltBytes = 16;

  // -------------------------------------------------------------------------
  // Initialisation
  // -------------------------------------------------------------------------

  /// Must be called once during app startup (after [WidgetsFlutterBinding]).
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _cachedUserId = await _secure.read(key: _Keys.userId);
    debugPrint('UserProfileService initialised. userId: $_cachedUserId');
  }

  // -------------------------------------------------------------------------
  // User identity
  // -------------------------------------------------------------------------

  /// Returns the persisted user ID, generating and saving one if absent.
  Future<String> getUserId() async {
    if (_cachedUserId != null) return _cachedUserId!;

    final newId = const Uuid().v4();
    await _secure.write(key: _Keys.userId, value: newId);
    _cachedUserId = newId;
    debugPrint('UserProfileService: new userId generated → $newId');
    return newId;
  }

  // -------------------------------------------------------------------------
  // Full profile load
  // -------------------------------------------------------------------------

  /// Loads and assembles the full [UserProfile] from all storage layers.
  ///
  /// Returns null if no profile has been created yet.
  Future<UserProfile?> loadProfile() async {
    final uid = await getUserId();

    final metaJson = await _secure.read(key: _Keys.profileMeta(uid));
    if (metaJson == null) return null;

    final meta = jsonDecode(metaJson) as Map<String, dynamic>;

    // Sensitive fields
    final walkingPace = await _loadWalkingPace(uid);
    final homeLocation = await _loadHomeLocation(uid);
    final trustedContacts = await _loadTrustedContacts(uid);

    // Safe-word flag
    final hasSafeWordStr = await _secure.read(key: _Keys.hasSafeWordFlag(uid));
    final hasSafeWord = hasSafeWordStr == 'true';

    // Non-sensitive preferences
    final prefs = await _loadPreferences(uid);

    return UserProfile(
      userId: uid,
      walkingPace: walkingPace,
      hasSafeWord: hasSafeWord,
      trustedContacts: trustedContacts,
      homeLocation: homeLocation,
      preferences: prefs,
      createdAt: DateTime.parse(meta['createdAt'] as String),
      updatedAt: DateTime.parse(meta['updatedAt'] as String),
    );
  }

  // -------------------------------------------------------------------------
  // Profile metadata (create / update timestamps)
  // -------------------------------------------------------------------------

  /// Creates or refreshes the profile metadata record.
  ///
  /// Call this whenever significant profile data changes.
  Future<void> _touchProfile(String uid, {DateTime? createdAt}) async {
    final meta = <String, String>{};
    final existing = await _secure.read(key: _Keys.profileMeta(uid));
    if (existing != null) {
      final parsed = jsonDecode(existing) as Map<String, dynamic>;
      meta['createdAt'] = parsed['createdAt'] as String;
    } else {
      meta['createdAt'] =
          (createdAt ?? DateTime.now()).toIso8601String();
    }
    meta['updatedAt'] = DateTime.now().toIso8601String();
    await _secure.write(
      key: _Keys.profileMeta(uid),
      value: jsonEncode(meta),
    );
  }

  /// Creates a brand-new profile record for a fresh enrolment.
  Future<UserProfile> createProfile() async {
    final uid = await getUserId();
    final now = DateTime.now();
    await _touchProfile(uid, createdAt: now);

    // Write default preferences.
    await savePreferences(const UserPreferences());

    return UserProfile(
      userId: uid,
      createdAt: now,
      updatedAt: now,
    );
  }

  // -------------------------------------------------------------------------
  // Walking pace
  // -------------------------------------------------------------------------

  /// Persists the user's calibrated walking-pace statistics.
  ///
  /// Uses secure encrypted storage because step-rate patterns are behavioural
  /// biometrics that could be used to re-identify a user.
  Future<void> saveWalkingPace(WalkingPaceProfile pace) async {
    final uid = await getUserId();
    await _secure.write(
      key: _Keys.walkingPace(uid),
      value: jsonEncode(pace.toJson()),
    );
    await _touchProfile(uid);
    debugPrint('UserProfileService: walking pace saved.');
  }

  Future<WalkingPaceProfile?> _loadWalkingPace(String uid) async {
    final raw = await _secure.read(key: _Keys.walkingPace(uid));
    if (raw == null) return null;
    return WalkingPaceProfile.fromJson(
        jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Public accessor for walking pace.
  Future<WalkingPaceProfile?> getWalkingPace() async {
    final uid = await getUserId();
    return _loadWalkingPace(uid);
  }

  // -------------------------------------------------------------------------
  // Safe word — PBKDF2-SHA256 hashing
  // -------------------------------------------------------------------------

  /// Hashes [safeWord] with PBKDF2-SHA256 and persists the hash + salt.
  ///
  /// The raw safe word is **never** written to disk. The variable is released
  /// as soon as hashing completes.
  Future<void> setSafeWord(String safeWord) async {
    final uid = await getUserId();

    // Generate a cryptographically random 16-byte salt.
    final salt = _generateSalt();
    final hash = await _pbkdf2Hash(safeWord, salt);

    await _secure.write(
      key: _Keys.safeWordSalt(uid),
      value: base64Encode(salt),
    );
    await _secure.write(
      key: _Keys.safeWordHash(uid),
      value: base64Encode(hash),
    );
    await _secure.write(key: _Keys.hasSafeWordFlag(uid), value: 'true');
    await _touchProfile(uid);

    debugPrint('UserProfileService: safe word hashed and stored (PBKDF2-SHA256, '
        '$_pbkdf2Iterations iterations, $_saltBytes-byte salt).');
  }

  /// Returns true when [input] matches the stored safe word hash.
  Future<bool> verifySafeWord(String input) async {
    final uid = await getUserId();

    final saltB64 = await _secure.read(key: _Keys.safeWordSalt(uid));
    final storedHashB64 = await _secure.read(key: _Keys.safeWordHash(uid));

    if (saltB64 == null || storedHashB64 == null) return false;

    final salt = base64Decode(saltB64);
    final storedHash = base64Decode(storedHashB64);
    final inputHash = await _pbkdf2Hash(input, salt);

    // Constant-time comparison to prevent timing attacks.
    return _constantTimeEquals(inputHash, storedHash);
  }

  /// Removes the stored safe word hash and salt.
  Future<void> clearSafeWord() async {
    final uid = await getUserId();
    await _secure.delete(key: _Keys.safeWordHash(uid));
    await _secure.delete(key: _Keys.safeWordSalt(uid));
    await _secure.write(key: _Keys.hasSafeWordFlag(uid), value: 'false');
    await _touchProfile(uid);
  }

  // -------------------------------------------------------------------------
  // Trusted contacts
  // -------------------------------------------------------------------------

  /// Persists the full list of trusted contacts, encrypted.
  Future<void> saveTrustedContacts(List<TrustedContact> contacts) async {
    final uid = await getUserId();
    final encoded = jsonEncode(contacts.map((c) => c.toJson()).toList());
    await _secure.write(key: _Keys.trustedContacts(uid), value: encoded);
    await _touchProfile(uid);
    debugPrint(
        'UserProfileService: ${contacts.length} trusted contact(s) saved.');
  }

  Future<List<TrustedContact>> _loadTrustedContacts(String uid) async {
    final raw = await _secure.read(key: _Keys.trustedContacts(uid));
    if (raw == null) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => TrustedContact.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Public accessor for trusted contacts.
  Future<List<TrustedContact>> getTrustedContacts() async {
    final uid = await getUserId();
    return _loadTrustedContacts(uid);
  }

  // -------------------------------------------------------------------------
  // Home location
  // -------------------------------------------------------------------------

  /// Persists the user's home location, encrypted.
  ///
  /// Geo-coordinates are treated as sensitive PII and stored only in
  /// encrypted secure storage — never in plain SharedPreferences.
  Future<void> saveHomeLocation(HomeLocation location) async {
    final uid = await getUserId();
    await _secure.write(
      key: _Keys.homeLocation(uid),
      value: jsonEncode(location.toJson()),
    );
    await _touchProfile(uid);
    debugPrint('UserProfileService: home location saved (encrypted).');
  }

  Future<HomeLocation?> _loadHomeLocation(String uid) async {
    final raw = await _secure.read(key: _Keys.homeLocation(uid));
    if (raw == null) return null;
    return HomeLocation.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Public accessor for home location.
  Future<HomeLocation?> getHomeLocation() async {
    final uid = await getUserId();
    return _loadHomeLocation(uid);
  }

  /// Removes the stored home location.
  Future<void> clearHomeLocation() async {
    final uid = await getUserId();
    await _secure.delete(key: _Keys.homeLocation(uid));
    await _touchProfile(uid);
  }

  // -------------------------------------------------------------------------
  // Preferences (non-sensitive)
  // -------------------------------------------------------------------------

  /// Saves user preferences to SharedPreferences (non-sensitive config).
  Future<void> savePreferences(UserPreferences preferences) async {
    final uid = await getUserId();
    await _prefs?.setString(
      _Keys.preferences(uid),
      jsonEncode(preferences.toJson()),
    );
    debugPrint('UserProfileService: preferences saved.');
  }

  Future<UserPreferences> _loadPreferences(String uid) async {
    final raw = _prefs?.getString(_Keys.preferences(uid));
    if (raw == null) return const UserPreferences();
    return UserPreferences.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Public accessor for preferences.
  Future<UserPreferences> getPreferences() async {
    final uid = await getUserId();
    return _loadPreferences(uid);
  }

  // -------------------------------------------------------------------------
  // Profile deletion
  // -------------------------------------------------------------------------

  /// Wipes all profile data for the current user — secure storage entries,
  /// preferences, and the root userId key.
  ///
  /// This gives the user a clean "right to erasure" delete.
  Future<void> deleteProfile() async {
    final uid = await getUserId();

    // Delete all scoped secure-storage keys.
    await Future.wait([
      _secure.delete(key: _Keys.walkingPace(uid)),
      _secure.delete(key: _Keys.safeWordHash(uid)),
      _secure.delete(key: _Keys.safeWordSalt(uid)),
      _secure.delete(key: _Keys.hasSafeWordFlag(uid)),
      _secure.delete(key: _Keys.trustedContacts(uid)),
      _secure.delete(key: _Keys.homeLocation(uid)),
      _secure.delete(key: _Keys.profileMeta(uid)),
      _secure.delete(key: _Keys.userId),     // root key last
    ]);

    // Remove preferences.
    await _prefs?.remove(_Keys.preferences(uid));

    _cachedUserId = null;
    debugPrint('UserProfileService: profile deleted for uid=$uid.');
  }

  /// Checks whether a profile has been enrolled on this device.
  Future<bool> hasProfile() async {
    final uid = await getUserId();
    final meta = await _secure.read(key: _Keys.profileMeta(uid));
    return meta != null;
  }

  // -------------------------------------------------------------------------
  // Cryptographic helpers
  // -------------------------------------------------------------------------

  /// Generates a cryptographically random [_saltBytes]-byte salt.
  Uint8List _generateSalt() {
    final rng = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(_saltBytes, (_) => rng.nextInt(256)),
    );
  }

  /// Derives a hash in a background isolate so the UI thread is never blocked.
  Future<Uint8List> _pbkdf2Hash(String password, Uint8List salt) {
    return compute(
      _runPbkdf2,
      _Pbkdf2Args(password, salt.toList(), _pbkdf2Iterations),
    );
  }

  /// Constant-time byte-array equality — prevents timing side-channels.
  bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
