import 'package:flutter_test/flutter_test.dart';
import 'package:shesafe/models/walk_safety_report.dart';
import 'package:shesafe/models/route_option.dart';
import 'package:shesafe/models/risk_zone.dart';
import 'package:shesafe/services/walk_safety_service.dart';

// =============================================================================
// Walk Safety Score Service Tests
// =============================================================================
//
// Validates the post-walk AI safety report generation:
//
//   1. Report fields are populated correctly
//   2. Anomaly-free walks produce correct feedback
//   3. Anomalies reduce safety percentage
//   4. Avoided zones are counted from analysis
//   5. AI summary varies by scenario
//   6. Edge cases (zero duration, high anomaly counts)
// =============================================================================

/// Builds a minimal [RouteOption] for testing.
RouteOption _testRoute({
  double overallRisk = 20.0,
  List<String> avoidedZones = const ['Dark Alley', 'Unlit Park'],
  List<RiskEvidence> riskEvidence = const [],
}) {
  return RouteOption(
    routeId: 'test_safest',
    isRecommended: false,
    segments: [
      RouteSegment(
        start: RouteWaypoint(
            latitude: 52.41, longitude: -1.51, type: WaypointType.start),
        end: RouteWaypoint(
            latitude: 52.42, longitude: -1.52, type: WaypointType.destination),
        distanceMeters: 800,
        riskScore: overallRisk,
        nearbyRiskZones: [],
        instruction: 'Head north on High Street',
      ),
    ],
    totalDistanceMeters: 800,
    estimatedDurationMinutes: 10,
    overallRiskScore: overallRisk,
    analysis: RouteAnalysis(
      summary: 'Safest route via well-lit streets',
      safetyReasons: ['Well-lit path', 'CCTV coverage'],
      riskEvidence: riskEvidence,
      avoidedZones: avoidedZones,
    ),
    waypoints: [
      RouteWaypoint(
          latitude: 52.41, longitude: -1.51, type: WaypointType.start),
      RouteWaypoint(
          latitude: 52.42, longitude: -1.52, type: WaypointType.destination),
    ],
  );
}

void main() {
  final service = WalkSafetyScoreService();
  final now = DateTime.now();

  // ═══════════════════════════════════════════════════════════════════════════
  // Basic report generation
  // ═══════════════════════════════════════════════════════════════════════════
  group('WalkSafetyScoreService — basic report', () {
    test('generates report with correct fields for anomaly-free walk', () {
      final report = service.generateReport(
        route: _testRoute(),
        anomalyCount: 0,
        walkStartTime: now.subtract(const Duration(minutes: 15)),
        walkEndTime: now,
      );

      expect(report.anomaliesDetected, 0);
      expect(report.isAnomalyFree, isTrue);
      expect(report.highRiskAreasAvoided, greaterThanOrEqualTo(2));
      expect(report.safetyPercentage, 80.0); // 100 - 20 risk = 80%
      expect(report.feedbackItems, hasLength(4));
    });

    test('feedback item labels match expected text', () {
      final report = service.generateReport(
        route: _testRoute(),
        anomalyCount: 0,
        walkStartTime: now.subtract(const Duration(minutes: 10)),
        walkEndTime: now,
      );

      expect(report.feedbackItems[0].label, 'No anomalies detected');
      expect(report.feedbackItems[1].label, contains('high-risk area'));
      expect(report.feedbackItems[2].label, contains('% safe'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Anomaly handling
  // ═══════════════════════════════════════════════════════════════════════════
  group('WalkSafetyScoreService — anomalies', () {
    test('anomalies reduce safety percentage by 5pp each', () {
      final noAnomaly = service.generateReport(
        route: _testRoute(overallRisk: 20),
        anomalyCount: 0,
        walkStartTime: now.subtract(const Duration(minutes: 10)),
        walkEndTime: now,
      );
      final twoAnomalies = service.generateReport(
        route: _testRoute(overallRisk: 20),
        anomalyCount: 2,
        walkStartTime: now.subtract(const Duration(minutes: 10)),
        walkEndTime: now,
      );

      expect(noAnomaly.safetyPercentage, 80.0);
      expect(twoAnomalies.safetyPercentage, 70.0); // 80 - 10 = 70
    });

    test('anomaly penalty capped at 30pp', () {
      final report = service.generateReport(
        route: _testRoute(overallRisk: 10),
        anomalyCount: 10, // 10 * 5 = 50, but capped at 30
        walkStartTime: now.subtract(const Duration(minutes: 20)),
        walkEndTime: now,
      );

      expect(report.safetyPercentage, 60.0); // 90 - 30 = 60
    });

    test('safety percentage cannot go below 0', () {
      final report = service.generateReport(
        route: _testRoute(overallRisk: 90), // safety = 10%
        anomalyCount: 6, // penalty = 30
        walkStartTime: now.subtract(const Duration(minutes: 5)),
        walkEndTime: now,
      );

      expect(report.safetyPercentage, 0.0); // 10 - 30 = -20 → clamped to 0
    });

    test('anomaly descriptions appear in feedback detail', () {
      final report = service.generateReport(
        route: _testRoute(),
        anomalyCount: 1,
        anomalyDescriptions: ['Sudden stop near Park St'],
        walkStartTime: now.subtract(const Duration(minutes: 5)),
        walkEndTime: now,
      );

      expect(report.feedbackItems[0].detail, contains('Sudden stop'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Avoided zones
  // ═══════════════════════════════════════════════════════════════════════════
  group('WalkSafetyScoreService — avoided zones', () {
    test('counts avoided zones from analysis', () {
      final report = service.generateReport(
        route: _testRoute(avoidedZones: ['Zone A', 'Zone B', 'Zone C']),
        anomalyCount: 0,
        walkStartTime: now.subtract(const Duration(minutes: 10)),
        walkEndTime: now,
      );

      expect(report.highRiskAreasAvoided, greaterThanOrEqualTo(3));
      expect(report.avoidedZoneNames, contains('Zone A'));
    });

    test('counts nearby-but-not-passed-through high-risk evidence', () {
      final report = service.generateReport(
        route: _testRoute(
          avoidedZones: [],
          riskEvidence: [
            RiskEvidence(
              zoneName: 'Danger Alley',
              riskLevel: RiskLevel.high,
              description: 'High crime area',
              distanceFromRouteMeters: 200,
              routePassesThrough: false,
            ),
          ],
        ),
        anomalyCount: 0,
        walkStartTime: now.subtract(const Duration(minutes: 8)),
        walkEndTime: now,
      );

      expect(report.highRiskAreasAvoided, 1);
      expect(report.avoidedZoneNames, contains('Danger Alley'));
    });

    test('ignores zones the route passes through', () {
      final report = service.generateReport(
        route: _testRoute(
          avoidedZones: [],
          riskEvidence: [
            RiskEvidence(
              zoneName: 'Passed Zone',
              riskLevel: RiskLevel.high,
              description: 'Route goes through here',
              distanceFromRouteMeters: 0,
              routePassesThrough: true, // NOT avoided
            ),
          ],
        ),
        anomalyCount: 0,
        walkStartTime: now.subtract(const Duration(minutes: 8)),
        walkEndTime: now,
      );

      expect(report.highRiskAreasAvoided, 0);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // AI summary variation
  // ═══════════════════════════════════════════════════════════════════════════
  group('WalkSafetyScoreService — AI summary', () {
    test('safe anomaly-free walk gets positive summary', () {
      final report = service.generateReport(
        route: _testRoute(overallRisk: 15),
        anomalyCount: 0,
        walkStartTime: now.subtract(const Duration(minutes: 10)),
        walkEndTime: now,
      );

      expect(report.aiSummary, contains('Great walk'));
    });

    test('risky walk with anomalies gets cautionary summary', () {
      final report = service.generateReport(
        route: _testRoute(overallRisk: 60),
        anomalyCount: 2,
        walkStartTime: now.subtract(const Duration(minutes: 10)),
        walkEndTime: now,
      );

      expect(report.aiSummary, contains('anomal'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Duration accuracy
  // ═══════════════════════════════════════════════════════════════════════════
  group('WalkSafetyScoreService — duration', () {
    test('short walk shows seconds, not minutes', () {
      final start = now.subtract(const Duration(seconds: 20));
      final report = service.generateReport(
        route: _testRoute(),
        anomalyCount: 0,
        walkStartTime: start,
        walkEndTime: now,
      );

      // walkDurationSeconds should be exactly 20
      expect(report.walkDurationSeconds, 20);
      // Feedback label should show "20s walk completed" not "1min"
      final durationItem = report.feedbackItems
          .firstWhere((i) => i.type == WalkFeedbackType.duration);
      expect(durationItem.label, contains('s walk completed'));
      // Should NOT contain a minutes component like "2m" or "1h"
      expect(durationItem.label, isNot(matches(RegExp(r'\d+m'))));
    });

    test('walk over 1 minute shows minutes and seconds', () {
      final start = now.subtract(const Duration(minutes: 2, seconds: 30));
      final report = service.generateReport(
        route: _testRoute(),
        anomalyCount: 0,
        walkStartTime: start,
        walkEndTime: now,
      );

      expect(report.walkDurationSeconds, 150);
      final durationItem = report.feedbackItems
          .firstWhere((i) => i.type == WalkFeedbackType.duration);
      expect(durationItem.label, contains('m'));
      expect(durationItem.label, contains('s'));
    });

    test('walk over 1 hour shows hours and minutes', () {
      final start = now.subtract(const Duration(hours: 1, minutes: 15));
      final report = service.generateReport(
        route: _testRoute(),
        anomalyCount: 0,
        walkStartTime: start,
        walkEndTime: now,
      );

      final durationItem = report.feedbackItems
          .firstWhere((i) => i.type == WalkFeedbackType.duration);
      expect(durationItem.label, contains('h'));
      expect(durationItem.label, contains('m'));
    });
  });
}
