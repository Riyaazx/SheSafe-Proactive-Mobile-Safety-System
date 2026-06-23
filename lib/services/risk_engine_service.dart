import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/crime_evidence.dart';
import '../models/risk_zone.dart';
import '../models/route_option.dart';
import 'crime_evidence_service.dart';
import 'uk_police_api_service.dart';

class RiskEngineService {
  List<RiskZone> _riskZones = [];
  bool _isInitialized = false;
  bool _usingLiveData = false;
  final CrimeEvidenceService _crimeService = CrimeEvidenceService();
  final UkPoliceApiService _policeApi = UkPoliceApiService();

  // Singleton pattern
  static final RiskEngineService _instance = RiskEngineService._internal();
  factory RiskEngineService() => _instance;
  RiskEngineService._internal();

  /// SharedPreferences key for the cached live risk zones JSON.
  static const String _liveZonesCacheKey = 'shesafe_live_risk_zones_v1';

  /// Whether the current risk zones come from the live UK Police API
  /// (or from a previously cached live fetch).
  bool get isUsingLiveData => _usingLiveData;

  // ── Local cache helpers ──────────────────────────────────────────────────────

  /// Persist [zones] to local storage so they survive offline restarts.
  Future<void> _saveLiveZonesToCache(List<RiskZone> zones) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = zones.map((z) => jsonEncode(z.toJson())).toList();
      await prefs.setStringList(_liveZonesCacheKey, jsonList);
      debugPrint(
        '💾 [RiskEngine] Saved ${zones.length} live zones to local cache '
        '(key: $_liveZonesCacheKey)',
      );
    } catch (e) {
      debugPrint('⚠️ [RiskEngine] Could not write live zones to cache: $e');
    }
  }

  /// Load previously-fetched live zones from local storage.
  /// Returns an empty list when no cache exists or it cannot be read.
  Future<List<RiskZone>> _loadLiveZonesFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = prefs.getStringList(_liveZonesCacheKey);
      if (jsonList == null || jsonList.isEmpty) return [];
      final zones = jsonList
          .map((s) => RiskZone.fromJson(jsonDecode(s) as Map<String, dynamic>))
          .toList();
      debugPrint(
        '📂 [RiskEngine] Loaded ${zones.length} live zones from local cache '
        '(previously fetched when online)',
      );
      return zones;
    } catch (e) {
      debugPrint('⚠️ [RiskEngine] Could not read cached live zones: $e');
      return [];
    }
  }

  // ── Initialisation ──────────────────────────────────────────────────────────

  /// Initialise the risk engine.
  ///
  /// **Priority order:**
  /// 1. Cached live data (from a previous successful online fetch) — best data.
  /// 2. Bundled CSV asset (shipped with the app) — always available offline.
  ///
  /// This means the app always shows risk zones, regardless of connectivity,
  /// and shows the freshest data available from a prior online session.
  Future<void> initialize() async {
    if (_isInitialized) return;

    // ── 1. Try previously-fetched live data from local cache ─────────────────
    final cached = await _loadLiveZonesFromCache();
    if (cached.isNotEmpty) {
      _riskZones = cached;
      _usingLiveData = true; // cached live data is treated as live
      await _crimeService.initialize();
      _isInitialized = true;
      debugPrint(
        '✅ [RiskEngine] Initialized from local cache (offline-friendly): '
        '${_riskZones.length} previously-fetched live zones',
      );
      return;
    }

    // ── 2. Fall back to bundled CSV asset ─────────────────────────────────────
    debugPrint(
      '📦 [RiskEngine] No cached live data found — '
      'loading bundled CSV fallback (always available offline)…',
    );
    try {
      final String csvData =
          await rootBundle.loadString('assets/risk_zones.csv');
      _riskZones = _parseCsvData(csvData);
      debugPrint(
        '✅ [RiskEngine] Loaded ${_riskZones.length} zones from bundled CSV',
      );
    } catch (e) {
      debugPrint('❌ [RiskEngine] Failed to load bundled CSV: $e');
      _riskZones = [];
    }

    await _crimeService.initialize();
    _isInitialized = true;
    debugPrint(
      '✅ [RiskEngine] Ready — source: bundled CSV, '
      '${_riskZones.length} zones, '
      '${_crimeService.recentRecords.length} crime records',
    );
  }

  /// Fetch live UK Police hotspot data and replace the current zones.
  ///
  /// On success: saves the fetched zones to local cache so the next offline
  /// launch can use them instead of the bundled CSV.
  ///
  /// On failure (network error / offline): existing zones stay active — either
  /// the already-loaded cache or the CSV fallback.
  Future<void> initializeWithLiveData(double lat, double lon) async {
    if (!_isInitialized) await initialize();

    try {
      debugPrint('🌐 [RiskEngine] Fetching live zones from UK Police API…');
      final liveZones = await _policeApi.fetchRiskZonesNearby(lat, lon);
      if (liveZones.isNotEmpty) {
        _riskZones = liveZones;
        _usingLiveData = true;
        // Save to local cache so future offline launches use this fresh data.
        await _saveLiveZonesToCache(liveZones);
        debugPrint(
          '✅ [RiskEngine] ${liveZones.length} live zones active and saved to cache',
        );
      } else {
        debugPrint(
          '⚠️ [RiskEngine] API returned no zones — '
          'keeping existing data (${_riskZones.length} zones, '
          'source: ${_usingLiveData ? "cached live" : "bundled CSV"})',
        );
      }
    } catch (e) {
      debugPrint(
        '❌ [RiskEngine] Live fetch failed — '
        'continuing with existing data '
        '(${_usingLiveData ? "cached live" : "bundled CSV"}): $e',
      );
    }
  }

  /// Parse CSV data into RiskZone objects.
  ///
  /// The CSV begins with `#` comment lines followed by the column header row,
  /// then data rows.  All comment/header lines are skipped so that only
  /// 8-column data rows are parsed.
  List<RiskZone> _parseCsvData(String csvData) {
    final List<RiskZone> zones = [];
    final lines = LineSplitter.split(csvData).toList();
    bool headerSeen = false;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      // Skip blank lines and comment lines
      if (line.isEmpty || line.startsWith('#')) continue;

      // First non-comment, non-blank line is the header — skip it once
      if (!headerSeen) {
        headerSeen = true;
        continue;
      }

      try {
        final fields = _parseCsvLine(line);
        // CSV has 8 columns: lat,lon,radius,risk_level,risk_score,severity,zone_name,description
        if (fields.length >= 8) {
          zones.add(RiskZone.fromCsvRow(fields));
        }
      } catch (e) {
        debugPrint('Warning: Could not parse CSV line $i: $e');
      }
    }

    return zones;
  }

  /// Parse a CSV line handling quoted fields
  List<String> _parseCsvLine(String line) {
    final List<String> fields = [];
    final buffer = StringBuffer();
    bool inQuotes = false;

    for (int i = 0; i < line.length; i++) {
      final char = line[i];

      if (char == '"') {
        inQuotes = !inQuotes;
      } else if (char == ',' && !inQuotes) {
        fields.add(buffer.toString().trim());
        buffer.clear();
      } else {
        buffer.write(char);
      }
    }

    // Add last field
    fields.add(buffer.toString().trim());
    return fields;
  }

  /// Calculate risk score for a single route
  RouteAnalysis analyzeRoute(RouteOption route, {double crimeScaleFactor = 1.0}) {
    if (!_isInitialized) {
      return RouteAnalysis(
        summary: 'Risk analysis unavailable',
        safetyReasons: [],
        riskEvidence: [],
        avoidedZones: [],
      );
    }

    // Collect evidence from all segments
    final List<RiskEvidence> allEvidence = [];
    final Set<String> encounteredzones = {};
    final List<String> avoidedZones = [];

    for (final segment in route.segments) {
      for (final zone in segment.nearbyRiskZones) {
        if (!encounteredzones.contains(zone.zoneName)) {
          encounteredzones.add(zone.zoneName);
          
          final distance = _minDistanceToSegment(
            zone.latitude,
            zone.longitude,
            segment.start,
            segment.end,
          );

          allEvidence.add(RiskEvidence(
            zoneName: zone.zoneName,
            riskLevel: zone.riskLevel,
            description: zone.description,
            distanceFromRouteMeters: distance,
            routePassesThrough: distance <= zone.radiusMeters,
          ));
        }
      }
    }

    // B2: Build crime evidence assessment from the route's actual path.
    // scaleFactor differentiates crime exposure between the shown routes.
    final crimeAss = _crimeService.isInitialized
      ? _crimeService.assessRoute(
        route.segments,
        scaleFactor: crimeScaleFactor,
        )
        : null;

    // Generate safety reasons
    final List<String> safetyReasons =
        _generateSafetyReasons(route, allEvidence, crimeAss);
    
    // Generate summary
    final String summary = _generateSummary(route.overallRiskScore, safetyReasons.length);

    return RouteAnalysis(
      summary: summary,
      safetyReasons: safetyReasons,
      riskEvidence: allEvidence,
      avoidedZones: avoidedZones,
      crimeAssessment: crimeAss,
    );
  }

  /// Generate safety reasons based on route analysis
  List<String> _generateSafetyReasons(
      RouteOption route,
      List<RiskEvidence> evidence,
      CrimeRiskAssessment? crimeAssessment) {
    final List<String> reasons = [];

    // Count risk zones by level
    int highRiskZones = 0;
    int mediumRiskZones = 0;
    // ignore: unused_local_variable
    int lowRiskZones = 0;

    for (final ev in evidence) {
      if (ev.routePassesThrough || ev.distanceFromRouteMeters < 200) {
        switch (ev.riskLevel) {
          case RiskLevel.high:
            highRiskZones++;
            break;
          case RiskLevel.medium:
            mediumRiskZones++;
            break;
          case RiskLevel.low:
            lowRiskZones++;
            break;
        }
      }
    }

    // Generate reasons based on findings
    if (highRiskZones == 0) {
      reasons.add('No high-risk zones along this route');
    } else if (highRiskZones == 1) {
      reasons.add('1 high-risk zone detected near route');
    } else {
      reasons.add('$highRiskZones high-risk zones detected near route');
    }

    if (mediumRiskZones > 0) {
      reasons.add('$mediumRiskZones medium-risk area(s) in proximity');
    }

    // Add specific zone mentions for high-risk areas
    for (final ev in evidence) {
      if (ev.riskLevel == RiskLevel.high && ev.routePassesThrough) {
        reasons.add('Route passes through ${ev.zoneName}');
      }
    }

    if (route.overallRiskScore < 15) {
      reasons.add('Avoids areas of highest concern — exposure to crime hotspots is minimised');
      reasons.add('Route maximises distance from known risk zones');
    } else if (route.overallRiskScore < 45) {
      reasons.add('Balances walking distance with reasonable safety margins');
      reasons.add('Moderate proximity to some risk areas — stay aware of surroundings');
    } else {
      reasons.add('More direct path — higher exposure to risk areas on this route');
      reasons.add('Consider the safer alternative routes if conditions allow');
    }

    // --- B2: Crime evidence reasons (reuse the already-built assessment) ---
    if (crimeAssessment != null && crimeAssessment.totalIncidents > 0) {
      reasons.add(crimeAssessment.explanation);
    }

    return reasons;
  }

  /// Generate summary text based on risk score
  String _generateSummary(double riskScore, int evidenceCount) {
    if (riskScore < 30) {
      return 'This is a safe route with minimal risk exposure';
    } else if (riskScore < 60) {
      return 'This route has moderate risk - exercise normal caution';
    } else {
      return 'This route passes through higher-risk areas';
    }
  }

  /// Score a route based on proximity to risk zones
  double scoreRoute(List<RouteSegment> segments) {
    if (segments.isEmpty) return 0.0;

    double totalRisk = 0.0;
    double totalDistance = 0.0;

    for (final segment in segments) {
      totalRisk += segment.riskScore * segment.distanceMeters;
      totalDistance += segment.distanceMeters;
    }

    return totalDistance > 0 ? totalRisk / totalDistance : 0.0;
  }

  /// Score a single segment of a route
  double scoreSegment(RouteWaypoint start, RouteWaypoint end) {
    double maxRisk = 0.0;

    // Check risk zones along this segment
    for (final zone in _riskZones) {
      final distanceToSegment = _minDistanceToSegment(
        zone.latitude,
        zone.longitude,
        start,
        end,
      );

      final riskScore = zone.getRiskScoreForDistance(distanceToSegment);
      if (riskScore > maxRisk) {
        maxRisk = riskScore;
      }
    }

    return maxRisk;
  }

  /// Find risk zones near a segment
  List<RiskZone> findNearbyRiskZones(RouteWaypoint start, RouteWaypoint end, {double maxDistanceMeters = 500}) {
    final List<RiskZone> nearbyZones = [];

    for (final zone in _riskZones) {
      final distanceToSegment = _minDistanceToSegment(
        zone.latitude,
        zone.longitude,
        start,
        end,
      );

      if (distanceToSegment <= maxDistanceMeters || distanceToSegment <= zone.radiusMeters) {
        nearbyZones.add(zone);
      }
    }

    return nearbyZones;
  }

  /// Calculate minimum distance from a point to a line segment (endpoint approximation).
  double _minDistanceToSegment(
    double pointLat,
    double pointLon,
    RouteWaypoint segmentStart,
    RouteWaypoint segmentEnd,
  ) {
    final distToStart = _haversineMeters(
        pointLat, pointLon, segmentStart.latitude, segmentStart.longitude);
    final distToEnd = _haversineMeters(
        pointLat, pointLon, segmentEnd.latitude, segmentEnd.longitude);
    return distToStart < distToEnd ? distToStart : distToEnd;
  }

  static double _haversineMeters(
      double lat1, double lon1, double lat2, double lon2) {
    const earthRadius = 6371000.0;
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

  /// Get all risk zones (for debugging/display)
  List<RiskZone> get allRiskZones => List.unmodifiable(_riskZones);

  /// Check if engine is initialized
  bool get isInitialized => _isInitialized;
}
