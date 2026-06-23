import '../models/walk_safety_report.dart';
import '../models/route_option.dart';
import '../models/risk_zone.dart';

/// Computes a [WalkSafetyReport] from the data collected during a
/// Safety-Mode navigation session.
///
/// Inputs:
///   - The selected [RouteOption] (contains segments, risk zones, analysis).
///   - The number of motion anomalies detected during the walk.
///   - Walk start time (to compute duration).
///   - Actual GPS-tracked distance walked.
///
/// The service is stateless — call [generateReport] at walk end.
class WalkSafetyScoreService {
  /// Average human stride length in meters (used for step estimation).
  static const double _avgStrideLengthMeters = 0.762;

  /// Generate the post-walk safety report.
  ///
  /// [route]              – the route the user navigated.
  /// [anomalyCount]       – motion anomalies detected during the session.
  /// [anomalyDescriptions] – human-readable labels for each anomaly.
  /// [walkStartTime]      – when navigation was started.
  /// [walkEndTime]        – exact moment the user ended navigation.
  /// [actualDistanceMeters] – real GPS-tracked distance (0 if unavailable).
  WalkSafetyReport generateReport({
    required RouteOption route,
    required int anomalyCount,
    List<String> anomalyDescriptions = const [],
    required DateTime walkStartTime,
    required DateTime walkEndTime,
    double actualDistanceMeters = 0,
  }) {
    final walkDurationSeconds =
        walkEndTime.difference(walkStartTime).inSeconds.clamp(1, 999999);

    // ── Distance: ONLY use real GPS data for steps / speed ─────────────────
    // If GPS tracked < 10 m it's just drift — treat as 0 actual movement.
    final gpsDistance = actualDistanceMeters >= 10 ? actualDistanceMeters : 0.0;
    final hasGpsData = gpsDistance > 0;

    // Steps & speed are derived ONLY from GPS-tracked distance — never from
    // the planned route distance.  This means if the user didn't physically
    // walk (e.g. clicked through navigation for testing), steps = 0.
    final estimatedSteps = hasGpsData
        ? (gpsDistance / _avgStrideLengthMeters).round()
        : 0;
    final durationHours = walkDurationSeconds / 3600.0;
    final avgSpeedKmh = (hasGpsData && durationHours > 0)
        ? (gpsDistance / 1000.0) / durationHours
        : 0.0;

    // ── Avoided high-risk zones ────────────────────────────────────────────
    // The route analysis already lists zone names the algorithm avoided.
    final avoidedZones = route.analysis.avoidedZones;
    final highRiskAvoided = avoidedZones.length;

    // Also count high-risk segments the route intentionally routed around.
    final avoidedHighRiskEvidence = route.analysis.riskEvidence
        .where((e) =>
            !e.routePassesThrough && e.riskLevel == RiskLevel.high)
        .toList();
    final totalAvoided = highRiskAvoided + avoidedHighRiskEvidence.length;
    final avoidedNames = [
      ...avoidedZones,
      ...avoidedHighRiskEvidence.map((e) => e.zoneName),
    ];

    // ── Safety percentage ──────────────────────────────────────────────────
    // Blend route's own safety score with a small penalty per anomaly.
    final rawSafety = route.safetyPercentage;
    final anomalyPenalty = (anomalyCount * 5.0).clamp(0.0, 30.0);
    final adjustedSafety = (rawSafety - anomalyPenalty).clamp(0.0, 100.0);

    // ── AI summary sentence ────────────────────────────────────────────────
    final summary = _buildSummary(
      anomalyCount: anomalyCount,
      avoided: totalAvoided,
      safety: adjustedSafety,
      actualDistanceMeters: gpsDistance,
      plannedDistanceMeters: route.totalDistanceMeters,
      durationSeconds: walkDurationSeconds,
      steps: estimatedSteps,
      hasGpsData: hasGpsData,
    );

    // ── Feedback items (safety-focused only) ───────────────────────────────
    // Distance / steps / speed / duration live in the stats row at the top
    // of the summary screen — we only need safety-related cards here.
    final items = <WalkFeedbackItem>[
      // 1. Anomaly line
      WalkFeedbackItem(
        type: WalkFeedbackType.anomaly,
        label: anomalyCount == 0
            ? 'No anomalies detected'
            : '$anomalyCount anomal${anomalyCount == 1 ? 'y' : 'ies'} detected',
        detail: anomalyCount == 0
            ? 'Your motion pattern remained normal throughout the walk.'
            : anomalyDescriptions.isNotEmpty
                ? anomalyDescriptions.join('; ')
                : 'Unusual motion patterns were flagged during your walk.',
      ),

      // 2. Avoided zones line
      WalkFeedbackItem(
        type: WalkFeedbackType.avoidedZones,
        label: totalAvoided == 0
            ? 'No high-risk areas on route'
            : '$totalAvoided high-risk area${totalAvoided == 1 ? '' : 's'} avoided',
        detail: avoidedNames.isNotEmpty
            ? 'Avoided: ${avoidedNames.join(', ')}'
            : 'The chosen route steered clear of known danger zones.',
      ),

      // 3. Safety score line
      WalkFeedbackItem(
        type: WalkFeedbackType.safetyScore,
        label: 'Route was ${adjustedSafety.round()}% safe',
        detail: _safetyDetail(adjustedSafety),
      ),

      // 4. Duration line
      WalkFeedbackItem(
        type: WalkFeedbackType.duration,
        label: '${_formatDuration(walkDurationSeconds)} walk completed',
        detail: 'Total time from navigation start to arrival.',
      ),
    ];

    return WalkSafetyReport(
      anomaliesDetected: anomalyCount,
      anomalyDescriptions: anomalyDescriptions,
      highRiskAreasAvoided: totalAvoided,
      avoidedZoneNames: avoidedNames,
      safetyPercentage: adjustedSafety,
      walkDurationSeconds: walkDurationSeconds,
      distanceMeters: route.totalDistanceMeters,
      actualDistanceMeters: gpsDistance,
      averageSpeedKmh: avgSpeedKmh,
      estimatedSteps: estimatedSteps,
      aiSummary: summary,
      feedbackItems: items,
    );
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  String _buildSummary({
    required int anomalyCount,
    required int avoided,
    required double safety,
    required double actualDistanceMeters,
    required double plannedDistanceMeters,
    required int durationSeconds,
    required int steps,
    required bool hasGpsData,
  }) {
    final durStr = _formatDuration(durationSeconds);

    // Build a distance phrase based on what data we actually have
    String distPhrase;
    if (hasGpsData) {
      final distStr = actualDistanceMeters < 1000
          ? '${actualDistanceMeters.round()} m'
          : '${(actualDistanceMeters / 1000).toStringAsFixed(2)} km';
      distPhrase = '$distStr in $durStr (~$steps steps)';
    } else {
      final plannedStr = plannedDistanceMeters < 1000
          ? '${plannedDistanceMeters.round()} m'
          : '${(plannedDistanceMeters / 1000).toStringAsFixed(1)} km';
      distPhrase = '$plannedStr route completed in $durStr';
    }

    if (anomalyCount == 0 && safety >= 80) {
      return 'Great walk! $distPhrase with no safety concerns.';
    }
    if (anomalyCount == 0 && safety >= 50) {
      return 'Walk complete \u2014 $distPhrase. Some moderate-risk areas were nearby but you stayed safe.';
    }
    if (anomalyCount == 0 && safety < 50) {
      return 'Walk complete \u2014 $distPhrase. The route crossed higher-risk areas; consider a different path next time.';
    }
    if (anomalyCount > 0 && safety >= 60) {
      return '$distPhrase. $anomalyCount motion anomal${anomalyCount == 1 ? 'y was' : 'ies were'} detected, but overall safety was acceptable.';
    }
    return '$distPhrase with $anomalyCount anomal${anomalyCount == 1 ? 'y' : 'ies'} \u2014 stay alert and consider safer alternatives.';
  }

  /// Formats seconds into a human-friendly string:
  ///   < 60 s  → "20s"
  ///   < 3600  → "5m 30s"
  ///   else    → "1h 12m"
  String _formatDuration(int totalSeconds) {
    if (totalSeconds < 60) return '${totalSeconds}s';
    final m = totalSeconds ~/ 60;
    final s = totalSeconds % 60;
    if (m < 60) return s > 0 ? '${m}m ${s}s' : '${m}m';
    final h = m ~/ 60;
    final rm = m % 60;
    return rm > 0 ? '${h}h ${rm}m' : '${h}h';
  }

  String _safetyDetail(double safety) {
    if (safety >= 80) return 'Excellent — low risk throughout.';
    if (safety >= 60) return 'Good — minor risk areas present.';
    if (safety >= 40) return 'Moderate — some caution was needed.';
    return 'Below average — consider a safer route next time.';
  }

  // ignore: unused_element
  String _speedDetail(double kmh) {
    if (kmh < 2.0) return 'Very slow pace — you may have paused during the walk.';
    if (kmh < 4.0) return 'Leisurely stroll — relaxed walking pace.';
    if (kmh < 5.5) return 'Normal walking pace — typical for an adult pedestrian.';
    if (kmh < 7.0) return 'Brisk walk — faster than average walking speed.';
    return 'Very fast pace — close to jogging speed.';
  }
}
