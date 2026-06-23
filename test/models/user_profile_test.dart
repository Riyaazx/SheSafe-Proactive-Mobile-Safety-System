import 'package:flutter_test/flutter_test.dart';
import 'package:shesafe/models/trusted_contact.dart';
import 'package:shesafe/models/user_preferences.dart';
import 'package:shesafe/models/user_profile.dart';

void main() {
  // ---------------------------------------------------------------------------
  // UserPreferences
  // ---------------------------------------------------------------------------
  group('UserPreferences', () {
    test('default values are sensible', () {
      const prefs = UserPreferences();
      expect(prefs.riskRadiusMeters, 500.0);
      expect(prefs.sensitivity, RiskSensitivity.medium);
      expect(prefs.notificationsEnabled, true);
      expect(prefs.backgroundMonitoringEnabled, true);
      expect(prefs.safeWordConfidenceThreshold, 0.75);
    });

    test('toJson / fromJson round-trip', () {
      const original = UserPreferences(
        riskRadiusMeters: 350.0,
        sensitivity: RiskSensitivity.high,
        notificationsEnabled: false,
        backgroundMonitoringEnabled: true,
        safeWordConfidenceThreshold: 0.85,
      );
      final json = original.toJson();
      final restored = UserPreferences.fromJson(json);

      expect(restored.riskRadiusMeters, 350.0);
      expect(restored.sensitivity, RiskSensitivity.high);
      expect(restored.notificationsEnabled, false);
      expect(restored.backgroundMonitoringEnabled, true);
      expect(restored.safeWordConfidenceThreshold, 0.85);
    });

    test('fromJson gracefully handles missing fields with defaults', () {
      final restored = UserPreferences.fromJson({});
      expect(restored.riskRadiusMeters, 500.0);
      expect(restored.sensitivity, RiskSensitivity.medium);
    });

    test('copyWith changes only specified fields', () {
      const original = UserPreferences(riskRadiusMeters: 200);
      final updated = original.copyWith(sensitivity: RiskSensitivity.low);
      expect(updated.riskRadiusMeters, 200.0);
      expect(updated.sensitivity, RiskSensitivity.low);
    });

    test('unknown sensitivity enum value falls back to medium', () {
      final prefs = UserPreferences.fromJson({'sensitivity': 'extreme'});
      expect(prefs.sensitivity, RiskSensitivity.medium);
    });
  });

  // ---------------------------------------------------------------------------
  // WalkingPaceProfile
  // ---------------------------------------------------------------------------
  group('WalkingPaceProfile', () {
    WalkingPaceProfile makeProfile({
      double mean = 1.8,
      double std = 0.2,
      double typical = 1.4,
      double min = 1.0,
      double max = 1.8,
    }) =>
        WalkingPaceProfile(
          meanStepsPerSecond: mean,
          stdStepsPerSecond: std,
          typicalSpeedMs: typical,
          minSpeedMs: min,
          maxSpeedMs: max,
          calibratedAt: DateTime(2026, 1, 1),
        );

    test('typicalSpeedKmh converts correctly', () {
      // 1.4 m/s × 3.6 = 5.04 km/h
      expect(makeProfile().typicalSpeedKmh, closeTo(5.04, 0.01));
    });

    test('isWithinNormalRange returns true for in-range speed', () {
      // min=1.0, max=1.8, tolerance=20% → effective range [0.8, 2.16]
      expect(makeProfile().isWithinNormalRange(1.4), isTrue);
      expect(makeProfile().isWithinNormalRange(0.85), isTrue);
      expect(makeProfile().isWithinNormalRange(2.1), isTrue);
    });

    test('isWithinNormalRange returns false for out-of-range speed', () {
      expect(makeProfile().isWithinNormalRange(0.5), isFalse);
      expect(makeProfile().isWithinNormalRange(3.0), isFalse);
    });

    test('toJson / fromJson round-trip', () {
      final original = makeProfile();
      final restored = WalkingPaceProfile.fromJson(original.toJson());
      expect(restored.meanStepsPerSecond, original.meanStepsPerSecond);
      expect(restored.typicalSpeedMs, original.typicalSpeedMs);
      expect(restored.calibratedAt, original.calibratedAt);
    });
  });

  // ---------------------------------------------------------------------------
  // HomeLocation
  // ---------------------------------------------------------------------------
  group('HomeLocation', () {
    final home = HomeLocation(
      latitude: 52.4092,
      longitude: -1.5055,
      label: 'Home',
      savedAt: DateTime(2026, 2, 1),
    );

    test('toJson / fromJson round-trip', () {
      final restored = HomeLocation.fromJson(home.toJson());
      expect(restored.latitude, home.latitude);
      expect(restored.longitude, home.longitude);
      expect(restored.label, 'Home');
    });

    test('copyWith preserves unchanged fields', () {
      final updated = home.copyWith(label: 'Work');
      expect(updated.label, 'Work');
      expect(updated.latitude, home.latitude);
    });
  });

  // ---------------------------------------------------------------------------
  // UserProfile  (in-memory, no storage)
  // ---------------------------------------------------------------------------
  group('UserProfile', () {
    final now = DateTime(2026, 2, 21);

    UserProfile emptyProfile() => UserProfile(
          userId: 'test-uid',
          createdAt: now,
          updatedAt: now,
        );

    test('isFullyConfigured is false when nothing set', () {
      expect(emptyProfile().isFullyConfigured, isFalse);
    });

    test('isFullyConfigured is true when all three conditions met', () {
      final profile = emptyProfile().copyWith(
        hasSafeWord: true,
        trustedContacts: [
          TrustedContact(id: '1', name: 'Mum', phone: '07700000000'),
        ],
        walkingPace: WalkingPaceProfile(
          meanStepsPerSecond: 1.8,
          stdStepsPerSecond: 0.2,
          typicalSpeedMs: 1.4,
          minSpeedMs: 1.0,
          maxSpeedMs: 1.8,
          calibratedAt: now,
        ),
      );
      expect(profile.isFullyConfigured, isTrue);
    });

    test('primaryContact returns the isPrimary contact', () {
      final profile = emptyProfile().copyWith(
        trustedContacts: [
          TrustedContact(id: '1', name: 'Friend', phone: '07700000001'),
          TrustedContact(id: '2', name: 'Mum', phone: '07700000002', isPrimary: true),
        ],
      );
      expect(profile.primaryContact?.name, 'Mum');
    });

    test('primaryContact falls back to first when none flagged', () {
      final profile = emptyProfile().copyWith(
        trustedContacts: [
          TrustedContact(id: '1', name: 'First', phone: '07700000001'),
          TrustedContact(id: '2', name: 'Second', phone: '07700000002'),
        ],
      );
      expect(profile.primaryContact?.name, 'First');
    });

    test('primaryContact is null when list is empty', () {
      expect(emptyProfile().primaryContact, isNull);
    });

    test('copyWith bumps updatedAt', () {
      final original = emptyProfile();
      final updated = original.copyWith(hasSafeWord: true);
      expect(updated.hasSafeWord, isTrue);
      expect(updated.userId, original.userId);
      expect(updated.createdAt, original.createdAt);
    });

    test('toJson / fromJson round-trip for non-sensitive fields', () {
      final profile = emptyProfile().copyWith(hasSafeWord: true);
      final restored = UserProfile.fromJson(profile.toJson());
      expect(restored.userId, profile.userId);
      expect(restored.hasSafeWord, true);
    });
  });
}
