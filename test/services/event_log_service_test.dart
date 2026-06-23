// test/services/event_log_service_test.dart
//
// Unit tests for [EventLogService].  Every test runs against an in-memory
// SharedPreferences instance (no real platform channel needed).

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shesafe/services/event_log_service.dart';
import 'package:shesafe/models/event_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Re-initialise the service with a fresh empty store before each test so
  // tests are fully isolated even though EventLogService is a singleton.
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await EventLogService().init();
    await EventLogService().clearAllEvents();
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Basic logging
  // ─────────────────────────────────────────────────────────────────────────

  group('logEvent() and getAllEvents()', () {
    test('stored event is retrievable', () async {
      await EventLogService().logEvent(
        type: EventType.appLaunched,
        outcome: EventOutcome.info,
        description: 'app started',
      );
      final events = await EventLogService().getAllEvents();
      expect(events, hasLength(1));
      expect(events.first.type, EventType.appLaunched);
      expect(events.first.outcome, EventOutcome.info);
      expect(events.first.description, 'app started');
    });

    test('events are ordered most-recent-first', () async {
      await EventLogService().logEvent(
        type: EventType.appLaunched,
        outcome: EventOutcome.info,
        description: 'first event',
      );
      await EventLogService().logEvent(
        type: EventType.panicModeActivated,
        outcome: EventOutcome.success,
        description: 'second event',
      );
      final events = await EventLogService().getAllEvents();
      expect(events.length, 2);
      expect(events.first.description, 'second event');
      expect(events.last.description, 'first event');
    });

    test('metadata map is persisted correctly', () async {
      await EventLogService().logEvent(
        type: EventType.safeRouteGenerated,
        outcome: EventOutcome.success,
        description: 'route generated',
        metadata: {'routeCount': 3, 'destination': 'Coventry'},
      );
      final events = await EventLogService().getAllEvents();
      expect(events.first.metadata?['routeCount'], 3);
      expect(events.first.metadata?['destination'], 'Coventry');
    });

    test('multiple events are all persisted', () async {
      for (int i = 0; i < 5; i++) {
        await EventLogService().logEvent(
          type: EventType.appLaunched,
          outcome: EventOutcome.info,
          description: 'event $i',
        );
      }
      final events = await EventLogService().getAllEvents();
      expect(events.length, 5);
    });

    test('empty store returns empty list', () async {
      final events = await EventLogService().getAllEvents();
      expect(events, isEmpty);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Filtering
  // ─────────────────────────────────────────────────────────────────────────

  group('filtering by type and outcome', () {
    setUp(() async {
      final svc = EventLogService();
      await svc.logEvent(
          type: EventType.appLaunched,
          outcome: EventOutcome.info,
          description: 'launch 1');
      await svc.logEvent(
          type: EventType.panicModeActivated,
          outcome: EventOutcome.success,
          description: 'panic');
      await svc.logEvent(
          type: EventType.appLaunched,
          outcome: EventOutcome.warning,
          description: 'launch 2');
    });

    test('getEventsByType returns only matching type', () async {
      final events =
          await EventLogService().getEventsByType(EventType.appLaunched);
      expect(events.length, 2);
      expect(events.every((e) => e.type == EventType.appLaunched), isTrue);
    });

    test('getEventsByOutcome returns only matching outcome', () async {
      final events =
          await EventLogService().getEventsByOutcome(EventOutcome.warning);
      expect(events.length, 1);
      expect(events.first.description, 'launch 2');
    });

    test('getEventsByType returns empty list when type not present', () async {
      final events = await EventLogService()
          .getEventsByType(EventType.emergencyAlertDispatched);
      expect(events, isEmpty);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Storage cap
  // ─────────────────────────────────────────────────────────────────────────

  group('storage cap at 500 events', () {
    test('never stores more than 500 events', () async {
      final svc = EventLogService();
      // Log 505 events to exceed the cap
      for (int i = 0; i < 505; i++) {
        await svc.logEvent(
          type: EventType.appLaunched,
          outcome: EventOutcome.info,
          description: 'event $i',
        );
      }
      final events = await svc.getAllEvents();
      expect(events.length, lessThanOrEqualTo(500));
    });

    test('oldest events are discarded first when cap is exceeded', () async {
      final svc = EventLogService();
      for (int i = 0; i < 502; i++) {
        await svc.logEvent(
          type: EventType.appLaunched,
          outcome: EventOutcome.info,
          description: 'event $i',
        );
      }
      final events = await svc.getAllEvents();
      // Most recent 500 should be retained; event 0 (oldest) should be gone
      final descriptions = events.map((e) => e.description).toList();
      expect(descriptions, isNot(contains('event 0')));
      expect(descriptions, isNot(contains('event 1')));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Privacy — sensitive key redaction in exports
  // ─────────────────────────────────────────────────────────────────────────

  group('export — sensitive key redaction', () {
    setUp(() async {
      await EventLogService().logEvent(
        type: EventType.emergencyAlertDispatched,
        outcome: EventOutcome.success,
        description: 'alert dispatched',
        metadata: {
          // Sensitive — must be redacted in exports
          'latitude': 51.5074,
          'longitude': -1.2345,
          'phone': '+44 7911 000000',
          // Non-sensitive — must appear in exports
          'routeIndex': 2,
        },
      );
    });

    test('text export does not leak lat/lon values', () async {
      final report = await EventLogService().exportEvents();
      expect(report, isNot(contains('51.5074')));
      expect(report, isNot(contains('-1.2345')));
    });

    test('text export does not leak phone number value', () async {
      final report = await EventLogService().exportEvents();
      expect(report, isNot(contains('+44 7911 000000')));
    });

    test('text export always includes the event description', () async {
      final report = await EventLogService().exportEvents();
      expect(report, contains('alert dispatched'));
    });

    test('JSON export also redacts sensitive keys', () async {
      final json = await EventLogService().exportEventsAsJson();
      expect(json, isNot(contains('+44 7911 000000')));
      expect(json, isNot(contains('51.5074')));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // clearAllEvents
  // ─────────────────────────────────────────────────────────────────────────

  group('clearAllEvents()', () {
    test('removes all stored events', () async {
      final svc = EventLogService();
      await svc.logEvent(
          type: EventType.appLaunched,
          outcome: EventOutcome.info,
          description: 'x');
      await svc.clearAllEvents();
      expect(await svc.getAllEvents(), isEmpty);
    });

    test('further logging works normally after clear', () async {
      final svc = EventLogService();
      await svc.clearAllEvents();
      await svc.logEvent(
          type: EventType.appLaunched,
          outcome: EventOutcome.info,
          description: 'after clear');
      final events = await svc.getAllEvents();
      expect(events.length, 1);
      expect(events.first.description, 'after clear');
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Statistics
  // ─────────────────────────────────────────────────────────────────────────

  group('getStatistics()', () {
    test('returns a non-empty map', () async {
      await EventLogService().logEvent(
          type: EventType.panicModeActivated,
          outcome: EventOutcome.success,
          description: 'panic');
      final stats = await EventLogService().getStatistics();
      expect(stats, isA<Map>());
      expect((stats['totalEvents'] as int), greaterThan(0));
    });

    test('totalEvents count matches number of logged events', () async {
      final svc = EventLogService();
      for (int i = 0; i < 3; i++) {
        await svc.logEvent(
            type: EventType.appLaunched,
            outcome: EventOutcome.info,
            description: 'e$i');
      }
      final stats = await svc.getStatistics();
      expect(stats['totalEvents'], 3);
    });
  });
}
