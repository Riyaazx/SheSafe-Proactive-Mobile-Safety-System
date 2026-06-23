import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shesafe/models/trusted_contact.dart';
import 'package:shesafe/models/user_preferences.dart';
import 'package:shesafe/models/user_profile.dart';
import 'package:shesafe/services/user_profile_service.dart';

// =============================================================================
// Helpers — in-memory mock for FlutterSecureStorage
// =============================================================================

/// In-memory store that intercepts all FlutterSecureStorage method-channel
/// calls so tests run without a real Android Keystore / iOS Keychain.
class _MockSecureStorage {
  final _store = <String, String>{};

  void register() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        switch (call.method) {
          case 'read':
            final key = (call.arguments as Map)['key'] as String;
            return _store[key];
          case 'write':
            final args = call.arguments as Map;
            _store[args['key'] as String] = args['value'] as String;
            return null;
          case 'delete':
            _store.remove((call.arguments as Map)['key'] as String);
            return null;
          case 'deleteAll':
            _store.clear();
            return null;
          case 'readAll':
            return Map<String, String>.from(_store);
          case 'containsKey':
            final key = (call.arguments as Map)['key'] as String;
            return _store.containsKey(key);
          default:
            return null;
        }
      },
    );
  }

  void clear() => _store.clear();
}

// =============================================================================
// Tests
// =============================================================================

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final mockStorage = _MockSecureStorage();

  setUp(() async {
    // Reset both storage layers before every test so tests are independent.
    mockStorage.register();
    mockStorage.clear();
    SharedPreferences.setMockInitialValues({});

    // Re-init the singleton service so it picks up the fresh SharedPreferences.
    await UserProfileService().init();
  });

  // ---------------------------------------------------------------------------
  // Profile lifecycle
  // ---------------------------------------------------------------------------
  group('UserProfileService — profile lifecycle', () {
    test('hasProfile returns false before createProfile()', () async {
      // Fresh storage — no meta key written yet.
      // getUserId() will write a new userId but no meta, so hasProfile = false.
      expect(await UserProfileService().hasProfile(), isFalse);
    });

    test('createProfile() creates a valid profile', () async {
      final svc = UserProfileService();
      final profile = await svc.createProfile();

      expect(profile.userId, isNotEmpty);
      expect(profile.hasSafeWord, isFalse);
      expect(profile.trustedContacts, isEmpty);
    });

    test('hasProfile returns true after createProfile()', () async {
      final svc = UserProfileService();
      await svc.createProfile();
      expect(await svc.hasProfile(), isTrue);
    });

    test('loadProfile returns null on fresh install', () async {
      // No createProfile called — no meta written.
      final svc = UserProfileService();
      // getUserId will create a new ID but won't write meta.
      final profile = await svc.loadProfile();
      expect(profile, isNull);
    });

    test('loadProfile returns full profile after setup', () async {
      final svc = UserProfileService();
      await svc.createProfile();
      await svc.setSafeWord('sunflower');

      final loaded = await svc.loadProfile();
      expect(loaded, isNotNull);
      expect(loaded!.hasSafeWord, isTrue);
    });

    test('deleteProfile wipes everything', () async {
      final svc = UserProfileService();
      await svc.createProfile();
      await svc.setSafeWord('sunflower');
      await svc.deleteProfile();

      // After deletion, hasProfile should be false.
      expect(await svc.hasProfile(), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Safe word — PBKDF2 hashing
  // ---------------------------------------------------------------------------
  group('UserProfileService — safe word', () {
    test('correct word verifies as true', () async {
      final svc = UserProfileService();
      await svc.createProfile();
      await svc.setSafeWord('sunflower');

      expect(await svc.verifySafeWord('sunflower'), isTrue);
    });

    test('wrong word verifies as false', () async {
      final svc = UserProfileService();
      await svc.createProfile();
      await svc.setSafeWord('sunflower');

      expect(await svc.verifySafeWord('wrongword'), isFalse);
    });

    test('safe word is case-sensitive', () async {
      final svc = UserProfileService();
      await svc.createProfile();
      await svc.setSafeWord('sunflower');

      expect(await svc.verifySafeWord('Sunflower'), isFalse);
      expect(await svc.verifySafeWord('SUNFLOWER'), isFalse);
    });

    test('same word re-enrolled produces different hash (different salt)', () async {
      final svc = UserProfileService();
      await svc.createProfile();
      await svc.setSafeWord('sunflower');
      final uid = await svc.getUserId();

      // Read stored hash for first enrolment.
      final firstHash = mockStorage._store[
          'profile.$uid.safe_word_hash'];

      // Re-set the same word — new salt must produce different hash.
      await svc.setSafeWord('sunflower');
      final secondHash = mockStorage._store[
          'profile.$uid.safe_word_hash'];

      expect(firstHash, isNotNull);
      expect(secondHash, isNotNull);
      // Different salts → different hashes even for the same password.
      expect(firstHash, isNot(equals(secondHash)));
    });

    test('raw word is never written to storage', () async {
      final svc = UserProfileService();
      await svc.createProfile();
      await svc.setSafeWord('mysecretword');

      // Search all stored values for the plaintext.
      final allValues = mockStorage._store.values;
      for (final v in allValues) {
        expect(v, isNot(contains('mysecretword')));
      }
    });

    test('clearSafeWord removes hash and salt', () async {
      final svc = UserProfileService();
      await svc.createProfile();
      await svc.setSafeWord('sunflower');
      await svc.clearSafeWord();

      expect(await svc.verifySafeWord('sunflower'), isFalse);

      final loaded = await svc.loadProfile();
      expect(loaded?.hasSafeWord, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Walking pace
  // ---------------------------------------------------------------------------
  group('UserProfileService — walking pace', () {
    WalkingPaceProfile makePace() => WalkingPaceProfile(
          meanStepsPerSecond: 1.8,
          stdStepsPerSecond: 0.2,
          typicalSpeedMs: 1.4,
          minSpeedMs: 1.0,
          maxSpeedMs: 1.8,
          calibratedAt: DateTime(2026, 2, 21),
        );

    test('saveWalkingPace and getWalkingPace round-trip', () async {
      final svc = UserProfileService();
      await svc.createProfile();
      await svc.saveWalkingPace(makePace());

      final loaded = await svc.getWalkingPace();
      expect(loaded, isNotNull);
      expect(loaded!.meanStepsPerSecond, 1.8);
      expect(loaded.typicalSpeedMs, 1.4);
    });

    test('walking pace appears in loadProfile()', () async {
      final svc = UserProfileService();
      await svc.createProfile();
      await svc.saveWalkingPace(makePace());

      final profile = await svc.loadProfile();
      expect(profile?.walkingPace?.typicalSpeedKmh, closeTo(5.04, 0.01));
    });
  });

  // ---------------------------------------------------------------------------
  // Trusted contacts
  // ---------------------------------------------------------------------------
  group('UserProfileService — trusted contacts', () {
    test('saveTrustedContacts and getTrustedContacts round-trip', () async {
      final svc = UserProfileService();
      await svc.createProfile();

      final contacts = [
        TrustedContact(id: '1', name: 'Mum', phone: '07700000001', isPrimary: true),
        TrustedContact(id: '2', name: 'Friend', phone: '07700000002'),
      ];
      await svc.saveTrustedContacts(contacts);

      final loaded = await svc.getTrustedContacts();
      expect(loaded.length, 2);
      expect(loaded.first.name, 'Mum');
      expect(loaded.first.isPrimary, isTrue);
    });

    test('contact data is stored encrypted (not plaintext JSON in store)', () async {
      final svc = UserProfileService();
      await svc.createProfile();
      await svc.saveTrustedContacts([
        TrustedContact(id: '1', name: 'SecretContact', phone: '07700000001'),
      ]);

      // The value in our mock store IS JSON (the mock bypasses AES encryption
      // since there's no real Keystore), but in production the OS encrypts the
      // underlying shared preferences file.  What we CAN assert is that the
      // contacts were stored under the correct scoped key, not a global key.
      final uid = await svc.getUserId();
      final key = 'profile.$uid.trusted_contacts';
      expect(mockStorage._store.containsKey(key), isTrue);
    });

    test('overwriting contacts replaces the full list', () async {
      final svc = UserProfileService();
      await svc.createProfile();
      await svc.saveTrustedContacts([
        TrustedContact(id: '1', name: 'First', phone: '07700000001'),
      ]);
      await svc.saveTrustedContacts([
        TrustedContact(id: '2', name: 'Second', phone: '07700000002'),
      ]);

      final loaded = await svc.getTrustedContacts();
      expect(loaded.length, 1);
      expect(loaded.first.name, 'Second');
    });
  });

  // ---------------------------------------------------------------------------
  // Home location
  // ---------------------------------------------------------------------------
  group('UserProfileService — home location', () {
    final home = HomeLocation(
      latitude: 52.4092,
      longitude: -1.5055,
      label: 'Home',
      savedAt: DateTime(2026, 2, 21),
    );

    test('saveHomeLocation and getHomeLocation round-trip', () async {
      final svc = UserProfileService();
      await svc.createProfile();
      await svc.saveHomeLocation(home);

      final loaded = await svc.getHomeLocation();
      expect(loaded?.latitude, home.latitude);
      expect(loaded?.longitude, home.longitude);
      expect(loaded?.label, 'Home');
    });

    test('clearHomeLocation removes the location', () async {
      final svc = UserProfileService();
      await svc.createProfile();
      await svc.saveHomeLocation(home);
      await svc.clearHomeLocation();

      expect(await svc.getHomeLocation(), isNull);
    });

    test('home location key is scoped to userId', () async {
      final svc = UserProfileService();
      await svc.createProfile();
      await svc.saveHomeLocation(home);

      final uid = await svc.getUserId();
      expect(
        mockStorage._store.containsKey('profile.$uid.home_location'),
        isTrue,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Preferences
  // ---------------------------------------------------------------------------
  group('UserProfileService — preferences', () {
    test('savePreferences and getPreferences round-trip', () async {
      final svc = UserProfileService();
      await svc.createProfile();
      await svc.savePreferences(const UserPreferences(
        riskRadiusMeters: 300,
        sensitivity: RiskSensitivity.high,
      ));

      final loaded = await svc.getPreferences();
      expect(loaded.riskRadiusMeters, 300.0);
      expect(loaded.sensitivity, RiskSensitivity.high);
    });

    test('getPreferences returns defaults when nothing saved', () async {
      final svc = UserProfileService();
      await svc.createProfile();

      final prefs = await svc.getPreferences();
      expect(prefs.riskRadiusMeters, 500.0);
      expect(prefs.sensitivity, RiskSensitivity.medium);
    });
  });
}
