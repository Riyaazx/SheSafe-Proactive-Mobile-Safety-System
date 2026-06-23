import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shesafe/services/arrival_notification_service.dart';
import 'package:shesafe/models/event_log.dart';

// =============================================================================
// Feature: Place Alerts — "Notify my Trusted Contact when I arrive safely"
// =============================================================================
//
// Tests cover:
//   1. SMS body construction (content, personalisation, fallback)
//   2. Arrival radius configuration (GPS proximity threshold)
//   3. EventType enum includes arrivalNotificationSent
//   4. EventLog display helpers handle the new event type
//   5. Edge cases (empty name, long destination, special characters)
// =============================================================================

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = ArrivalNotificationService();

  // =========================================================================
  // GROUP 1 — SMS body construction
  // =========================================================================
  group('Arrival SMS body construction', () {
    test('Body contains destination address', () {
      final body = service.buildArrivalSmsBody(
        destination: '23 Priory Street, Coventry',
      );
      expect(body, contains('23 Priory Street, Coventry'));
    });

    test('Body contains "safely arrived" wording', () {
      final body = service.buildArrivalSmsBody(
        destination: 'Home',
      );
      expect(body, contains('safely arrived'));
    });

    test('Body mentions SheSafe app for trust / context', () {
      final body = service.buildArrivalSmsBody(
        destination: 'University',
      );
      expect(body, contains('SheSafe'));
    });

    test('Body uses user name when provided', () {
      final body = service.buildArrivalSmsBody(
        destination: 'Home',
        userName: 'Riya',
      );
      expect(body, contains('Riya'));
      expect(body, isNot(contains(' I have')),
          reason: 'When a name is given, the first-person fallback must not appear');
    });

    test('Body falls back to first-person when userName is null', () {
      final body = service.buildArrivalSmsBody(
        destination: 'Home',
        userName: null,
      );
      expect(body, contains('I have safely arrived'));
    });

    test('Body falls back to first-person when userName is blank', () {
      final body = service.buildArrivalSmsBody(
        destination: 'Home',
        userName: '   ',
      );
      expect(body, contains('I have safely arrived'));
    });

    test('Body includes the safe-arrival emoji ✅', () {
      final body = service.buildArrivalSmsBody(
        destination: 'Home',
      );
      expect(body, contains('✅'));
    });

    test('Body includes the destination pin emoji 📍', () {
      final body = service.buildArrivalSmsBody(
        destination: 'Home',
      );
      expect(body, contains('📍'));
    });

    test('Body handles long destination string without truncation', () {
      const longDest =
          '123 Really Long Street Name, Apartment Building 4B, '
          'Coventry, West Midlands, CV1 5AB, United Kingdom';
      final body = service.buildArrivalSmsBody(
        destination: longDest,
      );
      expect(body, contains(longDest),
          reason: 'Full destination must appear — no truncation');
    });

    test('Body handles special characters in destination', () {
      const special = "O'Hare & Partners, Café Résumé";
      final body = service.buildArrivalSmsBody(
        destination: special,
      );
      expect(body, contains(special));
    });
  });

  // =========================================================================
  // GROUP 2 — Arrival radius constant
  // =========================================================================
  group('Arrival radius configuration', () {
    test('Arrival radius is 50 metres (sensible GPS drift tolerance)', () {
      expect(
        ArrivalNotificationService.arrivalRadiusMetres,
        equals(50.0),
        reason:
            '50 m balances early notification against GPS drift on consumer phones',
      );
    });

    test('Arrival radius is > 0 (never zero — would never trigger)', () {
      expect(ArrivalNotificationService.arrivalRadiusMetres, greaterThan(0));
    });

    test('Arrival radius is ≤ 200 m (not absurdly large)', () {
      expect(
        ArrivalNotificationService.arrivalRadiusMetres,
        lessThanOrEqualTo(200.0),
        reason:
            'Radius > 200 m would trigger arrival notification several streets away',
      );
    });
  });

  // =========================================================================
  // GROUP 3 — EventType enum contract
  // =========================================================================
  group('EventType contains arrivalNotificationSent', () {
    test('arrivalNotificationSent is a valid EventType value', () {
      expect(
        EventType.values,
        contains(EventType.arrivalNotificationSent),
      );
    });

    test('EventType enum has not lost any previous values after addition', () {
      // All original + new value must be present
      final expected = [
        EventType.safeRouteGenerated,
        EventType.riskZoneDetected,
        EventType.panicModeActivated,
        EventType.panicModeDeactivated,
        EventType.safeWordVerified,
        EventType.safeWordFailed,
        EventType.trustedContactAlerted,
        EventType.safetyModeActivated,
        EventType.calibrationCompleted,
        EventType.locationPermissionGranted,
        EventType.locationPermissionDenied,
        EventType.appLaunched,
        EventType.motionBaselineCalibrated,
        EventType.motionAnomalyDetected,
        EventType.motionConcernTriggered,
        EventType.escalationStageChanged,
        EventType.checkInPromptShown,
        EventType.checkInResponseReceived,
        EventType.countdownStarted,
        EventType.countdownCancelled,
        EventType.emergencyAlertDispatched,
        EventType.arrivalNotificationSent, // new
      ];
      for (final e in expected) {
        expect(EventType.values, contains(e),
            reason: '${e.name} must still be in enum');
      }
    });
  });

  // =========================================================================
  // GROUP 4 — EventLog display helpers for the new event type
  // =========================================================================
  group('EventLog display helpers for arrivalNotificationSent', () {
    final log = EventLog(
      id: 'test-arrival-001',
      timestamp: DateTime(2026, 2, 27),
      type: EventType.arrivalNotificationSent,
      outcome: EventOutcome.success,
      description: 'Sent arrival notification',
    );

    test('typeName returns a human-readable label', () {
      expect(log.typeName, isNotEmpty);
      expect(log.typeName, equals('Arrival Notification Sent'));
    });

    test('icon returns a non-null IconData', () {
      // Just verify it doesn't throw and returns a valid icon
      expect(log.icon, isNotNull);
    });

    test('outcomeColor for success is green', () {
      expect(log.outcomeColor.toARGB32(), equals(Colors.green.toARGB32()));
    });

    test('outcomeLabel for success is "Success"', () {
      expect(log.outcomeLabel, equals('Success'));
    });

    test('Warning outcome for skipped notification', () {
      final warningLog = EventLog(
        id: 'test-arrival-002',
        timestamp: DateTime(2026, 2, 27),
        type: EventType.arrivalNotificationSent,
        outcome: EventOutcome.warning,
        description: 'No contacts configured',
      );
      expect(warningLog.outcomeColor.toARGB32(), equals(Colors.orange.toARGB32()));
      expect(warningLog.outcomeLabel, equals('Warning'));
    });

    test('Failure outcome for failed SMS launch', () {
      final failLog = EventLog(
        id: 'test-arrival-003',
        timestamp: DateTime(2026, 2, 27),
        type: EventType.arrivalNotificationSent,
        outcome: EventOutcome.failure,
        description: 'Could not launch SMS intent',
      );
      expect(failLog.outcomeColor.toARGB32(), equals(Colors.red.toARGB32()));
      expect(failLog.outcomeLabel, equals('Failed'));
    });
  });

  // =========================================================================
  // GROUP 5 — Singleton contract
  // =========================================================================
  group('ArrivalNotificationService singleton', () {
    test('Factory constructor returns the same instance', () {
      final a = ArrivalNotificationService();
      final b = ArrivalNotificationService();
      expect(identical(a, b), isTrue,
          reason: 'Service must be a singleton — no duplicate state');
    });
  });
}
