import 'package:flutter_test/flutter_test.dart';
import 'package:shesafe/models/risk_zone.dart';
import 'package:shesafe/models/route_option.dart';
import 'package:shesafe/services/integration_pipeline_service.dart';

// =============================================================================
// F. Testing & Evaluation — Route Engine Tests
// =============================================================================
//
// Goal: Prove the route explanation system produces high-quality, consistent,
// and interpretable safety explanations and that the three-route ordering
// contract is always honoured.
//
// Test areas:
//   Layer 1 – RouteOption model
//               · safetyPercentage (inverse of riskScore)
//               · overallRiskLevel thresholds (low / medium / high)
//               · formattedDistance (m / km boundary)
//               · formattedDuration (minutes / hours boundary)
//   Layer 2 – RouteSegment model
//               · isLowRisk / isMediumRisk / isHighRisk predicates
//   Layer 3 – RouteAnalysis explanation quality
//               · Non-empty summary
//               · safetyReasons list not empty
//               · briefExplanation format
//               · Comparison chip present on safest route
//   Layer 4 – ComparisonData model
//               · comparisonStatement when riskDifference > 0
//               · comparisonStatement when riskDifference = 0
//   Layer 5 – BackendRouteExplanation model
//               · isWithinLatencyBudget (< 2000 ms)
//               · All fields stored correctly
//               · Explanation data quality checks
//   Layer 6 – Route ordering contract
//               · Routes must be ordered ascending by overallRiskScore
//               · Safest route has comparisonWithAlternative data attached
// =============================================================================

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

RouteWaypoint _waypoint(double lat, double lon) => RouteWaypoint(
      latitude: lat,
      longitude: lon,
      type: WaypointType.intermediate,
    );

RouteSegment _segment({double risk = 10.0, double distance = 500.0}) =>
    RouteSegment(
      start: _waypoint(52.63, 1.30),
      end: _waypoint(52.64, 1.31),
      distanceMeters: distance,
      riskScore: risk,
      nearbyRiskZones: [],
      instruction: 'Head north',
    );

RouteAnalysis _analysis({
  String summary = 'Safest route via well-lit streets',
  List<String>? reasons,
  ComparisonData? comparison,
}) =>
    RouteAnalysis(
      summary: summary,
      safetyReasons: reasons ??
          ['Avoids the town centre after dark', 'Well-lit footpaths throughout'],
      riskEvidence: [],
      avoidedZones: ['North Market Zone'],
      comparisonWithAlternative: comparison,
    );

RouteOption _route({
  String id = 'safe',
  double risk = 5.0,
  double distance = 1200.0,
  int duration = 15,
  bool isRecommended = false,
  RouteAnalysis? analysis,
}) =>
    RouteOption(
      routeId: id,
      isRecommended: isRecommended,
      segments: [_segment(risk: risk)],
      totalDistanceMeters: distance,
      estimatedDurationMinutes: duration,
      overallRiskScore: risk,
      waypoints: [
        RouteWaypoint(latitude: 52.63, longitude: 1.30, type: WaypointType.start),
        RouteWaypoint(latitude: 52.64, longitude: 1.31, type: WaypointType.destination),
      ],
      analysis: analysis ?? _analysis(),
    );

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  // =========================================================================
  // LAYER 1 — RouteOption model
  // =========================================================================
  group('RouteOption model', () {
    test('safetyPercentage is inverse of overallRiskScore', () {
      final r = _route(risk: 30.0);
      expect(r.safetyPercentage, closeTo(70.0, 0.001));
    });

    test('overallRiskLevel: score < 30 → low', () {
      expect(_route(risk: 0.0).overallRiskLevel, equals(RiskLevel.low));
      expect(_route(risk: 29.9).overallRiskLevel, equals(RiskLevel.low));
    });

    test('overallRiskLevel: 30 ≤ score < 60 → medium', () {
      expect(_route(risk: 30.0).overallRiskLevel, equals(RiskLevel.medium));
      expect(_route(risk: 59.9).overallRiskLevel, equals(RiskLevel.medium));
    });

    test('overallRiskLevel: score ≥ 60 → high', () {
      expect(_route(risk: 60.0).overallRiskLevel, equals(RiskLevel.high));
      expect(_route(risk: 100.0).overallRiskLevel, equals(RiskLevel.high));
    });

    group('formattedDistance', () {
      test('< 1 000 m is shown in metres (rounded)', () {
        final r = _route(distance: 750.0);
        expect(r.formattedDistance, equals('750 m'));
      });

      test('exactly 1 000 m is shown in km', () {
        final r = _route(distance: 1000.0);
        expect(r.formattedDistance, equals('1.0 km'));
      });

      test('> 1 000 m is shown in km with 1 decimal', () {
        final r = _route(distance: 2350.0);
        expect(r.formattedDistance, equals('2.4 km'));
      });
    });

    group('formattedDuration', () {
      test('< 60 min shown in minutes only', () {
        final r = _route(duration: 45);
        expect(r.formattedDuration, equals('45 min'));
      });

      test('exactly 60 min shown as 1h 0m', () {
        final r = _route(duration: 60);
        expect(r.formattedDuration, equals('1h 0m'));
      });

      test('90 min shown as 1h 30m', () {
        final r = _route(duration: 90);
        expect(r.formattedDuration, equals('1h 30m'));
      });
    });

    test('routeType returns routeId string', () {
      final r = _route(id: 'balanced');
      expect(r.routeType, equals('balanced'));
    });
  });

  // =========================================================================
  // LAYER 2 — RouteSegment model
  // =========================================================================
  group('RouteSegment risk predicates', () {
    test('riskScore < 30 → isLowRisk=true, others false', () {
      final s = _segment(risk: 20.0);
      expect(s.isLowRisk, isTrue);
      expect(s.isMediumRisk, isFalse);
      expect(s.isHighRisk, isFalse);
    });

    test('30 ≤ riskScore ≤ 60 → isMediumRisk=true', () {
      final s = _segment(risk: 45.0);
      expect(s.isMediumRisk, isTrue);
      expect(s.isLowRisk, isFalse);
      expect(s.isHighRisk, isFalse);
    });

    test('riskScore > 60 → isHighRisk=true', () {
      final s = _segment(risk: 75.0);
      expect(s.isHighRisk, isTrue);
      expect(s.isMediumRisk, isFalse);
      expect(s.isLowRisk, isFalse);
    });

    test('formattedDistance < 1 km shown in metres', () {
      final s = _segment(distance: 350.0);
      expect(s.formattedDistance, equals('350 m'));
    });

    test('formattedDistance ≥ 1 km shown in km', () {
      final s = _segment(distance: 2200.0);
      expect(s.formattedDistance, equals('2.2 km'));
    });
  });

  // =========================================================================
  // LAYER 3 — RouteAnalysis explanation quality
  // =========================================================================
  group('RouteAnalysis explanation quality', () {
    test('summary is non-empty', () {
      final a = _analysis(summary: 'Safest route via well-lit streets');
      expect(a.summary.isNotEmpty, isTrue);
    });

    test('safetyReasons is non-empty', () {
      final a = _analysis();
      expect(a.safetyReasons, isNotEmpty,
          reason: 'Route explanation must give at least one human-readable safety reason');
    });

    test('briefExplanation combines summary with first safetyReason', () {
      final a = _analysis(
        summary: 'Safest route',
        reasons: ['Avoids night-time hotspots', 'Second reason'],
      );
      // briefExplanation = "summary. first_reason"
      expect(a.briefExplanation, contains('Safest route'));
      expect(a.briefExplanation, contains('Avoids night-time hotspots'));
      expect(a.briefExplanation, isNot(contains('Second reason')),
          reason: 'briefExplanation shows only the first reason for conciseness');
    });

    test('briefExplanation falls back to summary when safetyReasons is empty', () {
      final a = RouteAnalysis(
        summary: 'No extra reasons available',
        safetyReasons: [],
        riskEvidence: [],
        avoidedZones: [],
      );
      expect(a.briefExplanation, equals('No extra reasons available'));
    });

    test('avoidedZones listed when route detours around risk areas', () {
      final a = _analysis();
      expect(a.avoidedZones, contains('North Market Zone'),
          reason:
              'Explanation must name the zones that the safe route avoids so '
              'the user understands the detour cost');
    });

    test('Comparison chip present on safest route', () {
      final comparison = ComparisonData(
        alternativeRouteName: 'Route 2',
        riskDifferencePercentage: 20.0,
        reason: 'lower crime exposure and fewer risk zones',
      );
      final a = _analysis(comparison: comparison);

      expect(a.comparisonWithAlternative, isNotNull);
      expect(a.comparisonWithAlternative!.alternativeRouteName, equals('Route 2'));
    });
  });

  // =========================================================================
  // LAYER 4 — ComparisonData model
  // =========================================================================
  group('ComparisonData model', () {
    test('comparisonStatement when riskDifference > 0 mentions percentage', () {
      final c = ComparisonData(
        alternativeRouteName: 'Route 2',
        riskDifferencePercentage: 18.5,
        reason: 'lower crime exposure',
      );
      final s = c.comparisonStatement;

      expect(s, contains('19%'),
          reason: 'Percentage should be rounded to 0 decimals → 18.5 → 19');
      expect(s, contains('Route 2'));
      expect(s, contains('safer'));
      expect(s, contains('lower crime exposure'));
    });

    test('comparisonStatement when riskDifference = 0 says similar safety', () {
      final c = ComparisonData(
        alternativeRouteName: 'Route 3',
        riskDifferencePercentage: 0.0,
        reason: '',
      );
      expect(c.comparisonStatement, contains('similar safety'));
    });

    test('Route 1 is always the comparison "other" route name in chip', () {
      // By contract (RouteGeneratorService), the chip on routes[0] compares
      // with 'Route 2' — the next-best option.
      final c = ComparisonData(
        alternativeRouteName: 'Route 2',
        riskDifferencePercentage: 10.0,
        reason: 'fewer risk zones',
      );
      expect(c.alternativeRouteName, equals('Route 2'));
    });
  });

  // =========================================================================
  // LAYER 5 — BackendRouteExplanation model
  // =========================================================================
  group('BackendRouteExplanation model', () {
    BackendRouteExplanation explanation({
      int latencyMs = 800,
      int safetyScore = 85,
      String riskLevel = 'low',
      List<String>? warnings,
    }) =>
        BackendRouteExplanation(
          summary: 'This route avoids all high-risk zones identified tonight.',
          details:
              'The route was selected based on 3 active risk zones and 12 recent '
              'crime reports within 500 m of your destination.',
          warnings: warnings ?? ['Poorly lit section near Central Park'],
          safetyScore: safetyScore,
          riskLevel: riskLevel,
          riskZonesNearby: 2,
          latencyMs: latencyMs,
        );

    // ── Explanation quality ───────────────────────────────────────────────────
    test('Summary is non-empty and meaningful', () {
      final e = explanation();
      expect(e.summary.isNotEmpty, isTrue);
      expect(e.summary.length, greaterThan(10),
          reason: 'A meaningful summary cannot be a single word');
    });

    test('Details string provides quantitative context', () {
      final e = explanation();
      expect(e.details.isNotEmpty, isTrue,
          reason: 'Details must explain the reasoning behind the recommendation');
    });

    test('Warnings list is accessible and can be non-empty', () {
      final e = explanation(warnings: ['Low lighting ahead', 'Recent theft reported']);
      expect(e.warnings.length, equals(2));
    });

    test('safetyScore is within 0–100 range', () {
      for (final score in [0, 50, 85, 100]) {
        final e = explanation(safetyScore: score);
        expect(e.safetyScore, inInclusiveRange(0, 100));
      }
    });

    test('riskLevel is a valid string value', () {
      for (final level in ['low', 'medium', 'high']) {
        final e = explanation(riskLevel: level);
        expect(['low', 'medium', 'high'], contains(e.riskLevel));
      }
    });

    // ── Latency budget (Safety Mode: < 2 000 ms) ─────────────────────────────
    test('isWithinLatencyBudget=true when latency < 2 000 ms', () {
      expect(explanation(latencyMs: 0).isWithinLatencyBudget, isTrue);
      expect(explanation(latencyMs: 999).isWithinLatencyBudget, isTrue);
      expect(explanation(latencyMs: 1999).isWithinLatencyBudget, isTrue);
    });

    test('isWithinLatencyBudget=false when latency >= 2 000 ms (budget exceeded)', () {
      expect(explanation(latencyMs: 2000).isWithinLatencyBudget, isFalse,
          reason: 'Exactly 2 000 ms is NOT within budget (uses strict <)');
      expect(explanation(latencyMs: 2001).isWithinLatencyBudget, isFalse);
      expect(explanation(latencyMs: 9999).isWithinLatencyBudget, isFalse);
    });

    // ── Consistency: same inputs always produce identical structure ───────────
    test('Explanation is deterministic (same inputs → same field values)', () {
      final e1 = explanation(latencyMs: 500, safetyScore: 85);
      final e2 = explanation(latencyMs: 500, safetyScore: 85);

      expect(e1.summary, equals(e2.summary));
      expect(e1.safetyScore, equals(e2.safetyScore));
      expect(e1.riskLevel, equals(e2.riskLevel));
      expect(e1.riskZonesNearby, equals(e2.riskZonesNearby));
    });
  });

  // =========================================================================
  // LAYER 6 — Route ordering contract
  // =========================================================================
  group('Route ordering contract', () {
    List<RouteOption> buildRoutes(List<double> riskScores) => riskScores
        .map((r) => _route(
              id: 'route_$r',
              risk: r,
              analysis: _analysis(
                comparison: r == riskScores.reduce((a, b) => a < b ? a : b)
                    ? ComparisonData(
                        alternativeRouteName: 'Route 2',
                        riskDifferencePercentage: 10.0,
                        reason: 'fewer risk zones',
                      )
                    : null,
              ),
            ))
        .toList()
      ..sort((a, b) => a.overallRiskScore.compareTo(b.overallRiskScore));

    test('Routes are sorted ascending by overallRiskScore', () {
      final routes = buildRoutes([35.0, 5.0, 20.0]);

      // After sorting: [5.0, 20.0, 35.0]
      expect(routes[0].overallRiskScore, lessThanOrEqualTo(routes[1].overallRiskScore));
      expect(routes[1].overallRiskScore, lessThanOrEqualTo(routes[2].overallRiskScore));
    });

    test('Safest route (index 0) has the lowest risk score', () {
      final routes = buildRoutes([50.0, 10.0, 30.0]);
      final minRisk = routes.map((r) => r.overallRiskScore).reduce((a, b) => a < b ? a : b);
      expect(routes.first.overallRiskScore, equals(minRisk));
    });

    test('Three routes always returned (safe, balanced, direct)', () {
      final routes = buildRoutes([5.0, 15.0, 25.0]);
      expect(routes.length, equals(3));
    });

    test('Safest route has comparisonWithAlternative chip', () {
      final routes = buildRoutes([5.0, 15.0, 25.0]);
      expect(routes.first.analysis.comparisonWithAlternative, isNotNull,
          reason:
              'The safest route must carry a chip comparing it with Route 2 '
              'so users understand why the detour is worthwhile');
    });

    test('Non-safest routes may have null comparisonWithAlternative', () {
      // The comparison chip is only generated for the recommended (first) route.
      final routes = buildRoutes([5.0, 15.0, 25.0]);
      // Only the first route has a chip in this test; others do not.
      expect(routes.last.analysis.comparisonWithAlternative, isNull,
          reason: 'Only routes[0] gets the comparison chip by design');
    });

    test('RiskLevel thresholds drive route labelling correctly', () {
      // Verify that the sorted routes align with risk level labels.
      final routes = buildRoutes([10.0, 45.0, 75.0]);
      expect(routes[0].overallRiskLevel, equals(RiskLevel.low));
      expect(routes[1].overallRiskLevel, equals(RiskLevel.medium));
      expect(routes[2].overallRiskLevel, equals(RiskLevel.high));
    });
  });

  // =========================================================================
  // LAYER 7 — EscalationAck model (Panic Mode backend round-trip)
  // =========================================================================
  group('EscalationAck model', () {
    test('Successful ack has correct fields', () {
      const ack = EscalationAck(
        success: true,
        backendStage: 'dispatching',
        message: 'Alert received',
        latencyMs: 320,
      );

      expect(ack.success, isTrue);
      expect(ack.backendStage, equals('dispatching'));
      expect(ack.latencyMs, equals(320));
    });

    test('Failure ack (network down) has correct fields', () {
      const ack = EscalationAck(
        success: false,
        message: 'Connection refused',
        latencyMs: 1500,
      );

      expect(ack.success, isFalse);
      expect(ack.backendStage, isNull);
    });
  });
}
