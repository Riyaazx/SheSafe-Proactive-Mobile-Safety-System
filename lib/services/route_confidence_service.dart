import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/route_confidence.dart';
import '../models/route_option.dart';
import 'risk_engine_service.dart';
import 'crime_evidence_service.dart';

// =============================================================================
// RouteConfidenceService
// =============================================================================
//
// Computes a **Route Confidence Score** for each generated route option by
// combining three independent signals:
//
//   1. **Static Hotspot Proximity** (weight 35 %)
//      How many risk zones from `risk_zones.csv` does the route pass through
//      or near?  Uses `RiskEngineService.scoreRoute()` which already produces
//      a distance-attenuated 0-100 risk score.
//
//   2. **Time-of-Day Risk** (weight 25 %)
//      Personal-safety risk follows a well-documented diurnal curve: lowest
//      mid-morning, highest between 22:00-04:00.  The scoring function uses
//      a cosine-shifted curve peaking at 01:00 to model this.
//
//   3. **Area Crime Density** (weight 35 %)
//      Incident count and severity from `crime_evidence.csv`, surfaced via
//      `CrimeEvidenceService.assessTopHotspots()`.  This is the heaviest
//      non-geometry signal, but it no longer uses per-route scaling.
//
// The composite score (0-100) is mapped to Low / Medium / High risk.
//
// Why this matters vs competitors:
//   Life360 / Google Maps do not provide rule-based route risk scoring.
//   SheSafe combines static risk zones + temporal patterns + crime density
//   into a single confidence grade using a transparent, deterministic formula.
// =============================================================================

class RouteConfidenceService {
  // ---------------------------------------------------------------------------
  // Singleton
  // ---------------------------------------------------------------------------
  static final RouteConfidenceService _instance =
      RouteConfidenceService._internal();
  factory RouteConfidenceService() => _instance;
  RouteConfidenceService._internal();

  // ignore: unused_field
  final RiskEngineService _riskEngine = RiskEngineService();
  final CrimeEvidenceService _crimeService = CrimeEvidenceService();

  // ---------------------------------------------------------------------------
  // Weights — must sum to 1.0
  // ---------------------------------------------------------------------------
  static const double _wHotspot  = 0.45;
  static const double _wTime     = 0.20;
  static const double _wDensity  = 0.35;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Compute a [RouteConfidenceScore] for a single route.
  ///
  /// [route]       – the route option to evaluate.
  /// [crimeScale]  – optional scale factor forwarded to the crime service.
  /// [nowOverride] – injectable clock for testing; defaults to `DateTime.now()`.
  RouteConfidenceScore scoreRoute(
    RouteOption route, {
    double crimeScale = 1.0,
    DateTime? nowOverride,
  }) {
    final now = nowOverride ?? DateTime.now();

    // ── Signal 1: hotspot risk — derived from the route's actual score.
    final hotspotRisk = route.overallRiskScore;

    // ── Signal 2: time-of-day risk ────────────────────────────────────────
    final timeRisk = computeTimeOfDayRisk(now.hour, now.minute);

    // ── Signal 3: area crime density (route-path specific) ───────────────
    final crimeAssessment = route.analysis.crimeAssessment ??
      _crimeService.assessTopHotspots(topN: 5, scaleFactor: crimeScale);
    final densityRisk = crimeAssessment.riskScore;

    // ── Composite ─────────────────────────────────────────────────────────
    final composite = (hotspotRisk * _wHotspot +
                       timeRisk    * _wTime +
                       densityRisk * _wDensity)
        .clamp(0.0, 100.0);

    final level = _classifyRisk(composite);
    final explanation = _buildExplanation(
      hotspotRisk: hotspotRisk,
      timeRisk: timeRisk,
      densityRisk: densityRisk,
      composite: composite,
      level: level,
      hour: now.hour,
    );

    final breakdown = _buildBreakdown(
      hotspotRisk: hotspotRisk,
      timeRisk: timeRisk,
      densityRisk: densityRisk,
      hour: now.hour,
    );

    debugPrint(
        '📊 RouteConfidence [${route.routeId}]: '
        'hotspot=${hotspotRisk.toStringAsFixed(1)}, '
        'time=${timeRisk.toStringAsFixed(1)}, '
        'density=${densityRisk.toStringAsFixed(1)} '
        '→ composite=${composite.toStringAsFixed(1)} (${level.label})');

    return RouteConfidenceScore(
      hotspotScore: hotspotRisk,
      timeOfDayScore: timeRisk,
      areaDensityScore: densityRisk,
      compositeRisk: composite,
      riskLevel: level,
      explanation: explanation,
      breakdownLines: breakdown,
      evaluatedAtHour: now.hour,
    );
  }

  /// Batch-score all route options.  Returns a list aligned 1:1 with [routes].
  List<RouteConfidenceScore> scoreAllRoutes(
    List<RouteOption> routes, {
    DateTime? nowOverride,
  }) {
    if (routes.isEmpty) return const [];

    final risks = routes.map((r) => r.overallRiskScore).toList();
    final minRisk = risks.reduce((a, b) => a < b ? a : b);
    final maxRisk = risks.reduce((a, b) => a > b ? a : b);

    double crimeScaleForRoute(RouteOption route) {
      if ((maxRisk - minRisk).abs() < 1e-6) {
        return 0.85;
      }
      final t =
          ((route.overallRiskScore - minRisk) / (maxRisk - minRisk)).clamp(0.0, 1.0);
      return 0.65 + (t * 0.35);
    }

    return List.generate(routes.length, (i) {
      final route = routes[i];
      return scoreRoute(
        route,
        crimeScale: crimeScaleForRoute(route),
        nowOverride: nowOverride,
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Time-of-day risk model
  // ---------------------------------------------------------------------------

  /// Returns a 0-100 risk score based on the hour and minute of day.
  ///
  /// Uses a shifted cosine curve that peaks at 01:00 (most dangerous) and
  /// troughs at 13:00 (safest).  This is consistent with UK Home Office
  /// data showing violent crime peaks between 22:00–03:00.
  ///
  /// The curve: risk = 50 + 50 × cos(π × (hour − 1) / 12)
  ///   • 01:00 → 100 (peak risk)
  ///   • 07:00 → 50  (moderate)
  ///   • 13:00 → 0   (minimum)
  ///   • 19:00 → 50  (moderate, rising)
  ///
  /// Made public + static for direct unit-testing.
  static double computeTimeOfDayRisk(int hour, [int minute = 0]) {
    final fractionalHour = hour + minute / 60.0;
    // Shift so peak is at 01:00
    final theta = math.pi * (fractionalHour - 1.0) / 12.0;
    return (50.0 + 50.0 * math.cos(theta)).clamp(0.0, 100.0);
  }

  /// Human-readable period label for the current hour.
  static String timePeriodLabel(int hour) {
    if (hour >= 5 && hour < 8)   return 'Early morning';
    if (hour >= 8 && hour < 12)  return 'Morning';
    if (hour >= 12 && hour < 14) return 'Midday';
    if (hour >= 14 && hour < 17) return 'Afternoon';
    if (hour >= 17 && hour < 20) return 'Evening';
    if (hour >= 20 && hour < 23) return 'Late evening';
    return 'Night';  // 23-4
  }

  // ---------------------------------------------------------------------------
  // Classification
  // ---------------------------------------------------------------------------

  static RouteRiskLevel _classifyRisk(double composite) {
    // Conservative thresholds for the current rule-based composite score.
    if (composite < 28) return RouteRiskLevel.low;
    if (composite < 55) return RouteRiskLevel.medium;
    return RouteRiskLevel.high;
  }

  // ---------------------------------------------------------------------------
  // Explanation text
  // ---------------------------------------------------------------------------

  static String _friendlyFactor(String technical) {
    switch (technical) {
      case 'hotspot proximity': return 'nearby risk areas';
      case 'time of day': return 'the current time';
      case 'crime density': return 'recent reports in this area';
      default: return technical;
    }
  }

  static String _buildExplanation({
    required double hotspotRisk,
    required double timeRisk,
    required double densityRisk,
    required double composite,
    required RouteRiskLevel level,
    required int hour,
  }) {
    // Find the dominant factor
    final factors = {
      'hotspot proximity': hotspotRisk,
      'time of day': timeRisk,
      'crime density': densityRisk,
    };
    final dominant = factors.entries.reduce(
        (a, b) => a.value >= b.value ? a : b);

    // ignore: unused_local_variable
    final period = timePeriodLabel(hour);

    switch (level) {
      case RouteRiskLevel.low:
        return 'Quiet area, good time to walk. You\'re all set!';
      case RouteRiskLevel.medium:
        return 'Some caution needed — ${_friendlyFactor(dominant.key)} is a bit elevated.';
      case RouteRiskLevel.high:
        return 'Higher risk — ${_friendlyFactor(dominant.key)} is a concern. Consider an alternative.';
    }
  }

  static List<String> _buildBreakdown({
    required double hotspotRisk,
    required double timeRisk,
    required double densityRisk,
    required int hour,
  }) {
    final period = timePeriodLabel(hour);
    return [
      'Hotspot proximity: ${hotspotRisk.toStringAsFixed(0)}/100 '
          '(${_signalLabel(hotspotRisk)})',
      'Time of day ($period): ${timeRisk.toStringAsFixed(0)}/100 '
          '(${_signalLabel(timeRisk)})',
      'Crime density: ${densityRisk.toStringAsFixed(0)}/100 '
          '(${_signalLabel(densityRisk)})',
    ];
  }

  static String _signalLabel(double score) {
    if (score < 35) return 'low';
    if (score < 65) return 'moderate';
    return 'high';
  }
}
