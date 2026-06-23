// test/services/panic_escalation_test.dart
//
// Unit tests for [PanicEscalationService] — the core state machine of Panic
// Mode.  These tests exercise every public trigger method, all valid state
// transitions, guard clauses on terminal stages, trigger-history deduplication,
// and the AlertMetadata builder.
//
// No real platform plugins are needed: SharedPreferences is mocked so that
// the internal EventLogService can log without hitting a platform channel.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shesafe/services/panic_escalation_service.dart';
import 'package:shesafe/models/alert_metadata.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Provide a clean in-memory SharedPreferences for every test so that
    // EventLogService (used internally by PanicEscalationService) can write
    // event logs without hitting a real platform channel.
    SharedPreferences.setMockInitialValues({});
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Initial state
  // ─────────────────────────────────────────────────────────────────────────

  group('initial state after initialize()', () {
    test('stage is monitoring', () async {
      final svc = PanicEscalationService();
      await svc.initialize(sessionId: 'test-init');
      expect(svc.stage, EscalationStage.monitoring);
      svc.dispose();
    });

    test('trigger history is empty', () async {
      final svc = PanicEscalationService();
      await svc.initialize(sessionId: 'test-init-2');
      expect(svc.triggerHistory, isEmpty);
      svc.dispose();
    });

    test('countdown remaining is 0', () async {
      final svc = PanicEscalationService();
      await svc.initialize(sessionId: 'test-init-3');
      expect(svc.countdownRemaining, 0);
      svc.dispose();
    });

    test('sessionId matches the value passed to initialize()', () async {
      final svc = PanicEscalationService();
      await svc.initialize(sessionId: 'my-unique-session');
      expect(svc.sessionId, 'my-unique-session');
      svc.dispose();
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Manual SOS transitions
  // ─────────────────────────────────────────────────────────────────────────

  group('triggerManualSOS()', () {
    late PanicEscalationService svc;
    final List<EscalationStage> stageLog = [];
    final List<EscalationTrigger> triggerLog = [];

    setUp(() async {
      svc = PanicEscalationService();
      stageLog.clear();
      triggerLog.clear();
      svc.onStageChanged = (s, t) {
        stageLog.add(s);
        triggerLog.add(t);
      };
      await svc.initialize(sessionId: 'sos-test');
    });
    tearDown(() => svc.dispose());

    test('first press: monitoring → checkIn', () {
      svc.triggerManualSOS();
      expect(svc.stage, EscalationStage.checkIn);
      expect(stageLog, [EscalationStage.checkIn]);
      expect(triggerLog, [EscalationTrigger.manualSOS]);
    });

    test('second press while in checkIn: checkIn → dispatching', () {
      svc.triggerManualSOS(); // monitoring → checkIn
      svc.triggerManualSOS(); // checkIn → dispatching
      expect(svc.stage, EscalationStage.dispatching);
    });

    test('callback fires with correct trigger on both presses', () {
      svc.triggerManualSOS();
      svc.triggerManualSOS();
      expect(triggerLog,
          [EscalationTrigger.manualSOS, EscalationTrigger.manualSOS]);
    });

    test('SOS followed by cancelAll → cancelled', () {
      svc.triggerManualSOS();
      svc.cancelAll();
      expect(svc.stage, EscalationStage.cancelled);
    });

    test('SOS is a no-op once already dispatching', () {
      svc.triggerManualSOS();
      svc.triggerManualSOS(); // → dispatching
      final before = svc.stage;
      svc.triggerManualSOS(); // should be no-op
      expect(svc.stage, before);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Motion anomaly transitions
  // ─────────────────────────────────────────────────────────────────────────

  group('triggerMotionAnomaly()', () {
    late PanicEscalationService svc;

    setUp(() async {
      svc = PanicEscalationService();
      await svc.initialize(sessionId: 'anomaly-test');
    });
    tearDown(() => svc.dispose());

    test('first anomaly from monitoring → checkIn', () {
      svc.triggerMotionAnomaly(
          score: 0.9, description: 'abrupt stop', consecutiveWindows: 2);
      expect(svc.stage, EscalationStage.checkIn);
    });

    test('second anomaly while in checkIn → countdown', () {
      svc.triggerMotionAnomaly(
          score: 0.8, description: 'spike 1', consecutiveWindows: 1);
      svc.triggerMotionAnomaly(
          score: 0.9, description: 'spike 2', consecutiveWindows: 2);
      expect(svc.stage, EscalationStage.countdown);
    });

    test('anomaly while in countdown does NOT further escalate', () {
      svc.triggerMotionAnomaly(
          score: 0.8, description: 'a', consecutiveWindows: 1);
      svc.triggerMotionAnomaly(
          score: 0.9, description: 'b', consecutiveWindows: 2);
      // Now in countdown — another anomaly should stay in countdown
      svc.triggerMotionAnomaly(
          score: 1.0, description: 'c', consecutiveWindows: 3);
      expect(svc.stage, EscalationStage.countdown);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Safe-word trigger
  // ─────────────────────────────────────────────────────────────────────────

  group('triggerSafeWord()', () {
    late PanicEscalationService svc;

    setUp(() async {
      svc = PanicEscalationService();
      await svc.initialize(sessionId: 'sw-test');
    });
    tearDown(() => svc.dispose());

    test('safe word from monitoring → dispatching immediately', () {
      svc.triggerSafeWord(confidence: 0.95, matchedViaApi: true);
      expect(svc.stage, EscalationStage.dispatching);
    });

    test('safe word from checkIn → dispatching', () {
      svc.triggerManualSOS(); // → checkIn
      svc.triggerSafeWord(confidence: 0.90, matchedViaApi: false);
      expect(svc.stage, EscalationStage.dispatching);
    });

    test('safe word from countdown → dispatching', () {
      // motion anomaly twice to reach countdown
      svc.triggerMotionAnomaly(
          score: 0.8, description: 'a', consecutiveWindows: 1);
      svc.triggerMotionAnomaly(
          score: 0.9, description: 'b', consecutiveWindows: 2);
      svc.triggerSafeWord(confidence: 0.88, matchedViaApi: true);
      expect(svc.stage, EscalationStage.dispatching);
    });

    test('safe word stores confidence value in metadata', () {
      svc.triggerSafeWord(confidence: 0.93, matchedViaApi: true);
      final meta = svc.buildAlertMetadata();
      expect(meta.safeWordConfidence, 0.93);
      expect(meta.safeWordMatchedViaApi, isTrue);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // respondOkay / respondHelp
  // ─────────────────────────────────────────────────────────────────────────

  group('respondOkay() and respondHelp()', () {
    late PanicEscalationService svc;

    setUp(() async {
      svc = PanicEscalationService();
      await svc.initialize(sessionId: 'respond-test');
    });
    tearDown(() => svc.dispose());

    test('respondOkay from checkIn → cancelled', () {
      svc.triggerManualSOS();
      svc.respondOkay();
      expect(svc.stage, EscalationStage.cancelled);
    });

    test('respondHelp from checkIn → dispatching', () {
      svc.triggerManualSOS();
      svc.respondHelp();
      expect(svc.stage, EscalationStage.dispatching);
    });

    test('respondOkay from monitoring is a no-op', () {
      svc.respondOkay();
      expect(svc.stage, EscalationStage.monitoring);
    });

    test('respondHelp from monitoring is a no-op', () {
      svc.respondHelp();
      expect(svc.stage, EscalationStage.monitoring);
    });

    test('respondOkay from countdown → cancelled', () {
      svc.triggerMotionAnomaly(
          score: 0.8, description: 'a', consecutiveWindows: 1);
      svc.triggerMotionAnomaly(
          score: 0.9, description: 'b', consecutiveWindows: 2);
      svc.respondOkay();
      expect(svc.stage, EscalationStage.cancelled);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Terminal-stage guards
  // ─────────────────────────────────────────────────────────────────────────

  group('terminal stages are locked', () {
    late PanicEscalationService svc;

    setUp(() async {
      svc = PanicEscalationService();
      await svc.initialize(sessionId: 'terminal-test');
    });
    tearDown(() => svc.dispose());

    test('cannot escalate after cancelled', () {
      svc.cancelAll();
      expect(svc.stage, EscalationStage.cancelled);
      svc.triggerManualSOS();
      svc.triggerSafeWord(confidence: 1.0, matchedViaApi: true);
      expect(svc.stage, EscalationStage.cancelled);
    });

    test('markResolved from dispatching → resolved', () {
      svc.triggerSafeWord(confidence: 1.0, matchedViaApi: true);
      expect(svc.stage, EscalationStage.dispatching);
      svc.markResolved();
      expect(svc.stage, EscalationStage.resolved);
    });

    test('cannot trigger anything after resolved', () {
      svc.triggerSafeWord(confidence: 1.0, matchedViaApi: true);
      svc.markResolved();
      svc.triggerManualSOS();
      svc.triggerMotionAnomaly(
          score: 1.0, description: 'x', consecutiveWindows: 5);
      expect(svc.stage, EscalationStage.resolved);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Trigger-history deduplication
  // ─────────────────────────────────────────────────────────────────────────

  group('trigger-history deduplication', () {
    test('consecutive identical triggers are not duplicated', () async {
      final svc = PanicEscalationService();
      await svc.initialize(sessionId: 'dedup-test');
      // First anomaly: monitoring → checkIn, recorded
      svc.triggerMotionAnomaly(
          score: 0.8, description: 'a', consecutiveWindows: 1);
      final afterFirst = svc.triggerHistory.length;
      // Second anomaly from checkIn → countdown; same trigger type as last
      // → dedup prevents a second consecutive motionAnomaly entry
      svc.triggerMotionAnomaly(
          score: 0.9, description: 'b', consecutiveWindows: 2);
      expect(svc.triggerHistory.length, afterFirst,
          reason: 'duplicate consecutive motionAnomaly should be collapsed');
      svc.dispose();
    });

    test('different trigger types are all recorded', () async {
      final svc = PanicEscalationService();
      await svc.initialize(sessionId: 'dedup-diff');
      svc.triggerMotionAnomaly(
          score: 0.8, description: 'whoops', consecutiveWindows: 1);
      // Now in checkIn; triggerSafeWord is a different trigger type
      svc.triggerSafeWord(confidence: 0.9, matchedViaApi: true);
      expect(svc.triggerHistory,
          containsAll([EscalationTrigger.safeWord]));
      svc.dispose();
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // AlertMetadata builder
  // ─────────────────────────────────────────────────────────────────────────

  group('buildAlertMetadata()', () {
    test('includes sessionId, location, anomaly data, and safe-word confidence',
        () async {
      final svc = PanicEscalationService();
      await svc.initialize(sessionId: 'meta-full');
      svc.triggerMotionAnomaly(
          score: 0.85, description: 'sudden stop', consecutiveWindows: 3);
      svc.triggerSafeWord(confidence: 0.92, matchedViaApi: true);

      final meta = svc.buildAlertMetadata(latitude: 51.5, longitude: -1.2);

      expect(meta.sessionId, 'meta-full');
      expect(meta.latitude, 51.5);
      expect(meta.longitude, -1.2);
      expect(meta.anomalyScore, 0.85);
      expect(meta.anomalyDescription, 'sudden stop');
      expect(meta.anomalyConsecutiveWindows, 3);
      expect(meta.safeWordConfidence, 0.92);
      expect(meta.safeWordMatchedViaApi, isTrue);
      expect(meta.triggerHistory, contains(EscalationTrigger.safeWord));
      svc.dispose();
    });

    test('metadata without GPS has null coordinates', () async {
      final svc = PanicEscalationService();
      await svc.initialize(sessionId: 'meta-no-gps');
      svc.triggerManualSOS();
      final meta = svc.buildAlertMetadata();
      expect(meta.latitude, isNull);
      expect(meta.longitude, isNull);
      svc.dispose();
    });

    test('triggerType matches the last recorded trigger', () async {
      final svc = PanicEscalationService();
      await svc.initialize(sessionId: 'meta-trigger');
      svc.triggerManualSOS(); // monitoring → checkIn
      svc.respondHelp();      // checkIn → dispatching via userRequestedHelp
      final meta = svc.buildAlertMetadata();
      expect(meta.triggerType, EscalationTrigger.userRequestedHelp);
      svc.dispose();
    });
  });
}
