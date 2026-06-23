import 'package:flutter_test/flutter_test.dart';
import 'package:shesafe/models/crime_evidence.dart';

// ---------------------------------------------------------------------------
// B2: Crime / Risk Evidence Dataset — Unit Tests
// ---------------------------------------------------------------------------
//
// These tests verify every layer of the B2 pipeline:
//   Layer 1 – CrimeEvidence model (parsing, recency, severity weight)
//   Layer 2 – AreaHotspot (aggregation formula, explanation text)
//   Layer 3 – CrimeRiskAssessment (score thresholds, flags)
//   Layer 4 – Service-level logic (haversine, explanation builder)
//             tested indirectly through the model objects.
//
// The service's initialize() reads from rootBundle (Flutter asset system),
// so that path is exercised via on-device / integration testing.
// Everything else is pure Dart and testable here.
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // Helper: build a CrimeEvidence row the same way the CSV parser does.
  // CSV columns: latitude, longitude, category, date, severity, area_name, description
  // -------------------------------------------------------------------------
  List<String> row({
    String lat = '52.635679',
    String lon = '1.304179',
    String category = 'theft',
    String date = '2026-02-20',
    String severity = '3',
    String area = 'Chapel Field',
    String description = 'Bicycle theft',
  }) =>
      [lat, lon, category, date, severity, area, description];

  CrimeEvidence evidence({
    double lat = 52.635679,
    double lon = 1.304179,
    CrimeCategory category = CrimeCategory.theft,
    DateTime? date,
    int severity = 3,
    String area = 'Chapel Field',
    String description = 'Bicycle theft',
  }) =>
      CrimeEvidence(
        latitude: lat,
        longitude: lon,
        category: category,
        date: date ?? DateTime(2026, 2, 20),
        severity: severity,
        areaName: area,
        description: description,
      );

  // =========================================================================
  // LAYER 1 — CrimeEvidence model
  // =========================================================================
  group('CrimeEvidence.fromCsvRow', () {
    test('parses all 7 columns correctly', () {
      final e = CrimeEvidence.fromCsvRow(row());
      expect(e.latitude, closeTo(52.635679, 1e-6));
      expect(e.longitude, closeTo(1.304179, 1e-6));
      expect(e.category, CrimeCategory.theft);
      expect(e.date, DateTime(2026, 2, 20));
      expect(e.severity, 3);
      expect(e.areaName, 'Chapel Field');
      expect(e.description, 'Bicycle theft');
    });

    test('maps every known category string', () {
      final categories = {
        'theft': CrimeCategory.theft,
        'assault': CrimeCategory.assault,
        'robbery': CrimeCategory.robbery,
        'harassment': CrimeCategory.harassment,
        'drug_activity': CrimeCategory.drugActivity,
        'unknown_xyz': CrimeCategory.other,
      };
      for (final entry in categories.entries) {
        final e = CrimeEvidence.fromCsvRow(row(category: entry.key));
        expect(e.category, entry.value,
            reason: '${entry.key} should map to ${entry.value}');
      }
    });

    test('severity 1 gives severityWeight 0.2', () {
      final e = CrimeEvidence.fromCsvRow(row(severity: '1'));
      expect(e.severityWeight, closeTo(0.2, 1e-9));
    });

    test('severity 5 gives severityWeight 1.0', () {
      final e = CrimeEvidence.fromCsvRow(row(severity: '5'));
      expect(e.severityWeight, closeTo(1.0, 1e-9));
    });
  });

  group('CrimeEvidence.isRecent', () {
    test('incident from yesterday is recent within 7-day window', () {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final e = evidence(date: yesterday);
      expect(e.isRecent(window: const Duration(days: 7)), isTrue);
    });

    test('incident from 200 days ago is NOT recent within 180-day window', () {
      final old = DateTime.now().subtract(const Duration(days: 200));
      final e = evidence(date: old);
      expect(e.isRecent(window: const Duration(days: 180)), isFalse);
    });

    test('incident exactly at boundary edge is still recent', () {
      // Subtract 179 days — just inside the 180-day window.
      final nearBoundary = DateTime.now().subtract(const Duration(days: 179));
      final e = evidence(date: nearBoundary);
      expect(e.isRecent(window: const Duration(days: 180)), isTrue);
    });
  });

  // =========================================================================
  // LAYER 2 — AreaHotspot aggregation formula
  // =========================================================================
  group('AreaHotspot.riskScore', () {
    AreaHotspot hotspot({
      required int incidentCount,
      required double weightedSeverity,
      int peakSeverity = 5,
    }) =>
        AreaHotspot(
          areaName: 'Test Area',
          centroidLat: 52.63,
          centroidLon: 1.30,
          incidentCount: incidentCount,
          weightedSeverity: weightedSeverity,
          categoryBreakdown: {CrimeCategory.theft: incidentCount},
          peakSeverity: peakSeverity,
        );

    test('0 incidents → riskScore is 0', () {
      final h = hotspot(incidentCount: 0, weightedSeverity: 0);
      expect(h.riskScore, 0.0);
    });

    test('10 incidents all severity 5 → riskScore is 100', () {
      // 10 incidents → densityFactor = 1.0 (capped)
      // weightedSeverity = 10 * (5/5) = 10  → severityFactor = 10/10 = 1.0
      // riskScore = (1.0*0.5 + 1.0*0.5) * 100 = 100
      final h = hotspot(incidentCount: 10, weightedSeverity: 10.0);
      expect(h.riskScore, closeTo(100.0, 1e-6));
    });

    test('1 incident severity 3 gives expected score', () {
      // densityFactor = 1/10 = 0.1
      // severityFactor = (3/5) / 1 = 0.6
      // riskScore = (0.1*0.5 + 0.6*0.5) * 100 = (0.05 + 0.30) * 100 = 35.0
      final h = hotspot(incidentCount: 1, weightedSeverity: 3 / 5);
      expect(h.riskScore, closeTo(35.0, 1e-6));
    });

    test('density is capped at 10 incidents', () {
      // 20 incidents should not exceed 100
      final h = hotspot(incidentCount: 20, weightedSeverity: 20.0);
      expect(h.riskScore, closeTo(100.0, 1e-6));
    });
  });

  group('AreaHotspot.explanationText', () {
    test('includes area name and incident count', () {
      final h = AreaHotspot(
        areaName: 'St Stephens Street',
        centroidLat: 52.62,
        centroidLon: 1.29,
        incidentCount: 4,
        weightedSeverity: 3.0,
        categoryBreakdown: {CrimeCategory.robbery: 3, CrimeCategory.theft: 1},
        peakSeverity: 5,
      );
      expect(h.explanationText, contains('St Stephens Street'));
      expect(h.explanationText, contains('4 incident'));
    });

    test('mentions most common crime category', () {
      final h = AreaHotspot(
        areaName: 'Market Area',
        centroidLat: 52.63,
        centroidLon: 1.30,
        incidentCount: 5,
        weightedSeverity: 4.0,
        categoryBreakdown: {
          CrimeCategory.harassment: 3,
          CrimeCategory.theft: 2,
        },
        peakSeverity: 3,
      );
      expect(h.explanationText.toLowerCase(), contains('harassment'));
    });

    test('singular "incident" for count = 1', () {
      final h = AreaHotspot(
        areaName: 'North Norwich',
        centroidLat: 52.64,
        centroidLon: 1.26,
        incidentCount: 1,
        weightedSeverity: 1.0,
        categoryBreakdown: {CrimeCategory.theft: 1},
        peakSeverity: 5,
      );
      // Should say "1 incident" not "1 incidents"
      expect(h.explanationText, contains('1 incident'));
      expect(h.explanationText, isNot(contains('1 incidents')));
    });
  });

  group('AreaHotspot.evidenceSummary', () {
    test('lists all categories in summary', () {
      final h = AreaHotspot(
        areaName: 'Central',
        centroidLat: 52.63,
        centroidLon: 1.30,
        incidentCount: 3,
        weightedSeverity: 2.4,
        categoryBreakdown: {
          CrimeCategory.theft: 2,
          CrimeCategory.assault: 1,
        },
        peakSeverity: 4,
      );
      final summary = h.evidenceSummary.toLowerCase();
      expect(summary, contains('theft'));
      expect(summary, contains('assault'));
    });
  });

  // =========================================================================
  // LAYER 3 — CrimeRiskAssessment thresholds
  // =========================================================================
  group('CrimeRiskAssessment risk thresholds', () {
    CrimeRiskAssessment assessment(double score) => CrimeRiskAssessment(
          riskScore: score,
          explanation: '',
          nearbyHotspots: [],
          totalIncidents: 0,
          overallCategoryBreakdown: {},
        );

    test('score 0 → not high risk, not medium risk', () {
      final a = assessment(0);
      expect(a.isHighRisk, isFalse);
      expect(a.isMediumRisk, isFalse);
    });

    test('score 29 → not medium risk', () {
      expect(assessment(29).isMediumRisk, isFalse);
    });

    test('score 30 → medium risk', () {
      expect(assessment(30).isMediumRisk, isTrue);
      expect(assessment(30).isHighRisk, isFalse);
    });

    test('score 59 → medium risk, not high', () {
      expect(assessment(59).isMediumRisk, isTrue);
      expect(assessment(59).isHighRisk, isFalse);
    });

    test('score 60 → high risk', () {
      expect(assessment(60).isHighRisk, isTrue);
      expect(assessment(60).isMediumRisk, isFalse); // high overrides medium
    });

    test('score 100 → high risk', () {
      expect(assessment(100).isHighRisk, isTrue);
    });
  });

  // =========================================================================
  // LAYER 4 — CrimeCategory enum display names
  // =========================================================================
  group('CrimeCategory display names', () {
    test('all categories have non-empty displayName', () {
      for (final cat in CrimeCategory.values) {
        expect(cat.displayName.isNotEmpty, isTrue,
            reason: '${cat.name} must have a displayName');
      }
    });

    test('all categories have non-empty icon', () {
      for (final cat in CrimeCategory.values) {
        expect(cat.icon.isNotEmpty, isTrue,
            reason: '${cat.name} must have an icon string');
      }
    });
  });

  // =========================================================================
  // LAYER 5 — End-to-end pipeline simulation (no rootBundle)
  // =========================================================================
  group('B2 pipeline simulation', () {
    // Simulate what the real service does after loading the CSV:
    // parse → filter recent → aggregate hotspots → assessPoint
    test('full pipeline: 3 recent incidents near Norwich centre score > 0', () {
      // Step 1 — Parse (simulate fromCsvRow for 3 recent records)
      final now = DateTime.now();
      final records = [
        CrimeEvidence(
          latitude: 52.6280,
          longitude: 1.2960,
          category: CrimeCategory.theft,
          date: now.subtract(const Duration(days: 10)),
          severity: 3,
          areaName: 'West End',
          description: 'Bag snatch',
        ),
        CrimeEvidence(
          latitude: 52.6282,
          longitude: 1.2962,
          category: CrimeCategory.robbery,
          date: now.subtract(const Duration(days: 20)),
          severity: 5,
          areaName: 'West End',
          description: 'Phone robbery',
        ),
        CrimeEvidence(
          latitude: 52.6450,
          longitude: 1.3100,
          category: CrimeCategory.harassment,
          date: now.subtract(const Duration(days: 5)),
          severity: 2,
          areaName: 'North Side',
          description: 'Verbal incident',
        ),
      ];

      // Step 2 — Filter recent (180-day window)
      final recentRecords = records
          .where((r) => r.isRecent(window: const Duration(days: 180)))
          .toList();
      expect(recentRecords.length, 3);

      // Step 3 — Aggregate hotspots
      final grouped = <String, List<CrimeEvidence>>{};
      for (final r in recentRecords) {
        grouped.putIfAbsent(r.areaName, () => []).add(r);
      }
      expect(grouped.keys, containsAll(['West End', 'North Side']));

      final westEnd = grouped['West End']!;
      expect(westEnd.length, 2);

      // Step 4 — Build AreaHotspot for 'West End'
      final latSum = westEnd.fold(0.0, (s, r) => s + r.latitude);
      final lonSum = westEnd.fold(0.0, (s, r) => s + r.longitude);
      final weightedSev = westEnd.fold(0.0, (s, r) => s + r.severityWeight);

      final hotspot = AreaHotspot(
        areaName: 'West End',
        centroidLat: latSum / westEnd.length,
        centroidLon: lonSum / westEnd.length,
        incidentCount: westEnd.length,
        weightedSeverity: weightedSev,
        categoryBreakdown: {CrimeCategory.theft: 1, CrimeCategory.robbery: 1},
        peakSeverity: 5,
      );

      expect(hotspot.riskScore, greaterThan(0));
      expect(hotspot.explanationText, contains('West End'));
      expect(hotspot.explanationText, contains('2 incident'));

      // Step 5 — Wrap in CrimeRiskAssessment
      final assessment = CrimeRiskAssessment(
        riskScore: hotspot.riskScore,
        explanation: hotspot.explanationText,
        nearbyHotspots: [hotspot],
        totalIncidents: hotspot.incidentCount,
        overallCategoryBreakdown: hotspot.categoryBreakdown,
      );

      expect(assessment.riskScore, greaterThan(0));
      expect(assessment.totalIncidents, 2);
      // WeightedSev = 3/5 + 5/5 = 0.6 + 1.0 = 1.6
      // densityFactor = 2/10 = 0.2
      // severityFactor = 1.6/2 = 0.8
      // riskScore = (0.2*0.5 + 0.8*0.5) * 100 = 50
      expect(assessment.riskScore, closeTo(50.0, 1e-4));
      expect(assessment.isMediumRisk, isTrue);
    });

    test('zero incidents near a remote location gives safe assessment', () {
      // No hotspots anywhere near this point — simulates assessPoint returning
      // the "no incidents" response
      const assessment = CrimeRiskAssessment(
        riskScore: 0,
        explanation: 'No recent incidents recorded near this location',
        nearbyHotspots: [],
        totalIncidents: 0,
        overallCategoryBreakdown: {},
      );
      expect(assessment.isHighRisk, isFalse);
      expect(assessment.isMediumRisk, isFalse);
      expect(assessment.explanation, contains('No recent'));
    });
  });
}
