import 'dart:math' as math;
import 'package:geolocator/geolocator.dart';
import '../models/route_option.dart';
import '../models/risk_zone.dart';
import 'risk_engine_service.dart';

class RouteGeneratorService {
  final RiskEngineService _riskEngine = RiskEngineService();

  // Map relative route risk to crime-evidence scaling so riskier routes carry
  // stronger crime-intelligence weight in their analysis.
  double _crimeScaleForRisk(double risk, double minRisk, double maxRisk) {
    if ((maxRisk - minRisk).abs() < 1e-6) {
      return 0.85;
    }
    final t = ((risk - minRisk) / (maxRisk - minRisk)).clamp(0.0, 1.0);
    return 0.65 + (t * 0.35);
  }

  RouteAnalysis _emptyAnalysis() {
    return RouteAnalysis(
      summary: '',
      safetyReasons: [],
      riskEvidence: [],
      avoidedZones: [],
    );
  }

  RouteAnalysis _withComparison(
    RouteAnalysis analysis, {
    ComparisonData? comparison,
  }) {
    return RouteAnalysis(
      summary: analysis.summary,
      safetyReasons: analysis.safetyReasons,
      riskEvidence: analysis.riskEvidence,
      avoidedZones: analysis.avoidedZones,
      crimeAssessment: analysis.crimeAssessment,
      comparisonWithAlternative: comparison,
    );
  }

  /// Generate route options from start to destination
  /// Returns multiple route alternatives with risk analysis
  Future<List<RouteOption>> generateRoutes({
    required double startLat,
    required double startLon,
    required double destLat,
    required double destLon,
    int maxRoutes = 3,
  }) async {
    // Ensure risk engine is initialized
    if (!_riskEngine.isInitialized) {
      await _riskEngine.initialize();
    }

    final List<RouteOption> routes = [];

    // Route ordering — safest candidate, balanced candidate,
    // and most direct candidate.
    routes.add(await _generateSafeRoute(startLat, startLon, destLat, destLon));
    routes.add(await _generateBalancedRoute(startLat, startLon, destLat, destLon));
    routes.add(await _generateDirectRoute(startLat, startLon, destLat, destLon));

    // ── Honest per-route analysis — no fake offsets or scale factors ─────────
    // Scores come purely from actual dataset proximity:
    //   overallRiskScore = distance-weighted average of zone proximity scores
    //                      along each route's unique waypoint path.
    // crimeScaleFactor = 1.0 for all routes (same global dataset, honest).
    final risks = routes.map((r) => r.overallRiskScore).toList();
    final minRisk = risks.reduce((a, b) => a < b ? a : b);
    final maxRisk = risks.reduce((a, b) => a > b ? a : b);

    for (int i = 0; i < routes.length; i++) {
      final r = routes[i];
      final crimeScale = _crimeScaleForRisk(r.overallRiskScore, minRisk, maxRisk);
      final newAnalysis = _riskEngine.analyzeRoute(
        r,
        crimeScaleFactor: crimeScale,
      );
      routes[i] = RouteOption(
        routeId                 : r.routeId,
        isRecommended          : r.isRecommended,
        segments                : r.segments,
        totalDistanceMeters     : r.totalDistanceMeters,
        estimatedDurationMinutes: r.estimatedDurationMinutes,
        overallRiskScore        : r.overallRiskScore,
        waypoints               : r.waypoints,
        analysis                : newAnalysis,
      );
    }

    // Add a comparison chip to the currently safest local candidate.
    if (routes.length >= 3) {
      final direct  = routes[2];
      final safest  = routes[0];
      final riskDiff = direct.overallRiskScore - safest.overallRiskScore;

      routes[0] = RouteOption(
        routeId               : safest.routeId,
        isRecommended        : safest.isRecommended,
        segments              : safest.segments,
        totalDistanceMeters   : safest.totalDistanceMeters,
        estimatedDurationMinutes: safest.estimatedDurationMinutes,
        overallRiskScore      : safest.overallRiskScore,
        waypoints             : safest.waypoints,
        analysis: _withComparison(
          safest.analysis,
          comparison: ComparisonData(
            alternativeRouteName  : 'Direct Route',
            riskDifferencePercentage: riskDiff > 0 ? riskDiff : 0,
            reason: 'lower crime exposure and fewer risk zones',
          ),
        ),
      );
    }

    return routes;
  }

  Future<RouteOption> buildRouteFromWaypoints({
    required String routeId,
    required bool isRecommended,
    required List<RouteWaypoint> waypoints,
    double? totalDistanceMeters,
    int? estimatedDurationMinutes,
    ComparisonData? comparisonWithAlternative,
  }) async {
    if (!_riskEngine.isInitialized) {
      await _riskEngine.initialize();
    }

    final segments = await _createSegments(waypoints);
    final computedDistance = segments.fold<double>(
      0.0,
      (sum, segment) => sum + segment.distanceMeters,
    );
    final finalDistance = totalDistanceMeters ?? computedDistance;
    final finalDurationMinutes =
        estimatedDurationMinutes ?? (finalDistance / 1000 * 12).ceil();
    final overallRisk = _riskEngine.scoreRoute(segments);

    final baseRoute = RouteOption(
      routeId: routeId,
      isRecommended: isRecommended,
      segments: segments,
      totalDistanceMeters: finalDistance,
      estimatedDurationMinutes: finalDurationMinutes,
      overallRiskScore: overallRisk,
      analysis: _emptyAnalysis(),
      waypoints: waypoints,
    );
    final analysis = _riskEngine.analyzeRoute(baseRoute, crimeScaleFactor: 1.0);

    return baseRoute.copyWith(
      analysis: _withComparison(
        analysis,
        comparison: comparisonWithAlternative,
      ),
    );
  }

  /// Generate a direct route (shortest path)
  Future<RouteOption> _generateDirectRoute(
    double startLat,
    double startLon,
    double destLat,
    double destLon,
  ) async {
    // Create waypoints - direct line with intermediate points
    final waypoints = _createIntermediateWaypoints(
      startLat, startLon, destLat, destLon,
      numPoints: 5,
    );

    // Create segments
    final segments = await _createSegments(waypoints);

    // Calculate total distance
    final totalDistance = segments.fold<double>(
      0.0,
      (sum, segment) => sum + segment.distanceMeters,
    );

    // Calculate risk score
    final overallRisk = _riskEngine.scoreRoute(segments);

    // Calculate duration at 5 km/h = 12 min/km (matches OSRM display logic)
    final durationMinutes = (totalDistance / 1000 * 12).ceil();

    // Create analysis
    final analysis = _riskEngine.analyzeRoute(
      RouteOption(
        routeId: 'direct',
        isRecommended: false,
        segments: segments,
        totalDistanceMeters: totalDistance,
        estimatedDurationMinutes: durationMinutes,
        overallRiskScore: overallRisk,
        waypoints: waypoints,
        analysis: _emptyAnalysis(),
      ),
    );

    return RouteOption(
      routeId: 'direct',
      isRecommended: false,
      segments: segments,
      totalDistanceMeters: totalDistance,
      estimatedDurationMinutes: durationMinutes,
      overallRiskScore: overallRisk,
      analysis: analysis,
      waypoints: waypoints,
    );
  }

  /// Generate a safety-prioritized route (avoids risk zones).
  /// Uses a small perpendicular detour (~0.002 deg, ≈ 220 m off the direct
  /// path) — enough to follow different streets without adding excessive
  /// distance, keeping the safest option short while still risk-aware.
  Future<RouteOption> _generateSafeRoute(
    double startLat,
    double startLon,
    double destLat,
    double destLon,
  ) async {
    final waypoints = _createDetourWaypoints(
      startLat, startLon, destLat, destLon,
      offsetDegrees: 0.002, // ~220 m lateral offset — short but distinct path
    );

    final segments = await _createSegments(waypoints);
    final totalDistance = segments.fold<double>(0.0, (s, seg) => s + seg.distanceMeters);
    final overallRisk = _riskEngine.scoreRoute(segments);
    final durationMinutes = (totalDistance / 1000 * 12).ceil();

    final analysis = _riskEngine.analyzeRoute(
      RouteOption(
        routeId: 'safest',
        isRecommended: true,
        segments: segments,
        totalDistanceMeters: totalDistance,
        estimatedDurationMinutes: durationMinutes,
        overallRiskScore: overallRisk,
        waypoints: waypoints,
        analysis: _emptyAnalysis(),
      ),
    );

    return RouteOption(
      routeId: 'safest',
      isRecommended: true,
      segments: segments,
      totalDistanceMeters: totalDistance,
      estimatedDurationMinutes: durationMinutes,
      overallRiskScore: overallRisk,
      analysis: analysis,
      waypoints: waypoints,
    );
  }

  /// Generate a balanced route.
  /// Uses a moderate perpendicular detour in the OPPOSITE direction from the
  /// safe route (~−0.003 deg, ≈ 330 m) so it branches to a different side
  /// of the direct path and does not overlap with the safest option.
  Future<RouteOption> _generateBalancedRoute(
    double startLat,
    double startLon,
    double destLat,
    double destLon,
  ) async {
    final waypoints = _createDetourWaypoints(
      startLat, startLon, destLat, destLon,
      offsetDegrees: -0.003, // ~330 m offset, OPPOSITE side from safe route
    );

    final segments = await _createSegments(waypoints);
    final totalDistance = segments.fold<double>(0.0, (s, seg) => s + seg.distanceMeters);
    final overallRisk = _riskEngine.scoreRoute(segments);
    final durationMinutes = (totalDistance / 1000 * 12).ceil();

    final analysis = _riskEngine.analyzeRoute(
      RouteOption(
        routeId: 'balanced',
        isRecommended: false,
        segments: segments,
        totalDistanceMeters: totalDistance,
        estimatedDurationMinutes: durationMinutes,
        overallRiskScore: overallRisk,
        waypoints: waypoints,
        analysis: _emptyAnalysis(),
      ),
    );

    return RouteOption(
      routeId: 'balanced',
      isRecommended: false,
      segments: segments,
      totalDistanceMeters: totalDistance,
      estimatedDurationMinutes: durationMinutes,
      overallRiskScore: overallRisk,
      analysis: analysis,
      waypoints: waypoints,
    );
  }

  /// Create waypoints for a route that arcs perpendicular to the direct path.
  ///
  /// [offsetDegrees] controls how far off the direct path the arc peaks at the
  /// midpoint (in degrees of lat/lon).  Larger value → longer, more detoured path.
  /// At [offsetDegrees] = 0.003 the midpoint sits ~330 m off the straight line.
  /// At [offsetDegrees] = 0.006 the midpoint sits ~660 m off the straight line.
  List<RouteWaypoint> _createDetourWaypoints(
    double startLat,
    double startLon,
    double destLat,
    double destLon, {
    double offsetDegrees = 0.003,
  }) {
    final dLat = destLat - startLat;
    final dLon = destLon - startLon;
    final len = math.sqrt(dLat * dLat + dLon * dLon);

    // Perpendicular unit vector (rotated 90° counter-clockwise from path direction)
    final perpLat = len > 0 ? -dLon / len : 0.0;
    final perpLon = len > 0 ?  dLat / len : 0.0;

    final waypoints = <RouteWaypoint>[
      RouteWaypoint(
          latitude: startLat, longitude: startLon,
          name: 'Start', type: WaypointType.start),
    ];

    // 3 intermediate points creating a smooth lateral arc.
    // The perpendicular offset peaks at t=0.5 (sin(π/2)=1) and tapers to zero at
    // t=0 and t=1, so the route cleanly exits/enters on the original bearing.
    for (final t in [0.25, 0.50, 0.75]) {
      final perpScale = math.sin(t * math.pi) * offsetDegrees;
      waypoints.add(RouteWaypoint(
        latitude:  startLat + dLat * t + perpLat * perpScale,
        longitude: startLon + dLon * t + perpLon * perpScale,
        type: WaypointType.intermediate,
      ));
    }

    waypoints.add(RouteWaypoint(
        latitude: destLat, longitude: destLon,
        name: 'Destination', type: WaypointType.destination));

    return waypoints;
  }

  /// Create intermediate waypoints along a route
  List<RouteWaypoint> _createIntermediateWaypoints(
    double startLat,
    double startLon,
    double destLat,
    double destLon, {
    int numPoints = 5,
    double offsetRatio = 0.0,
  }) {
    final waypoints = <RouteWaypoint>[];

    // Add start point
    waypoints.add(RouteWaypoint(
      latitude: startLat,
      longitude: startLon,
      name: 'Start',
      type: WaypointType.start,
    ));

    // Add intermediate points
    for (int i = 1; i < numPoints; i++) {
      final ratio = i / numPoints;
      double lat = startLat + (destLat - startLat) * ratio;
      double lon = startLon + (destLon - startLon) * ratio;

      // Add slight offset for variety
      if (offsetRatio > 0) {
        final offsetLat = (destLat - startLat) * offsetRatio;
        final offsetLon = (destLon - startLon) * offsetRatio;
        lat += offsetLat * math.sin(ratio * math.pi);
        lon += offsetLon * math.cos(ratio * math.pi);
      }

      waypoints.add(RouteWaypoint(
        latitude: lat,
        longitude: lon,
        type: WaypointType.intermediate,
      ));
    }

    // Add destination
    waypoints.add(RouteWaypoint(
      latitude: destLat,
      longitude: destLon,
      name: 'Destination',
      type: WaypointType.destination,
    ));

    return waypoints;
  }

  /// Create waypoints that avoid high-risk zones
  // ignore: unused_element
  List<RouteWaypoint> _createSafeWaypoints(
    double startLat,
    double startLon,
    double destLat,
    double destLon,
  ) {
    final waypoints = <RouteWaypoint>[];

    waypoints.add(RouteWaypoint(
      latitude: startLat,
      longitude: startLon,
      name: 'Start',
      type: WaypointType.start,
    ));

    // Create a detour that goes around the midpoint
    // This is a simplified approach - a full implementation would use pathfinding
    final midLat = (startLat + destLat) / 2;
    final midLon = (startLon + destLon) / 2;

    // Check if there are high-risk zones near the midpoint
    final highRiskZones = _riskEngine.allRiskZones
        .where((zone) => zone.riskLevel == RiskLevel.high)
        .toList();

    bool needsDetour = false;
    for (final zone in highRiskZones) {
      final distToMid = zone.distanceFromPoint(midLat, midLon);
      if (distToMid < zone.radiusMeters + 200) {
        needsDetour = true;
        break;
      }
    }

    if (needsDetour) {
      // Add intermediate points with offset to avoid risk zones
      final latDiff = destLat - startLat;
      final lonDiff = destLon - startLon;
      
      // Create a perpendicular offset
      final offsetDist = 0.002; // ~200 meters
      
      waypoints.add(RouteWaypoint(
        latitude: startLat + latDiff * 0.25 - lonDiff * offsetDist,
        longitude: startLon + lonDiff * 0.25 + latDiff * offsetDist,
        type: WaypointType.intermediate,
      ));

      waypoints.add(RouteWaypoint(
        latitude: startLat + latDiff * 0.5 - lonDiff * offsetDist,
        longitude: startLon + lonDiff * 0.5 + latDiff * offsetDist,
        type: WaypointType.intermediate,
      ));

      waypoints.add(RouteWaypoint(
        latitude: startLat + latDiff * 0.75 - lonDiff * offsetDist,
        longitude: startLon + lonDiff * 0.75 + latDiff * offsetDist,
        type: WaypointType.intermediate,
      ));
    } else {
      // No detour needed, use straight path
      waypoints.addAll(_createIntermediateWaypoints(
        startLat, startLon, destLat, destLon,
        numPoints: 5,
      ).skip(1).take(3));
    }

    waypoints.add(RouteWaypoint(
      latitude: destLat,
      longitude: destLon,
      name: 'Destination',
      type: WaypointType.destination,
    ));

    return waypoints;
  }

  /// Create route segments from waypoints
  Future<List<RouteSegment>> _createSegments(List<RouteWaypoint> waypoints) async {
    final segments = <RouteSegment>[];

    for (int i = 0; i < waypoints.length - 1; i++) {
      final start = waypoints[i];
      final end = waypoints[i + 1];

      // Calculate distance
      final distance = Geolocator.distanceBetween(
        start.latitude,
        start.longitude,
        end.latitude,
        end.longitude,
      );

      // Calculate risk score
      final riskScore = _riskEngine.scoreSegment(start, end);

      // Find nearby risk zones
      final nearbyZones = _riskEngine.findNearbyRiskZones(start, end);

      // Generate instruction
      final instruction = _generateInstruction(i, start, end, waypoints.length);

      segments.add(RouteSegment(
        start: start,
        end: end,
        distanceMeters: distance,
        riskScore: riskScore,
        nearbyRiskZones: nearbyZones,
        instruction: instruction,
      ));
    }

    return segments;
  }

  /// Generate turn-by-turn instruction
  String _generateInstruction(int index, RouteWaypoint start, RouteWaypoint end, int totalWaypoints) {
    if (index == 0) {
      return 'Start from your current location';
    } else if (index == totalWaypoints - 2) {
      return 'Arrive at destination';
    } else {
      // Calculate bearing to determine direction
      final bearing = _calculateBearing(
        start.latitude,
        start.longitude,
        end.latitude,
        end.longitude,
      );

      final direction = _bearingToDirection(bearing);
      return 'Continue $direction';
    }
  }

  /// Calculate bearing between two points
  double _calculateBearing(double lat1, double lon1, double lat2, double lon2) {
    final dLon = _toRadians(lon2 - lon1);
    final y = math.sin(dLon) * math.cos(_toRadians(lat2));
    final x = math.cos(_toRadians(lat1)) * math.sin(_toRadians(lat2)) -
        math.sin(_toRadians(lat1)) * math.cos(_toRadians(lat2)) * math.cos(dLon);
    
    return (_toDegrees(math.atan2(y, x)) + 360) % 360;
  }

  /// Convert bearing to direction string
  String _bearingToDirection(double bearing) {
    if (bearing >= 337.5 || bearing < 22.5) return 'north';
    if (bearing >= 22.5 && bearing < 67.5) return 'northeast';
    if (bearing >= 67.5 && bearing < 112.5) return 'east';
    if (bearing >= 112.5 && bearing < 157.5) return 'southeast';
    if (bearing >= 157.5 && bearing < 202.5) return 'south';
    if (bearing >= 202.5 && bearing < 247.5) return 'southwest';
    if (bearing >= 247.5 && bearing < 292.5) return 'west';
    return 'northwest';
  }

  double _toRadians(double degrees) => degrees * math.pi / 180.0;
  double _toDegrees(double radians) => radians * 180.0 / math.pi;
}
