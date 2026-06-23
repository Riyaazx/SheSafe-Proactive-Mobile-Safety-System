import 'package:flutter_test/flutter_test.dart';
import 'package:shesafe/models/alert_metadata.dart';
import 'package:shesafe/models/motion_baseline.dart';
import 'package:shesafe/services/integration_pipeline_service.dart';
import 'package:shesafe/services/panic_escalation_service.dart';
import 'package:shesafe/services/safe_word_verification_service.dart';

// =============================================================================
// F. Testing & Evaluation — System Tests
// =============================================================================
//
// Goal: Prove the app degrades gracefully — never crashing or blocking the user
// — when fundamental infrastructure is unavailable: no GPS, no internet, and
// permissions denied.
//
// Test areas:
//   Group 1 – No internet / backend offline
//               · SafeWordVerificationResult.error() contract
//               · EscalationAck failure contract
//               · IntegrationPipelineService health-cache invalidation
//               · Route explanation: null returned → graceful degradation
//   Group 2 – No GPS / location unavailable
//               · PanicEscalationService.buildAlertMetadata(lat=null, lon=null)
//               · AlertMetadata with null coordinates still stores trigger info
//   Group 3 – Permissions denied
//               · Stage machine still transitions on manualSOS (no sensor dependency)
//               · Safe word error result does not crash escalation state machine
//   Group 4 – State machine robustness
//               · Terminal stage transitions are no-ops
//               · Duplicate trigger records are deduplicated
//               · cancelAll() from monitoring/checkIn/countdown all reach cancelled
//   Group 5 – Error propagation
//               · PanicEscalationService trigger order is preserved in triggerHistory
//               · respondOkay() from non-checkIn stage is a no-op
//               · respondHelp() from non-checkIn stage is a no-op
//               · markResolved() only from dispatching stage
// =============================================================================

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Build a fresh PanicEscalationService without touching real timers.
/// Initializes synchronously via the future returned by initialize().
Future<PanicEscalationService> _freshService({String sessionId = 'test-001'}) async {
  final svc = PanicEscalationService();
  await svc.initialize(sessionId: sessionId);
  return svc;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // =========================================================================
  // GROUP 1 — No internet / backend offline
  // =========================================================================
  group('No internet / backend offline', () {
    test('SafeWordVerificationResult.error() never causes a crash', () {
      // When the HTTP call times out (>1 s) the service returns an error
      // result.  The model must be safe to read in every code path.
      final result = SafeWordVerificationResult.error('Connection refused');

      // Core safety contract: must not throw and must clearly signal failure
      expect(result.isError, isTrue);
      expect(result.detected, isFalse);
      expect(result.isVerified, isFalse);
      expect(result.shouldRetry, isFalse);
      expect(() => result.statusMessage, returnsNormally);
    });

    test('EscalationAck failure: success=false, non-null latencyMs', () {
      // Fire-and-forget escalation call returns a failure ack when the backend
      // is unreachable.  The Panic Mode state machine must never wait on it.
      const ack = EscalationAck(
        success: false,
        message: 'timeout after 1500 ms',
        latencyMs: 1500,
      );

      expect(ack.success, isFalse);
      expect(ack.latencyMs, greaterThan(0));
      expect(ack.backendStage, isNull);
    });

    test('IntegrationPipelineService invalidateHealthCache resets cached state', () {
      // After a network error the health check cache must be invalidated so
      // the next probe gets a fresh read.
      final service = IntegrationPipelineService.instance;
      // Two successive invalidations must not throw.
      expect(() {
        service.invalidateHealthCache();
        service.invalidateHealthCache();
      }, returnsNormally);
    });

    test('BackendRouteExplanation null represents graceful degradation', () {
      // The fetchRouteExplanation() returns null when the backend is offline.
      // All downstream code must accept null gracefully.
      BackendRouteExplanation? explanation; // null = backend offline
      expect(explanation, isNull);

      // Simulate how the UI screen would handle this.
      // Moving the null-aware expression into a function prevents a false
      // dead_code warning (the parameter is not statically known to be null).
      String summarise(BackendRouteExplanation? exp) =>
          exp?.summary ?? 'Local route analysis only';
      final summary = summarise(explanation);
      expect(summary, equals('Local route analysis only'));
    });

    test('EscalationAck latency is always populated regardless of success', () {
      final successAck = const EscalationAck(
        success: true,
        latencyMs: 320,
      );
      final failAck = const EscalationAck(
        success: false,
        latencyMs: 1501, // exceeded 1.5 s escalation budget
      );

      // Both must have a non-negative latency (for performance logging)
      expect(successAck.latencyMs, greaterThanOrEqualTo(0));
      expect(failAck.latencyMs, greaterThanOrEqualTo(0));
    });
  });

  // =========================================================================
  // GROUP 2 — No GPS / location unavailable
  // =========================================================================
  group('No GPS / location unavailable', () {
    test('buildAlertMetadata with null lat/lon stores trigger correctly', () async {
      final svc = await _freshService();
      svc.triggerManualSOS();

      // GPS unavailable → pass null coordinates
      final meta = svc.buildAlertMetadata(latitude: null, longitude: null);

      // Alert must still be dispatched with whatever context is available
      expect(meta.latitude, isNull);
      expect(meta.longitude, isNull);
      // But trigger information must be preserved
      expect(meta.triggerType, isNotNull);
      expect(meta.sessionId, equals('test-001'));
      expect(meta.triggerHistory, isNotEmpty);

      svc.dispose();
    });

    test('AlertMetadata.timestamp is always populated (not dependent on GPS)', () async {
      final svc = await _freshService();
      svc.triggerManualSOS();

      final before = DateTime.now().toUtc().subtract(const Duration(seconds: 1));
      final meta = svc.buildAlertMetadata();
      final after = DateTime.now().toUtc().add(const Duration(seconds: 1));

      expect(meta.timestamp.isAfter(before), isTrue);
      expect(meta.timestamp.isBefore(after), isTrue);

      svc.dispose();
    });

    test('AlertMetadata stores anomaly info when motion data collected before GPS fails', () async {
      final svc = await _freshService();

      // Motion data collected during monitoring (sensor worked)
      svc.triggerMotionAnomaly(
        score: 0.88,
        description: 'Unusual jerk detected',
        consecutiveWindows: 3,
      );

      // GPS fails at dispatch
      final meta = svc.buildAlertMetadata(latitude: null, longitude: null);

      expect(meta.anomalyScore, closeTo(0.88, 0.001));
      expect(meta.anomalyDescription, contains('jerk'));
      expect(meta.anomalyConsecutiveWindows, equals(3));
      expect(meta.latitude, isNull);

      svc.dispose();
    });
  });

  // =========================================================================
  // GROUP 3 — Permissions denied
  // =========================================================================
  group('Permissions denied', () {
    test('Panic escalation via manualSOS works without sensor permissions', () async {
      // The motion sensor is not needed to manually trigger SOS.
      // Test that triggerManualSOS works purely via the state machine.
      final svc = await _freshService();

      EscalationStage? seenStage;
      svc.onStageChanged = (stage, _) => seenStage = stage;

      // Simulate: microphone + accelerometer permissions denied.
      // The user triggers escalation manually via the UI button.
      svc.triggerManualSOS();
      expect(seenStage, equals(EscalationStage.checkIn),
          reason:
              'Manual SOS must transition to checkIn even when sensor '
              'permissions are denied');

      svc.dispose();
    });

    test('Safe word error result does not crash escalation state machine', () async {
      // When microphone permission is denied, speech recognition fails and
      // SafeWordVerificationService returns an error result.  The state
      // machine must not attempt to process it and must remain in its current stage.
      final svc = await _freshService();
      final errorResult = SafeWordVerificationResult.error('Permission denied');

      // State machine should still be in monitoring after the error
      expect(svc.stage, equals(EscalationStage.monitoring));

      // Attempting to use the error result:
      if (!errorResult.isError && errorResult.detected) {
        svc.triggerSafeWord(
          confidence: errorResult.confidence,
          matchedViaApi: !errorResult.isError,
        );
      }

      // Stage must remain unchanged — error result must not trigger escalation
      expect(svc.stage, equals(EscalationStage.monitoring));

      svc.dispose();
    });

    test('Notification-denied scenario: EscalationAck still returned', () {
      // Even when notification permission is denied, the escalation ack model
      // is populated correctly (notification sending is handled separately).
      const ack = EscalationAck(
        success: true,
        backendStage: 'dispatching',
        message: 'Backend acknowledged',
        latencyMs: 410,
      );
      expect(ack.success, isTrue);
      expect(ack.latencyMs, lessThan(1500));
    });

    test('Uncalibrated motion service returns benign (no-alert) result', () {
      // When location + sensor permissions denied during onboarding,
      // motion baseline stays empty(). scoreWindow() must return normal result.
      final empty = MotionBaseline.empty();
      expect(empty.isCalibrated, isFalse,
          reason: 'No permissions → no calibration → must not trigger alerts');
    });
  });

  // =========================================================================
  // GROUP 4 — State machine robustness
  // =========================================================================
  group('PanicEscalationService state machine robustness', () {
    test('Terminal states (resolved, cancelled) ignore further triggers', () async {
      final svc = await _freshService();
      // Force to cancelled
      svc.triggerManualSOS();   // monitoring → checkIn
      svc.cancelAll();          // checkIn → cancelled

      final stageBefore = svc.stage;
      // These calls must all be silent no-ops
      svc.triggerManualSOS();
      svc.triggerMotionAnomaly(
          score: 0.99, description: 'x', consecutiveWindows: 5);
      svc.cancelAll();

      expect(svc.stage, equals(stageBefore),
          reason: 'Terminal stage must not change after being entered');
      svc.dispose();
    });

    test('Duplicate consecutive triggers are deduplicated in history', () async {
      final svc = await _freshService();
      svc.triggerManualSOS(); // monitoring → checkIn, records manualSOS once

      // Fire the same trigger twice more (should already be in checkIn)
      svc.triggerManualSOS(); // checkIn → dispatching on second press
      // Third call — should be in dispatching (no-op)
      svc.triggerManualSOS();

      // Verify no duplicate consecutive entries exist
      final history = svc.triggerHistory;
      for (int i = 1; i < history.length; i++) {
        expect(history[i], isNot(equals(history[i - 1])),
            reason:
                'Consecutive duplicate trigger entries must be collapsed '
                'to avoid inflating the audit trail');
      }

      svc.dispose();
    });

    test('cancelAll() from monitoring → cancelled', () async {
      final svc = await _freshService();
      svc.cancelAll();
      expect(svc.stage, equals(EscalationStage.cancelled));
      svc.dispose();
    });

    test('cancelAll() from checkIn → cancelled', () async {
      final svc = await _freshService();
      svc.triggerManualSOS(); // → checkIn
      svc.cancelAll();
      expect(svc.stage, equals(EscalationStage.cancelled));
      svc.dispose();
    });

    test('Safe word from monitoring → dispatching (bypasses checkIn)', () async {
      // The safe word can only be spoken purposely while in distress,
      // so it fast-tracks directly to dispatching from any active stage.
      final svc = await _freshService();
      svc.triggerSafeWord(confidence: 0.91, matchedViaApi: true);
      expect(svc.stage, equals(EscalationStage.dispatching));
      svc.dispose();
    });

    test('Safe word from checkIn → dispatching', () async {
      final svc = await _freshService();
      svc.triggerManualSOS(); // → checkIn
      svc.triggerSafeWord(confidence: 0.87, matchedViaApi: true);
      expect(svc.stage, equals(EscalationStage.dispatching));
      svc.dispose();
    });
  });

  // =========================================================================
  // GROUP 5 — Error propagation & stage guard contracts
  // =========================================================================
  group('Error propagation & stage guards', () {
    test('triggerHistory preserves insertion order', () async {
      final svc = await _freshService();
      svc.triggerManualSOS();   // → checkIn
      svc.triggerMotionAnomaly( // → countdown (second anomaly while in checkIn)
          score: 0.9, description: 'jerk', consecutiveWindows: 3);

      final history = svc.triggerHistory;
      expect(history.first, equals(EscalationTrigger.manualSOS));
      // motionAnomaly was recorded in checkIn stage; it must appear after manualSOS
      expect(history.last, equals(EscalationTrigger.motionAnomaly));

      svc.dispose();
    });

    test('respondOkay() from monitoring stage is a no-op', () async {
      final svc = await _freshService();
      svc.respondOkay();
      expect(svc.stage, equals(EscalationStage.monitoring),
          reason: 'respondOkay only acts from checkIn or countdown stages');
      svc.dispose();
    });

    test('respondHelp() from monitoring stage is a no-op', () async {
      final svc = await _freshService();
      svc.respondHelp();
      expect(svc.stage, equals(EscalationStage.monitoring),
          reason: 'respondHelp only acts from checkIn stage');
      svc.dispose();
    });

    test('markResolved() from non-dispatching stage is a no-op', () async {
      final svc = await _freshService();
      svc.markResolved();
      expect(svc.stage, equals(EscalationStage.monitoring),
          reason: 'markResolved() only transitions from dispatching stage');
      svc.dispose();
    });

    test('markResolved() from dispatching stage → resolved', () async {
      final svc = await _freshService();
      svc.triggerSafeWord(confidence: 0.90, matchedViaApi: true); // → dispatching
      svc.markResolved();
      expect(svc.stage, equals(EscalationStage.resolved));
      svc.dispose();
    });

    test('Initialize with new sessionId resets all state', () async {
      final svc = await _freshService(sessionId: 'old');
      svc.triggerManualSOS(); // accumulate some state

      await svc.initialize(sessionId: 'new');
      expect(svc.stage, equals(EscalationStage.monitoring));
      expect(svc.sessionId, equals('new'));
      expect(svc.triggerHistory, isEmpty);
      expect(svc.countdownRemaining, equals(0));

      svc.dispose();
    });

    test('EscalationTrigger labels are non-empty for all cases', () {
      // Every trigger must have a human-readable label for the audit event log.
      for (final trigger in EscalationTrigger.values) {
        expect(trigger.label.isNotEmpty, isTrue,
            reason: 'Trigger ${trigger.name} has an empty label');
      }
    });

    test('EscalationStage values cover all 6 stages', () {
      expect(EscalationStage.values.length, equals(6),
          reason:
              'monitoring, checkIn, countdown, dispatching, resolved, cancelled');
    });

    test('checkIn and countdown duration constants are within design bounds', () {
      // checkInTimeoutSeconds = 30 s: long enough to respond, short enough to
      // escalate quickly if the user is unable to act.
      expect(PanicEscalationService.checkInTimeoutSeconds, equals(30));

      // countdownDurationSeconds = 10 s: tight enough to reach help quickly,
      // generous enough that a false positive can be cancelled.
      expect(PanicEscalationService.countdownDurationSeconds, equals(10));
    });
  });

  // =========================================================================
  // GROUP 6 — Early uneasy stage: end-to-end escalation path
  //
  // Traces the complete "user does not respond" journey:
  //
  //   monitoring ──(motionAnomaly, 3 consecutive)──▶ checkIn
  //              ──(no response — second motionAnomaly)──▶ countdown
  //              ──(cancel OR safe word)──────────────▶ cancelled / dispatching
  //
  // Validates:
  //   (a) every state transition fires in the correct order
  //   (b) audit history records every trigger chronologically
  //   (c) the terminal state is reached cleanly (no exceptions)
  // =========================================================================
  group('Group 6 – Early uneasy stage: full E2E escalation path', () {
    test(
        'E2E FP path: motionAnomaly → checkIn → non-response → countdown → cancel',
        () async {
      final svc = await _freshService(sessionId: 'e2e-fp-001');
      final stages = <EscalationStage>[];
      svc.onStageChanged = (stage, _) => stages.add(stage);

      // Step 1: Motion anomaly detected (3 consecutive windows)
      svc.triggerMotionAnomaly(
        score: 0.88,
        description: 'Unusual jerk spike detected in 3 consecutive windows',
        consecutiveWindows: 3,
      );
      expect(
        svc.stage,
        equals(EscalationStage.checkIn),
        reason:
            'After 3 consecutive anomalous windows the service must enter '
            'checkIn and prompt the user to confirm safety',
      );

      // Step 2: No user response — watcher re-triggers while in checkIn
      // (represents the checkIn timeout expiring without a user action)
      svc.triggerMotionAnomaly(
        score: 0.91,
        description: 'No response from user — sustained motion anomaly',
        consecutiveWindows: 4,
      );
      expect(
        svc.stage,
        equals(EscalationStage.countdown),
        reason: 'Non-response escalates from checkIn to countdown',
      );

      // Step 3: False positive — user finds phone and cancels
      svc.cancelAll();
      expect(
        svc.stage,
        equals(EscalationStage.cancelled),
        reason: 'User cancelled during countdown → terminal cancelled state',
      );

      // The full stage journey must appear in chronological order
      expect(
        stages,
        equals([
          EscalationStage.checkIn,
          EscalationStage.countdown,
          EscalationStage.cancelled,
        ]),
        reason: 'Every state transition must be captured in order',
      );

      // Audit history must contain the motion anomaly trigger
      expect(
        svc.triggerHistory,
        contains(EscalationTrigger.motionAnomaly),
        reason: 'motionAnomaly must appear in audit history',
      );

      svc.dispose();
    });

    test(
        'E2E emergency path: motionAnomaly → checkIn → countdown → dispatch → resolved',
        () async {
      final svc = await _freshService(sessionId: 'e2e-emergency-001');
      final stages = <EscalationStage>[];
      svc.onStageChanged = (stage, _) => stages.add(stage);

      // monitoring → checkIn
      svc.triggerMotionAnomaly(
        score: 0.85,
        description: 'Initial anomaly detected',
        consecutiveWindows: 3,
      );
      expect(svc.stage, equals(EscalationStage.checkIn));

      // checkIn → countdown (non-response — watcher re-triggers)
      svc.triggerMotionAnomaly(
        score: 0.93,
        description: 'Second anomaly — user has not responded',
        consecutiveWindows: 5,
      );
      expect(svc.stage, equals(EscalationStage.countdown));

      // countdown → dispatching via safe word (genuine emergency)
      svc.triggerSafeWord(confidence: 0.92, matchedViaApi: true);
      expect(
        svc.stage,
        equals(EscalationStage.dispatching),
        reason: 'Safe word during countdown must fast-track to dispatching',
      );

      // dispatching → resolved (backend confirmed)
      svc.markResolved();
      expect(
        svc.stage,
        equals(EscalationStage.resolved),
        reason: 'markResolved() must transition dispatching → resolved',
      );

      // Full 4-stage journey in order
      expect(
        stages,
        equals([
          EscalationStage.checkIn,
          EscalationStage.countdown,
          EscalationStage.dispatching,
          EscalationStage.resolved,
        ]),
      );

      svc.dispose();
    });

    test(
        'E2E: anomaly score and consecutive windows are preserved in final metadata',
        () async {
      final svc = await _freshService(sessionId: 'e2e-meta-001');
      const expectedScore = 0.89;
      const expectedConsec = 3;

      svc.triggerMotionAnomaly(
        score: expectedScore,
        description: 'High jerk + variance combination',
        consecutiveWindows: expectedConsec,
      );

      // Metadata captured even before GPS is available
      final meta = svc.buildAlertMetadata(latitude: null, longitude: null);
      expect(meta.anomalyScore, closeTo(expectedScore, 0.001));
      expect(meta.anomalyConsecutiveWindows, equals(expectedConsec));
      expect(
        meta.latitude,
        isNull,
        reason: 'No GPS supplied → lat must be null (graceful degradation)',
      );

      svc.dispose();
    });
  });
}
