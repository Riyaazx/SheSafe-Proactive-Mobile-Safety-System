import 'package:flutter/material.dart';

/// Represents different types of events that can be logged
enum EventType {
  safeRouteGenerated,
  riskZoneDetected,
  panicModeActivated,
  panicModeDeactivated,
  safeWordVerified,
  safeWordFailed,
  trustedContactAlerted,
  safetyModeActivated,
  calibrationCompleted,
  locationPermissionGranted,
  locationPermissionDenied,
  appLaunched,
  motionBaselineCalibrated,
  motionAnomalyDetected,
  motionConcernTriggered,
  // ── Escalation state-machine events ──────────────────────────────────────
  /// The escalation stage advanced (e.g. monitoring → checkIn)
  escalationStageChanged,
  /// The "Are you okay?" check-in prompt was surfaced to the user
  checkInPromptShown,
  /// User responded to the check-in prompt (confirmed safe or requested help)
  checkInResponseReceived,
  /// 10-second countdown to automatic dispatch was started
  countdownStarted,
  /// Countdown was cancelled by the user
  countdownCancelled,
  /// Emergency alert was fully dispatched (SMS / contact notified)
  emergencyAlertDispatched,

  /// User arrived at destination and trusted contact was notified
  arrivalNotificationSent,

  /// Walk completed — post-walk safety summary generated
  walkCompleted,

  /// User attempted to plan a safe route but was blocked before generation
  /// (e.g. empty destination, location permission denied at entry point).
  safeRouteAttempted,
}

/// Represents the outcome/status of an event
enum EventOutcome {
  success,
  warning,
  failure,
  info,
}

/// Model for logging app events without exposing sensitive data
class EventLog {
  final String id;
  final DateTime timestamp;
  final EventType type;
  final EventOutcome outcome;
  final String description;
  final Map<String, dynamic>? metadata;

  EventLog({
    required this.id,
    required this.timestamp,
    required this.type,
    required this.outcome,
    required this.description,
    this.metadata,
  });

  /// Create EventLog from JSON
  factory EventLog.fromJson(Map<String, dynamic> json) {
    return EventLog(
      id: json['id'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      type: EventType.values.firstWhere(
        (e) => e.toString() == json['type'],
        orElse: () => EventType.appLaunched,
      ),
      outcome: EventOutcome.values.firstWhere(
        (e) => e.toString() == json['outcome'],
        orElse: () => EventOutcome.info,
      ),
      description: json['description'] as String,
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }

  /// Convert EventLog to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'timestamp': timestamp.toIso8601String(),
      'type': type.toString(),
      'outcome': outcome.toString(),
      'description': description,
      'metadata': metadata,
    };
  }

  /// Get user-friendly display name for event type
  String get typeName {
    switch (type) {
      case EventType.safeRouteGenerated:
        return 'Safe Route Generated';
      case EventType.riskZoneDetected:
        return 'Risk Zone Detected';
      case EventType.panicModeActivated:
        return 'Panic Mode Activated';
      case EventType.panicModeDeactivated:
        return 'Panic Mode Deactivated';
      case EventType.safeWordVerified:
        return 'Safe Word Verified';
      case EventType.safeWordFailed:
        return 'Safe Word Failed';
      case EventType.trustedContactAlerted:
        return 'Trusted Contact Alerted';
      case EventType.safetyModeActivated:
        return 'Safety Mode Activated';
      case EventType.calibrationCompleted:
        return 'Calibration Completed';
      case EventType.locationPermissionGranted:
        return 'Location Permission Granted';
      case EventType.locationPermissionDenied:
        return 'Location Permission Denied';
      case EventType.appLaunched:
        return 'App Launched';
      case EventType.motionBaselineCalibrated:
        return 'Motion Baseline Calibrated';
      case EventType.motionAnomalyDetected:
        return 'Motion Anomaly Detected';
      case EventType.motionConcernTriggered:
        return 'Motion Concern Triggered';
      case EventType.escalationStageChanged:
        return 'Escalation Stage Changed';
      case EventType.checkInPromptShown:
        return 'Check-In Prompt Shown';
      case EventType.checkInResponseReceived:
        return 'Check-In Response Received';
      case EventType.countdownStarted:
        return 'Countdown Started';
      case EventType.countdownCancelled:
        return 'Countdown Cancelled';
      case EventType.emergencyAlertDispatched:
        return 'Emergency Alert Dispatched';
      case EventType.arrivalNotificationSent:
        return 'Arrival Notification Sent';
      case EventType.walkCompleted:
        return 'Walk Completed';
      case EventType.safeRouteAttempted:
        return 'Safe Route Attempted';
    }
  }

  /// Get icon for event type
  IconData get icon {
    switch (type) {
      case EventType.safeRouteGenerated:
        return Icons.route;
      case EventType.riskZoneDetected:
        return Icons.warning;
      case EventType.panicModeActivated:
        return Icons.emergency;
      case EventType.panicModeDeactivated:
        return Icons.check_circle;
      case EventType.safeWordVerified:
        return Icons.verified;
      case EventType.safeWordFailed:
        return Icons.error;
      case EventType.trustedContactAlerted:
        return Icons.contact_phone;
      case EventType.safetyModeActivated:
        return Icons.shield;
      case EventType.calibrationCompleted:
        return Icons.tune;
      case EventType.locationPermissionGranted:
        return Icons.location_on;
      case EventType.locationPermissionDenied:
        return Icons.location_off;
      case EventType.appLaunched:
        return Icons.launch;
      case EventType.motionBaselineCalibrated:
        return Icons.tune;
      case EventType.motionAnomalyDetected:
        return Icons.sensors;
      case EventType.motionConcernTriggered:
        return Icons.warning_amber;
      case EventType.escalationStageChanged:
        return Icons.swap_horiz;
      case EventType.checkInPromptShown:
        return Icons.help_outline;
      case EventType.checkInResponseReceived:
        return Icons.record_voice_over;
      case EventType.countdownStarted:
        return Icons.timer;
      case EventType.countdownCancelled:
        return Icons.cancel;
      case EventType.emergencyAlertDispatched:
        return Icons.notification_important;
      case EventType.arrivalNotificationSent:
        return Icons.where_to_vote;
      case EventType.walkCompleted:
        return Icons.directions_walk;
      case EventType.safeRouteAttempted:
        return Icons.route_outlined;
    }
  }

  /// Get color for event outcome
  Color get outcomeColor {
    switch (outcome) {
      case EventOutcome.success:
        return Colors.green;
      case EventOutcome.warning:
        return Colors.orange;
      case EventOutcome.failure:
        return Colors.red;
      case EventOutcome.info:
        return Colors.blue;
    }
  }

  /// Get user-friendly outcome label
  String get outcomeLabel {
    switch (outcome) {
      case EventOutcome.success:
        return 'Success';
      case EventOutcome.warning:
        return 'Warning';
      case EventOutcome.failure:
        return 'Failed';
      case EventOutcome.info:
        return 'Info';
    }
  }
}
