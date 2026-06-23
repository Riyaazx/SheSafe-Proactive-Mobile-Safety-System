/// Trigger types that can initiate or escalate a panic alert
enum EscalationTrigger {
  /// User pressed the manual SOS button
  manualSOS,

  /// Accelerometer / motion anomaly spike detected during monitoring
  motionAnomaly,

  /// Safe word recognised by speech-to-text (final confirmation of distress)
  safeWord,

  /// User did not respond to the "Are you okay?" check-in prompt
  nonResponse,

  /// User pressed "No – Send Help" on the check-in prompt
  userRequestedHelp,

  /// User cancelled from any stage
  userCancelled,

  /// User confirmed they are safe during check-in
  userConfirmedOkay,
}

/// Human-readable label for each trigger
extension EscalationTriggerLabel on EscalationTrigger {
  String get label {
    switch (this) {
      case EscalationTrigger.manualSOS:
        return 'Manual SOS';
      case EscalationTrigger.motionAnomaly:
        return 'Motion Anomaly';
      case EscalationTrigger.safeWord:
        return 'Safe Word Detected';
      case EscalationTrigger.nonResponse:
        return 'No Response (Timeout)';
      case EscalationTrigger.userRequestedHelp:
        return 'User Requested Help';
      case EscalationTrigger.userCancelled:
        return 'User Cancelled';
      case EscalationTrigger.userConfirmedOkay:
        return 'User Confirmed Safe';
    }
  }
}

/// Metadata bundle attached to every dispatched emergency alert.
///
/// Contains the full audit trail of what triggered the alert, the user's GPS
/// position at dispatch time, motion-anomaly confidence values, and the
/// complete trigger history so that a recipient (or later analysis) can
/// reconstruct the escalation path.
class AlertMetadata {
  /// Unique session ID for this panic-mode activation
  final String sessionId;

  /// Exact UTC wall-clock time the alert was dispatched
  final DateTime timestamp;

  /// Primary trigger that caused the final alert to be sent
  final EscalationTrigger triggerType;

  /// Latitude at dispatch time (null if location unavailable)
  final double? latitude;

  /// Longitude at dispatch time (null if location unavailable)
  final double? longitude;

  /// Human-readable description of the anomaly (if motion triggered)
  final String? anomalyDescription;

  /// Anomaly score at the time of the triggering event (0.0–1.0)
  final double? anomalyScore;

  /// How many consecutive anomalous motion windows were detected
  final int? anomalyConsecutiveWindows;

  /// Speech-to-text confidence for the safe-word match (0.0–1.0)
  final double? safeWordConfidence;

  /// Whether the safe word was matched via API or local fallback
  final bool? safeWordMatchedViaApi;

  /// Ordered list of all triggers that fired during the session,
  /// e.g. [motionAnomaly, nonResponse] → dispatch via timeout
  final List<EscalationTrigger> triggerHistory;

  const AlertMetadata({
    required this.sessionId,
    required this.timestamp,
    required this.triggerType,
    this.latitude,
    this.longitude,
    this.anomalyDescription,
    this.anomalyScore,
    this.anomalyConsecutiveWindows,
    this.safeWordConfidence,
    this.safeWordMatchedViaApi,
    required this.triggerHistory,
  });

  /// Whether we have a valid GPS fix
  bool get hasLocation => latitude != null && longitude != null;

  /// Google Maps deep-link for this location
  String? get googleMapsUrl => hasLocation
      ? 'https://maps.google.com/?q=$latitude,$longitude'
      : null;

  /// Convenience: formatted location string
  String get locationString => hasLocation
      ? '${latitude!.toStringAsFixed(6)}, ${longitude!.toStringAsFixed(6)}'
      : 'Location unavailable';

  Map<String, dynamic> toJson() {
    return {
      'sessionId': sessionId,
      'timestamp': timestamp.toIso8601String(),
      'triggerType': triggerType.name,
      'latitude': latitude,
      'longitude': longitude,
      'anomalyDescription': anomalyDescription,
      'anomalyScore': anomalyScore,
      'anomalyConsecutiveWindows': anomalyConsecutiveWindows,
      'safeWordConfidence': safeWordConfidence,
      'safeWordMatchedViaApi': safeWordMatchedViaApi,
      'triggerHistory': triggerHistory.map((t) => t.name).toList(),
    };
  }

  @override
  String toString() =>
      'AlertMetadata(session=$sessionId, trigger=${triggerType.label}, '
      'location=$locationString, triggers=${triggerHistory.map((t) => t.label).join(" → ")})';
}
