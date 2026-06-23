/// Post-walk AI safety report shown when Safety Mode / navigation ends.
///
/// Aggregates anomaly detection results, risk-zone avoidance, and the
/// overall route safety percentage into a single feedback card.
class WalkSafetyReport {
  /// Number of motion anomalies detected during the walk.
  final int anomaliesDetected;

  /// Descriptions of each anomaly event (e.g. "Sudden stop near Park St").
  final List<String> anomalyDescriptions;

  /// Number of high-risk zones the chosen route avoided.
  final int highRiskAreasAvoided;

  /// Names / labels of the avoided high-risk zones.
  final List<String> avoidedZoneNames;

  /// Overall route safety percentage (0–100).
  final double safetyPercentage;

  /// Walk duration in seconds.
  final int walkDurationSeconds;

  /// Planned route distance in meters (from OSRM).
  final double distanceMeters;

  /// Actual GPS-tracked distance walked in meters.
  final double actualDistanceMeters;

  /// Average walking speed in km/h (from GPS data).
  final double averageSpeedKmh;

  /// Estimated step count (from actual distance / avg stride).
  final int estimatedSteps;

  /// AI-generated one-line summary (e.g. "Your walk was safe and uneventful").
  final String aiSummary;

  /// Individual feedback lines for the report card.
  final List<WalkFeedbackItem> feedbackItems;

  const WalkSafetyReport({
    required this.anomaliesDetected,
    required this.anomalyDescriptions,
    required this.highRiskAreasAvoided,
    required this.avoidedZoneNames,
    required this.safetyPercentage,
    required this.walkDurationSeconds,
    required this.distanceMeters,
    required this.actualDistanceMeters,
    required this.averageSpeedKmh,
    required this.estimatedSteps,
    required this.aiSummary,
    required this.feedbackItems,
  });

  /// Quick check: was the walk entirely anomaly-free?
  bool get isAnomalyFree => anomaliesDetected == 0;

  /// Formatted actual distance for display.
  String get formattedActualDistance {
    if (actualDistanceMeters < 1000) {
      return '${actualDistanceMeters.round()} m';
    }
    return '${(actualDistanceMeters / 1000).toStringAsFixed(2)} km';
  }

  /// Formatted average speed for display.
  String get formattedSpeed => '${averageSpeedKmh.toStringAsFixed(1)} km/h';
}

/// A single line item in the walk safety feedback card.
class WalkFeedbackItem {
  final WalkFeedbackType type;
  final String label;
  final String detail;

  const WalkFeedbackItem({
    required this.type,
    required this.label,
    required this.detail,
  });
}

enum WalkFeedbackType {
  anomaly,
  avoidedZones,
  safetyScore,
  duration,
  distance,
  steps,
  speed,
}
