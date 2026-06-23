import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/alert_metadata.dart';
import '../models/event_log.dart';
import 'event_log_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Escalation stages
// ─────────────────────────────────────────────────────────────────────────────

/// All possible stages of the panic-mode state machine.
///
/// Transitions (→ = allowed, ✗ = ignored):
///   monitoring   → checkIn (manualSOS, motionAnomaly)
///   monitoring   → dispatching (safeWord)
///   checkIn      → countdown (motionAnomaly while in checkIn, timeout)
///   checkIn      → dispatching (respondHelp, safeWord, second manualSOS)
///   checkIn      → cancelled (respondOkay, cancelAll)
///   countdown    → cancelled (userCancelled)
///   countdown    → dispatching (countdown expired, safeWord)
///   dispatching  → resolved (after alert sent)
///   resolved / cancelled are terminal
enum EscalationStage {
  /// Stage 1 – high-alert monitoring, no prompt yet.
  monitoring,

  /// Stage 2 – "Are you okay?" check-in prompt shown to the user.
  checkIn,

  /// Stage 3 – Countdown timer running; dispatch if it reaches zero.
  countdown,

  /// Stage 4 – Alert is being / has been dispatched.
  dispatching,

  /// Terminal: alert was dispatched successfully.
  resolved,

  /// Terminal: user confirmed safety and cancelled from any stage.
  cancelled,
}

// ─────────────────────────────────────────────────────────────────────────────
// Service
// ─────────────────────────────────────────────────────────────────────────────

/// Backend state machine for Panic Mode escalation.
///
/// Responsibility:
///   - Tracks current [EscalationStage]
///   - Manages check-in and countdown timers
///   - Collects trigger history and anomaly/confidence values
///   - Fires UI callbacks so the screen can react without polling
///
/// The screen is responsible for:
///   - Rendering the appropriate UI per stage
///   - Fetching GPS at dispatch time
///   - Sending the actual SMS / alert
///
/// Usage:
/// ```dart
/// final svc = PanicEscalationService();
/// svc.onStageChanged  = (stage, trigger) { … };
/// svc.onCountdownTick = (remaining)       { … };
/// await svc.initialize(sessionId: '…');
/// svc.triggerMotionAnomaly(score: 0.9, description: '…', consecutiveWindows: 3);
/// ```
class PanicEscalationService {



  /// Seconds the check-in prompt is shown before auto-escalating to countdown.
  static const int checkInTimeoutSeconds = 30;

  /// Seconds the countdown runs before auto-dispatching the alert.
  static const int countdownDurationSeconds = 10;

  // ── Callbacks (set by the screen) ─────────────────────────────────────────

  /// Fired whenever the stage changes.
  /// [stage]   – new stage
  /// [trigger] – what caused the transition
  void Function(EscalationStage stage, EscalationTrigger trigger)?
      onStageChanged;

  /// Fired once per second during countdown; [remaining] counts down to 0.
  void Function(int remaining)? onCountdownTick;

  // ── Public state (read-only) ───────────────────────────────────────────────

  EscalationStage get stage => _stage;
  String get sessionId => _sessionId;
  List<EscalationTrigger> get triggerHistory =>
      List.unmodifiable(_triggerHistory);

  /// Remaining seconds during the current countdown (0 outside countdown).
  int get countdownRemaining => _countdownRemaining;



  // ── Private fields ─────────────────────────────────────────────────────────

  EscalationStage _stage = EscalationStage.monitoring;
  String _sessionId = '';
  final List<EscalationTrigger> _triggerHistory = [];

  // Latest anomaly values collected during the session
  double? _anomalyScore;
  String? _anomalyDescription;
  int? _anomalyConsecutiveWindows;

  // Safe-word match values
  double? _safeWordConfidence;
  bool? _safeWordMatchedViaApi;

  // Timers
  Timer? _checkInTimer;
  Timer? _countdownTimer;
  int _countdownRemaining = 0;

  final EventLogService _eventLog = EventLogService();

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  /// Must be called once before any triggers.
  /// [sessionId] should be globally unique for this panic session.
  Future<void> initialize({required String sessionId}) async {
    _sessionId = sessionId;
    _stage = EscalationStage.monitoring;
    _triggerHistory.clear();
    _anomalyScore = null;
    _anomalyDescription = null;
    _anomalyConsecutiveWindows = null;
    _safeWordConfidence = null;
    _safeWordMatchedViaApi = null;
    _cancelAllTimers();
    debugPrint('⚡ PanicEscalationService initialized (session: $sessionId)');
  }

  void dispose() {
    _cancelAllTimers();
    onStageChanged = null;
    onCountdownTick = null;
    debugPrint('⚡ PanicEscalationService disposed');
  }

  // ── Public trigger methods ─────────────────────────────────────────────────

  /// Called when the user presses the on-screen SOS button.
  void triggerManualSOS() {
    debugPrint('🚨 Trigger: manualSOS (current stage: ${_stage.name})');
    _record(EscalationTrigger.manualSOS);
    if (_stage == EscalationStage.monitoring) {
      _transitionTo(EscalationStage.checkIn, EscalationTrigger.manualSOS);
    } else if (_stage == EscalationStage.checkIn) {
      // Second press – user is insisting → fast-track to dispatching
      _transitionTo(EscalationStage.dispatching, EscalationTrigger.manualSOS);
    } else if (_stage == EscalationStage.countdown) {
      // Pressing SOS during countdown fast-tracks to dispatch
      _transitionTo(EscalationStage.dispatching, EscalationTrigger.manualSOS);
    }
    // no-op in dispatching / resolved / cancelled
  }

  /// Called when the motion baseline service detects an anomaly spike.
  void triggerMotionAnomaly({
    required double score,
    required String description,
    required int consecutiveWindows,
  }) {
    _anomalyScore = score;
    _anomalyDescription = description;
    _anomalyConsecutiveWindows = consecutiveWindows;
    debugPrint('📳 Trigger: motionAnomaly (score=$score, consecutive=$consecutiveWindows, stage=${_stage.name})');
    if (_stage == EscalationStage.monitoring) {
      _record(EscalationTrigger.motionAnomaly);
      _transitionTo(EscalationStage.checkIn, EscalationTrigger.motionAnomaly);
    } else if (_stage == EscalationStage.checkIn) {
      // Second anomaly while user has not responded → escalate to countdown
      _record(EscalationTrigger.motionAnomaly);
      _transitionTo(EscalationStage.countdown, EscalationTrigger.motionAnomaly);
    }
    // In countdown or later stages we just keep recording but don't escalate further.
  }

  /// Called when the speech-to-text system detects the user's safe word.
  void triggerSafeWord({
    required double confidence,
    required bool matchedViaApi,
  }) {
    _safeWordConfidence = confidence;
    _safeWordMatchedViaApi = matchedViaApi;

    debugPrint(
        '🔐 Trigger: safeWord (confidence=$confidence, api=$matchedViaApi, '
        'stage=${_stage.name})');

    if (_stage == EscalationStage.monitoring ||
        _stage == EscalationStage.checkIn ||
        _stage == EscalationStage.countdown) {
      _record(EscalationTrigger.safeWord);
      _transitionTo(EscalationStage.dispatching, EscalationTrigger.safeWord);
    }
  }



  /// Called when the user taps "I'm okay" on the check-in prompt.
  /// From [checkIn] or [countdown] → [cancelled]; no-op otherwise.
  void respondOkay() {
    debugPrint('✅ respondOkay (stage=${_stage.name})');
    if (_stage == EscalationStage.checkIn ||
        _stage == EscalationStage.countdown) {
      _record(EscalationTrigger.userConfirmedOkay);
      _transitionTo(EscalationStage.cancelled, EscalationTrigger.userConfirmedOkay);
    }
  }

  /// Called when the user taps "Send Help" on the check-in prompt.
  /// From [checkIn] → [dispatching]; no-op otherwise.
  void respondHelp() {
    debugPrint('🆘 respondHelp (stage=${_stage.name})');
    if (_stage == EscalationStage.checkIn) {
      _record(EscalationTrigger.userRequestedHelp);
      _transitionTo(EscalationStage.dispatching, EscalationTrigger.userRequestedHelp);
    }
  }

  /// Cancels from any non-terminal stage.
  void cancelAll() {
    debugPrint('🛑 User cancelled panic mode (stage=${_stage.name})');
    if (_stage == EscalationStage.monitoring ||
        _stage == EscalationStage.checkIn ||
        _stage == EscalationStage.countdown) {
      _record(EscalationTrigger.userCancelled);
      _transitionTo(EscalationStage.cancelled, EscalationTrigger.userCancelled);
    }
  }

  /// Must be called by the screen once the alert has actually been dispatched
  /// (SMS sent, contacts notified, etc.).
  void markResolved() {
    if (_stage == EscalationStage.dispatching) {
      _transitionTo(EscalationStage.resolved, _triggerHistory.last);
    }
  }

  // ── Metadata builder ───────────────────────────────────────────────────────

  /// Builds the [AlertMetadata] bundle to attach to the dispatched alert.
  /// [latitude] / [longitude] should be provided from a fresh GPS fix.
  AlertMetadata buildAlertMetadata({
    double? latitude,
    double? longitude,
  }) {
    final primary = _triggerHistory.isNotEmpty
        ? _triggerHistory.last
        : EscalationTrigger.manualSOS;

    return AlertMetadata(
      sessionId: _sessionId,
      timestamp: DateTime.now().toUtc(),
      triggerType: primary,
      latitude: latitude,
      longitude: longitude,
      anomalyDescription: _anomalyDescription,
      anomalyScore: _anomalyScore,
      anomalyConsecutiveWindows: _anomalyConsecutiveWindows,
      safeWordConfidence: _safeWordConfidence,
      safeWordMatchedViaApi: _safeWordMatchedViaApi,
      triggerHistory: List.unmodifiable(_triggerHistory),
    );
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  void _record(EscalationTrigger trigger) {
    // Avoid duplicate consecutive entries (e.g. repeated motion anomaly callbacks)
    if (_triggerHistory.isEmpty || _triggerHistory.last != trigger) {
      _triggerHistory.add(trigger);
    }
  }

  void _transitionTo(EscalationStage newStage, EscalationTrigger trigger) {
    if (_stage == newStage) return;

    final oldStage = _stage;
    _stage = newStage;

    debugPrint(
        '🔄 Escalation: ${oldStage.name} → ${newStage.name} (${trigger.label})');

    // Cancel timers that belong to the old stage
    _cancelAllTimers();

    // Start timers for the new stage
    if (newStage == EscalationStage.checkIn) {
      _startCheckInTimer();
    } else if (newStage == EscalationStage.countdown) {
      _startCountdownTimer();
    }

    // Notify the screen
    onStageChanged?.call(newStage, trigger);

    // Audit log
    _logTransition(oldStage, newStage, trigger);
  }

  // ── Timer management ───────────────────────────────────────────────────────



  void _startCheckInTimer() {
    _checkInTimer = Timer(Duration(seconds: checkInTimeoutSeconds), () {
      if (_stage == EscalationStage.checkIn) {
        debugPrint('⏰ Check-in timeout – escalating to countdown');
        _record(EscalationTrigger.nonResponse);
        _transitionTo(EscalationStage.countdown, EscalationTrigger.nonResponse);
      }
    });
  }

  void _startCountdownTimer() {
    _countdownRemaining = countdownDurationSeconds;
    onCountdownTick?.call(_countdownRemaining);

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      _countdownRemaining--;
      onCountdownTick?.call(_countdownRemaining);

      if (_countdownRemaining <= 0) {
        t.cancel();
        if (_stage == EscalationStage.countdown) {
          debugPrint('⏰ Countdown expired – dispatching alert');
          _record(EscalationTrigger.nonResponse);
          _transitionTo(
              EscalationStage.dispatching, EscalationTrigger.nonResponse);
        }
      }
    });
  }

  void _cancelAllTimers() {
    _checkInTimer?.cancel();
    _checkInTimer = null;
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  // ── Event logging ──────────────────────────────────────────────────────────

  void _logTransition(
    EscalationStage from,
    EscalationStage to,
    EscalationTrigger trigger,
  ) {
    EventType? type;
    EventOutcome outcome;

    switch (to) {
      case EscalationStage.checkIn:
        type = EventType.escalationStageChanged;
        outcome = EventOutcome.warning;
        break;
      case EscalationStage.countdown:
        type = EventType.countdownStarted;
        outcome = EventOutcome.warning;
        break;
      case EscalationStage.dispatching:
        type = EventType.escalationStageChanged;
        outcome = EventOutcome.warning;
        break;
      case EscalationStage.resolved:
        type = EventType.emergencyAlertDispatched;
        outcome = EventOutcome.success;
        break;
      case EscalationStage.cancelled:
        type = trigger == EscalationTrigger.userCancelled ||
                trigger == EscalationTrigger.userConfirmedOkay
            ? EventType.countdownCancelled
            : EventType.escalationStageChanged;
        outcome = EventOutcome.info;
        break;
      default:
        return;
    }

    _eventLog.logEvent(
      type: type,
      outcome: outcome,
      description:
          'Escalation: ${from.name} → ${to.name} (${trigger.label})',
      metadata: {
        'sessionId': _sessionId,
        'fromStage': from.name,
        'toStage': to.name,
        'trigger': trigger.name,
        'triggerHistory': _triggerHistory.map((t) => t.name).toList(),
        if (_anomalyScore != null) 'anomalyScore': _anomalyScore,
        if (_anomalyConsecutiveWindows != null)
          'consecutiveWindows': _anomalyConsecutiveWindows,
        if (_safeWordConfidence != null)
          'safeWordConfidence': _safeWordConfidence,
      },
    );
  }
}
