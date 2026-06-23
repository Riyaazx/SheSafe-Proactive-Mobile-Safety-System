/// Crime evidence data model for B2: Crime / Risk Evidence Dataset.
///
/// Each record represents a single crime/incident report with location,
/// category, date, severity weight, and area context. Used by the
/// [CrimeEvidenceService] to produce risk scores, explanation text,
/// and evidence numbers that back route recommendations.
class CrimeEvidence {
  final double latitude;
  final double longitude;
  final CrimeCategory category;
  final DateTime date;
  final int severity; // 1-5 scale
  final String areaName;
  final String description;

  const CrimeEvidence({
    required this.latitude,
    required this.longitude,
    required this.category,
    required this.date,
    required this.severity,
    required this.areaName,
    required this.description,
  });

  /// Parse a single CSV row (after header) into a [CrimeEvidence].
  factory CrimeEvidence.fromCsvRow(List<String> fields) {
    return CrimeEvidence(
      latitude: double.parse(fields[0]),
      longitude: double.parse(fields[1]),
      category: _parseCategory(fields[2]),
      date: DateTime.parse(fields[3]),
      severity: int.parse(fields[4]),
      areaName: fields[5],
      description: fields[6],
    );
  }

  static CrimeCategory _parseCategory(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'theft':
        return CrimeCategory.theft;
      case 'assault':
        return CrimeCategory.assault;
      case 'robbery':
        return CrimeCategory.robbery;
      case 'harassment':
        return CrimeCategory.harassment;
      case 'drug_activity':
        return CrimeCategory.drugActivity;
      default:
        return CrimeCategory.other;
    }
  }

  /// Severity-weighted score (0-1). Higher = worse.
  double get severityWeight => severity / 5.0;

  /// True when the incident is within the supplied recency window.
  bool isRecent({required Duration window}) {
    return DateTime.now().difference(date) <= window;
  }

  @override
  String toString() =>
      'CrimeEvidence($category, severity=$severity, $areaName, $date)';
}

/// Crime categories relevant to personal safety.
enum CrimeCategory {
  theft(displayName: 'Theft', icon: 'shopping_bag'),
  assault(displayName: 'Assault', icon: 'warning'),
  robbery(displayName: 'Robbery', icon: 'report'),
  harassment(displayName: 'Harassment', icon: 'person_off'),
  drugActivity(displayName: 'Drug Activity', icon: 'science'),
  other(displayName: 'Other', icon: 'info');

  final String displayName;
  final String icon;
  const CrimeCategory({required this.displayName, required this.icon});
}

/// Aggregated hotspot summary for a named area.
class AreaHotspot {
  /// Human-readable area name (matches `area_name` column).
  final String areaName;

  /// Representative centre latitude.
  final double centroidLat;

  /// Representative centre longitude.
  final double centroidLon;

  /// Total number of incidents in the recency window.
  final int incidentCount;

  /// Weighted severity total (sum of each incident's severity / 5).
  final double weightedSeverity;

  /// Breakdown by category.
  final Map<CrimeCategory, int> categoryBreakdown;

  /// The most severe incident in this area.
  final int peakSeverity;

  const AreaHotspot({
    required this.areaName,
    required this.centroidLat,
    required this.centroidLon,
    required this.incidentCount,
    required this.weightedSeverity,
    required this.categoryBreakdown,
    required this.peakSeverity,
  });

  /// Risk score for this hotspot on a 0-100 scale.
  ///
  /// Combines incident density and severity into a single figure.
  /// - Incident density contributes 50 % (capped at 10 incidents → 100 %).
  /// - Weighted severity average contributes 50 %.
  double get riskScore {
    final densityFactor = (incidentCount / 10.0).clamp(0.0, 1.0);
    final severityFactor =
        incidentCount > 0 ? weightedSeverity / incidentCount : 0.0;
    return ((densityFactor * 0.5) + (severityFactor * 0.5)) * 100.0;
  }

  /// Human-readable explanation of *why* this area is flagged.
  String get explanationText {
    final buffer = StringBuffer();
    buffer.write('$areaName: $incidentCount incident');
    if (incidentCount != 1) buffer.write('s');
    buffer.write(' in the last 6 months');

    // Top category
    if (categoryBreakdown.isNotEmpty) {
      final topEntry = categoryBreakdown.entries.reduce(
          (a, b) => a.value >= b.value ? a : b);
      buffer.write(
          ' (most common: ${topEntry.key.displayName.toLowerCase()}, '
          '${topEntry.value} case${topEntry.value != 1 ? "s" : ""})');
    }

    buffer.write('. Risk score: ${riskScore.toStringAsFixed(0)}/100.');
    return buffer.toString();
  }

  /// Short evidence summary used in route "why this route" cards.
  String get evidenceSummary {
    final parts = <String>[];
    for (final entry in categoryBreakdown.entries) {
      parts.add('${entry.value} ${entry.key.displayName.toLowerCase()}');
    }
    return parts.join(', ');
  }

  @override
  String toString() =>
      'AreaHotspot($areaName, incidents=$incidentCount, risk=${riskScore.toStringAsFixed(1)})';
}

/// The output object consumed by the route recommendation backend.
///
/// Wraps a risk score, explanation text, and evidence numbers for a given
/// point or route segment.
class CrimeRiskAssessment {
  /// Overall risk score for the query point/segment (0-100).
  final double riskScore;

  /// Human-friendly explanation text.
  final String explanation;

  /// Nearby hotspots contributing to the score.
  final List<AreaHotspot> nearbyHotspots;

  /// Total incident count within the search radius.
  final int totalIncidents;

  /// Category breakdown across all nearby hotspots.
  final Map<CrimeCategory, int> overallCategoryBreakdown;

  const CrimeRiskAssessment({
    required this.riskScore,
    required this.explanation,
    required this.nearbyHotspots,
    required this.totalIncidents,
    required this.overallCategoryBreakdown,
  });

  /// Whether this location is considered high-risk.
  bool get isHighRisk => riskScore >= 60;

  /// Whether this location is considered medium-risk.
  bool get isMediumRisk => riskScore >= 30 && riskScore < 60;

  @override
  String toString() =>
      'CrimeRiskAssessment(score=$riskScore, incidents=$totalIncidents)';
}
