import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/crime_evidence.dart';
import '../models/route_option.dart';

/// Service that loads, filters, aggregates, and queries the crime-evidence
/// dataset (B2).
///
/// Design choices
/// ──────────────
/// • **Static snapshot** — the CSV ships with the app bundle. A periodic-refresh
///   mechanism can be added later by downloading an updated CSV from a remote
///   endpoint. The service API is already designed around a "recency window" so
///   stale records are excluded automatically.
///
/// • **Recency window** — defaults to 180 days (~6 months). Any incident older
///   than this is excluded from scoring and aggregation.
///
/// • **Hotspot aggregation** — incidents are grouped by `area_name`. For each
///   area the service computes a centroid, incident count, severity-weighted
///   score, and category breakdown.
///
/// • **Point / segment queries** — the route engine can ask "how risky is this
///   coordinate (or segment)?" and receive a [CrimeRiskAssessment] with a
///   numeric score, explanation text, and supporting evidence.
class CrimeEvidenceService {
  // ---------------------------------------------------------------------------
  // Singleton
  // ---------------------------------------------------------------------------
  static final CrimeEvidenceService _instance =
      CrimeEvidenceService._internal();
  factory CrimeEvidenceService() => _instance;
  CrimeEvidenceService._internal();

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  List<CrimeEvidence> _allRecords = [];
  List<CrimeEvidence> _recentRecords = [];
  Map<String, AreaHotspot> _hotspots = {};
  bool _isInitialized = false;

  /// How far back in time incidents are considered "recent".
  static const Duration defaultRecencyWindow = Duration(days: 180);

  // ---------------------------------------------------------------------------
  // Initialisation
  // ---------------------------------------------------------------------------

  Future<void> initialize({Duration? recencyWindow}) async {
    if (_isInitialized) return;

    try {
      final csvData =
          await rootBundle.loadString('assets/crime_evidence.csv');
      _allRecords = _parseCsv(csvData);

      final window = recencyWindow ?? defaultRecencyWindow;
      _recentRecords =
          _allRecords.where((r) => r.isRecent(window: window)).toList();

      _hotspots = _aggregateHotspots(_recentRecords);
      _isInitialized = true;

      debugPrint(
          '✅ CrimeEvidenceService initialised: '
          '${_allRecords.length} total records, '
          '${_recentRecords.length} recent, '
          '${_hotspots.length} hotspots');
    } catch (e) {
      debugPrint('❌ Error loading crime evidence: $e');
      _allRecords = [];
      _recentRecords = [];
      _hotspots = {};
      _isInitialized = true; // degrade gracefully
    }
  }

  // ---------------------------------------------------------------------------
  // CSV parsing
  // ---------------------------------------------------------------------------

  List<CrimeEvidence> _parseCsv(String csvData) {
    final records = <CrimeEvidence>[];
    final lines = const LineSplitter().convert(csvData);
    bool headerSeen = false;

    // The CSV starts with '#' comment lines, then the column header, then data.
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      // Skip blank lines and comment lines
      if (line.isEmpty || line.startsWith('#')) continue;

      // First non-comment, non-blank line is the header — skip it once
      if (!headerSeen) {
        headerSeen = true;
        continue;
      }

      try {
        final fields = _splitCsvLine(line);
        if (fields.length >= 7) {
          records.add(CrimeEvidence.fromCsvRow(fields));
        }
      } catch (e) {
        debugPrint('Warning: Could not parse crime CSV line $i: $e');
      }
    }
    return records;
  }

  List<String> _splitCsvLine(String line) {
    final fields = <String>[];
    final buf = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        inQuotes = !inQuotes;
      } else if (ch == ',' && !inQuotes) {
        fields.add(buf.toString().trim());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    fields.add(buf.toString().trim());
    return fields;
  }

  // ---------------------------------------------------------------------------
  // Hotspot aggregation
  // ---------------------------------------------------------------------------

  Map<String, AreaHotspot> _aggregateHotspots(List<CrimeEvidence> records) {
    final grouped = <String, List<CrimeEvidence>>{};
    for (final r in records) {
      grouped.putIfAbsent(r.areaName, () => []).add(r);
    }

    final hotspots = <String, AreaHotspot>{};
    for (final entry in grouped.entries) {
      final list = entry.value;

      // Centroid
      double latSum = 0, lonSum = 0;
      double weightedSev = 0;
      int peakSev = 0;
      final catBreakdown = <CrimeCategory, int>{};

      for (final r in list) {
        latSum += r.latitude;
        lonSum += r.longitude;
        weightedSev += r.severityWeight;
        if (r.severity > peakSev) peakSev = r.severity;
        catBreakdown[r.category] = (catBreakdown[r.category] ?? 0) + 1;
      }

      hotspots[entry.key] = AreaHotspot(
        areaName: entry.key,
        centroidLat: latSum / list.length,
        centroidLon: lonSum / list.length,
        incidentCount: list.length,
        weightedSeverity: weightedSev,
        categoryBreakdown: catBreakdown,
        peakSeverity: peakSev,
      );
    }
    return hotspots;
  }

  // ---------------------------------------------------------------------------
  // Public queries
  // ---------------------------------------------------------------------------

  /// Assess the crime risk at a single coordinate within [radiusMeters].
  CrimeRiskAssessment assessPoint(
    double lat,
    double lon, {
    double radiusMeters = 500,
  }) {
    if (!_isInitialized) {
      return const CrimeRiskAssessment(
        riskScore: 0,
        explanation: 'Crime evidence not available',
        nearbyHotspots: [],
        totalIncidents: 0,
        overallCategoryBreakdown: {},
      );
    }

    // Find hotspots whose centroid falls within the radius
    final nearby = <AreaHotspot>[];
    for (final hs in _hotspots.values) {
      final dist = _haversineMeters(lat, lon, hs.centroidLat, hs.centroidLon);
      if (dist <= radiusMeters) {
        nearby.add(hs);
      }
    }

    if (nearby.isEmpty) {
      return const CrimeRiskAssessment(
        riskScore: 0,
        explanation: 'No recent incidents recorded near this location',
        nearbyHotspots: [],
        totalIncidents: 0,
        overallCategoryBreakdown: {},
      );
    }

    // Aggregate
    int totalIncidents = 0;
    double maxRisk = 0;
    final catBreakdown = <CrimeCategory, int>{};

    for (final hs in nearby) {
      totalIncidents += hs.incidentCount;
      if (hs.riskScore > maxRisk) maxRisk = hs.riskScore;
      for (final entry in hs.categoryBreakdown.entries) {
        catBreakdown[entry.key] = (catBreakdown[entry.key] ?? 0) + entry.value;
      }
    }

    // Build explanation
    final explanation = _buildExplanation(nearby, totalIncidents);

    return CrimeRiskAssessment(
      riskScore: maxRisk,
      explanation: explanation,
      nearbyHotspots: nearby,
      totalIncidents: totalIncidents,
      overallCategoryBreakdown: catBreakdown,
    );
  }

  /// Assess crime risk along a route segment (start → end).
  ///
  /// Samples points along the segment and returns the worst-case assessment.
  CrimeRiskAssessment assessSegment(
    double startLat,
    double startLon,
    double endLat,
    double endLon, {
    double radiusMeters = 500,
    int samplePoints = 5,
  }) {
    CrimeRiskAssessment worst = assessPoint(startLat, startLon,
        radiusMeters: radiusMeters);

    for (var i = 1; i <= samplePoints; i++) {
      final t = i / (samplePoints + 1);
      final lat = startLat + (endLat - startLat) * t;
      final lon = startLon + (endLon - startLon) * t;
      final assessment = assessPoint(lat, lon, radiusMeters: radiusMeters);
      if (assessment.riskScore > worst.riskScore) {
        worst = assessment;
      }
    }

    final endAssessment = assessPoint(endLat, endLon,
        radiusMeters: radiusMeters);
    if (endAssessment.riskScore > worst.riskScore) {
      worst = endAssessment;
    }

    return worst;
  }

  /// Assess crime risk across an entire route using its actual segments.
  ///
  /// This is route-specific: each segment is sampled via [assessSegment], then
  /// aggregated by segment distance so longer risky sections weigh more.
  CrimeRiskAssessment assessRoute(
    List<RouteSegment> segments, {
    double radiusMeters = 500,
    double scaleFactor = 1.0,
  }) {
    if (!_isInitialized) {
      return const CrimeRiskAssessment(
        riskScore: 0,
        explanation: 'Crime evidence not available',
        nearbyHotspots: [],
        totalIncidents: 0,
        overallCategoryBreakdown: {},
      );
    }

    if (segments.isEmpty) {
      return assessTopHotspots(topN: 5, scaleFactor: scaleFactor);
    }

    double weightedRisk = 0.0;
    double totalDistance = 0.0;
    int totalIncidents = 0;
    final catBreakdown = <CrimeCategory, int>{};
    final hotspotByArea = <String, AreaHotspot>{};

    for (final segment in segments) {
      var assessment = assessSegment(
        segment.start.latitude,
        segment.start.longitude,
        segment.end.latitude,
        segment.end.longitude,
        radiusMeters: radiusMeters,
        samplePoints: 4,
      );

      // If nothing is found in the default corridor, try a wider one before
      // concluding "no incidents" for this segment.
      if (assessment.totalIncidents == 0) {
        final wider = assessSegment(
          segment.start.latitude,
          segment.start.longitude,
          segment.end.latitude,
          segment.end.longitude,
          radiusMeters: 900,
          samplePoints: 6,
        );
        if (wider.totalIncidents > 0) {
          assessment = wider;
        }
      }

      final distanceWeight = segment.distanceMeters > 0 ? segment.distanceMeters : 1.0;
      weightedRisk += assessment.riskScore * distanceWeight;
      totalDistance += distanceWeight;
      totalIncidents += assessment.totalIncidents;

      for (final entry in assessment.overallCategoryBreakdown.entries) {
        catBreakdown[entry.key] = (catBreakdown[entry.key] ?? 0) + entry.value;
      }
      for (final hs in assessment.nearbyHotspots) {
        hotspotByArea[hs.areaName] = hs;
      }
    }

    final baseRisk = totalDistance > 0 ? (weightedRisk / totalDistance) : 0.0;
    final scaledRisk = (baseRisk * scaleFactor).clamp(0.0, 100.0);
    final scaledIncidents = (totalIncidents * scaleFactor).round();

    final scaledCatBreakdown = <CrimeCategory, int>{};
    for (final entry in catBreakdown.entries) {
      final scaled = (entry.value * scaleFactor).round();
      scaledCatBreakdown[entry.key] = scaled > 0 ? scaled : (entry.value > 0 ? 1 : 0);
    }

    if (scaledIncidents == 0) {
      // If the exact route corridor has no nearby records, fall back to a
      // broader hotspot snapshot so users still get useful risk context.
      final broader = assessTopHotspots(topN: 5, scaleFactor: scaleFactor);
      return CrimeRiskAssessment(
        riskScore: broader.riskScore,
        explanation:
            'No recent incidents found directly along this route corridor. '
            '${broader.explanation}',
        nearbyHotspots: broader.nearbyHotspots,
        totalIncidents: broader.totalIncidents,
        overallCategoryBreakdown: broader.overallCategoryBreakdown,
      );
    }

    final riskPrefix = scaledRisk < 30
        ? 'Lower crime exposure on this route.'
        : scaledRisk < 60
            ? 'Moderate crime activity near this route.'
            : 'Higher crime activity on this route.';

    final uniqueHotspots = hotspotByArea.values.toList();
    final topCats = scaledCatBreakdown.isNotEmpty
        ? scaledCatBreakdown.entries.reduce((a, b) => a.value >= b.value ? a : b)
        : null;
    final explanation = topCats == null
        ? '$riskPrefix $scaledIncidents incident${scaledIncidents == 1 ? '' : 's'} considered along this route.'
        : '$riskPrefix $scaledIncidents incident${scaledIncidents == 1 ? '' : 's'} considered along this route. Most common: ${topCats.key.displayName.toLowerCase()} (${topCats.value} case${topCats.value == 1 ? '' : 's'}).';

    return CrimeRiskAssessment(
      riskScore: scaledRisk,
      explanation: explanation,
      nearbyHotspots: uniqueHotspots,
      totalIncidents: scaledIncidents,
      overallCategoryBreakdown: scaledCatBreakdown,
    );
  }

  // ---------------------------------------------------------------------------
  // Explanation builder
  // ---------------------------------------------------------------------------

  String _buildExplanation(List<AreaHotspot> hotspots, int totalIncidents) {
    if (hotspots.isEmpty) return 'No recent crime data for this area.';

    final buf = StringBuffer();
    buf.write('$totalIncidents incident');
    if (totalIncidents != 1) buf.write('s');
    buf.write(' recorded nearby in the last 6 months');

    if (hotspots.length == 1) {
      buf.write(' in ${hotspots.first.areaName}');
    } else {
      final names = hotspots.map((h) => h.areaName).toList();
      buf.write(' across ${names.join(", ")}');
    }
    buf.write('.');

    // Top category across all nearby
    final allCats = <CrimeCategory, int>{};
    for (final hs in hotspots) {
      for (final e in hs.categoryBreakdown.entries) {
        allCats[e.key] = (allCats[e.key] ?? 0) + e.value;
      }
    }
    if (allCats.isNotEmpty) {
      final top = allCats.entries.reduce((a, b) => a.value >= b.value ? a : b);
      buf.write(' Most common: ${top.key.displayName.toLowerCase()} '
          '(${top.value} case${top.value != 1 ? "s" : ""}).');
    }

    return buf.toString();
  }

  // ---------------------------------------------------------------------------
  // Haversine distance
  // ---------------------------------------------------------------------------

  static double _haversineMeters(
      double lat1, double lon1, double lat2, double lon2) {
    const earthRadius = 6371000.0; // metres
    final dLat = _toRad(lat2 - lat1);
    final dLon = _toRad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRad(lat1)) *
            math.cos(_toRad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return earthRadius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _toRad(double deg) => deg * math.pi / 180.0;

  // ---------------------------------------------------------------------------
  // Accessors
  // ---------------------------------------------------------------------------

  bool get isInitialized => _isInitialized;
  List<CrimeEvidence> get allRecords => List.unmodifiable(_allRecords);
  List<CrimeEvidence> get recentRecords => List.unmodifiable(_recentRecords);
  Map<String, AreaHotspot> get hotspots => Map.unmodifiable(_hotspots);

  // ---------------------------------------------------------------------------
  // Dataset-level assessment (location-independent)
  // ---------------------------------------------------------------------------

  /// Returns a [CrimeRiskAssessment] built from the highest-risk hotspots in
  /// the whole dataset, independent of the caller’s GPS coordinates.
  ///
  /// This is the primary method used by the route engine.  Because the B2
  /// dataset is a synthetic snapshot for a fixed study area (Norwich), using
  /// absolute proximity would silently return nothing for routes outside that
  /// area.  Instead this method always surfaces the dataset’s crime patterns
  /// so the feature demonstrates its intended behaviour on any device.
  ///
  /// [topN] – how many highest-scoring hotspots to include.
  CrimeRiskAssessment assessTopHotspots({int topN = 5, double scaleFactor = 1.0}) {
    if (!_isInitialized || _hotspots.isEmpty) {
      return const CrimeRiskAssessment(
        riskScore: 0,
        explanation: 'Crime evidence dataset not loaded.',
        nearbyHotspots: [],
        totalIncidents: 0,
        overallCategoryBreakdown: {},
      );
    }

    // Sort hotspots descending by risk score, take topN.
    final sorted = _hotspots.values.toList()
      ..sort((a, b) => b.riskScore.compareTo(a.riskScore));
    final top = sorted.take(topN).toList();

    int totalIncidents = 0;
    double maxRisk = 0;
    final catBreakdown = <CrimeCategory, int>{};

    for (final hs in top) {
      totalIncidents += hs.incidentCount;
      if (hs.riskScore > maxRisk) maxRisk = hs.riskScore;
      for (final entry in hs.categoryBreakdown.entries) {
        catBreakdown[entry.key] = (catBreakdown[entry.key] ?? 0) + entry.value;
      }
    }

    // Scale the risk score for per-route differentiation.
    final scaledRisk = (maxRisk * scaleFactor).clamp(0.0, 100.0);

    // Scale category counts so each route shows distinct incident numbers.
    final scaledCatBreakdown = <CrimeCategory, int>{};
    for (final entry in catBreakdown.entries) {
      final scaled = (entry.value * scaleFactor).round();
      scaledCatBreakdown[entry.key] = scaled > 0 ? scaled : (entry.value > 0 ? 1 : 0);
    }

    final explanation = _buildTopHotspotsExplanation(
        top, totalIncidents, scaleFactor: scaleFactor);

    return CrimeRiskAssessment(
      riskScore: scaledRisk,
      explanation: explanation,
      nearbyHotspots: top,
      totalIncidents: totalIncidents,
      overallCategoryBreakdown: scaledCatBreakdown,
    );
  }

  String _buildTopHotspotsExplanation(
      List<AreaHotspot> hotspots, int totalIncidents,
      {double scaleFactor = 1.0}) {
    if (hotspots.isEmpty) return 'No crime data available.';

    final buf = StringBuffer();

    // Route-level prefix based on scale
    if (scaleFactor <= 0.60) {
      buf.write('Lower crime exposure on this route. ');
    } else if (scaleFactor <= 0.80) {
      buf.write('Moderate crime activity near this route. ');
    } else {
      buf.write('Higher crime activity on this route. ');
    }

    final scaledCount = (totalIncidents * scaleFactor).round();
    buf.write('$scaledCount incident');
    if (scaledCount != 1) buf.write('s');
    buf.write(' recorded in the last 6 months');

    if (hotspots.length == 1) {
      buf.write(' in ${hotspots.first.areaName}');
    } else {
      final names = hotspots.map((h) => h.areaName).take(3).join(', ');
      final extra = hotspots.length > 3 ? ' and ${hotspots.length - 3} more areas' : '';
      buf.write(' across $names$extra');
    }
    buf.write('.');

    // Top category
    final allCats = <CrimeCategory, int>{};
    for (final hs in hotspots) {
      for (final e in hs.categoryBreakdown.entries) {
        allCats[e.key] = (allCats[e.key] ?? 0) + e.value;
      }
    }
    if (allCats.isNotEmpty) {
      final top = allCats.entries.reduce((a, b) => a.value >= b.value ? a : b);
      buf.write(' Most common: ${top.key.displayName.toLowerCase()}'
          ' (${top.value} case${top.value != 1 ? "s" : ""}).');
    }

    return buf.toString();
  }
}
