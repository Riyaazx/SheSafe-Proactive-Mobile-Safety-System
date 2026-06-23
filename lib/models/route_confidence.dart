// Data models for the Route Confidence scoring system.
//
// RouteRiskLevel  – three-tier ordinal classification
// RouteConfidenceScore – scored output from RouteConfidenceService

// ─────────────────────────────────────────────────────────────────────────────
// Risk level enum
// ─────────────────────────────────────────────────────────────────────────────

enum RouteRiskLevel {
  low,
  medium,
  high;

  /// Short human-readable label.
  String get label {
    switch (this) {
      case RouteRiskLevel.low:    return 'Low';
      case RouteRiskLevel.medium: return 'Medium';
      case RouteRiskLevel.high:   return 'High';
    }
  }

  /// Human-friendly display name shown in the UI.
  String get displayName {
    switch (this) {
      case RouteRiskLevel.low:    return 'Low Risk';
      case RouteRiskLevel.medium: return 'Moderate Risk';
      case RouteRiskLevel.high:   return 'High Risk';
    }
  }

  /// Emoji badge shown next to the display name in cards.
  String get emoji {
    switch (this) {
      case RouteRiskLevel.low:    return '🟢';
      case RouteRiskLevel.medium: return '🟠';
      case RouteRiskLevel.high:   return '🔴';
    }
  }

  /// ARGB integer colour value — pass directly to `Color(...)`.
  /// Low = green, Medium = orange, High = red.
  int get colorValue {
    switch (this) {
      case RouteRiskLevel.low:    return 0xFF2E7D62; // subtle green
      case RouteRiskLevel.medium: return 0xFFE18A2C; // subtle orange
      case RouteRiskLevel.high:   return 0xFFC3564E; // subtle red
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Route confidence score
// ─────────────────────────────────────────────────────────────────────────────

class RouteConfidenceScore {
  /// 0-100 partial score: distance to static risk-zone hotspots.
  final double hotspotScore;

  /// 0-100 partial score: risk based on the current time of day.
  final double timeOfDayScore;

  /// 0-100 partial score: crime-report density in the area.
  final double areaDensityScore;

  /// 0-100 weighted composite of the three signals above.
  final double compositeRisk;

  /// Classified risk tier derived from [compositeRisk].
  final RouteRiskLevel riskLevel;

  /// Short, user-facing explanation of the primary risk driver.
  final String explanation;

  /// Per-signal breakdown lines shown in expandable detail views.
  final List<String> breakdownLines;

  /// Hour of day (0-23) at which this score was computed.
  final int evaluatedAtHour;

  const RouteConfidenceScore({
    required this.hotspotScore,
    required this.timeOfDayScore,
    required this.areaDensityScore,
    required this.compositeRisk,
    required this.riskLevel,
    required this.explanation,
    required this.breakdownLines,
    required this.evaluatedAtHour,
  });

  /// Confidence percentage: inverse of [compositeRisk], clamped to 0–100.
  double get confidencePercent => (100.0 - compositeRisk).clamp(0.0, 100.0);

  @override
  String toString() =>
      'RouteConfidenceScore(compositeRisk: $compositeRisk, riskLevel: ${riskLevel.label})';
}
