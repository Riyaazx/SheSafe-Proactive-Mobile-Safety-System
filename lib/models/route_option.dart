import 'risk_zone.dart';
import 'crime_evidence.dart';

class RouteOption {
  final String routeId;
  final bool isRecommended;
  final List<RouteSegment> segments;
  final double totalDistanceMeters;
  final int estimatedDurationMinutes;
  final double overallRiskScore; // 0-100, lower is safer
  final RouteAnalysis analysis;
  final List<RouteWaypoint> waypoints;

  RouteOption({
    required this.routeId,
    required this.isRecommended,
    required this.segments,
    required this.totalDistanceMeters,
    required this.estimatedDurationMinutes,
    required this.overallRiskScore,
    required this.analysis,
    required this.waypoints,
  });

  // Get safety percentage (inverse of risk)
  double get safetyPercentage => 100.0 - overallRiskScore;

  // Get risk level based on overall score
  RiskLevel get overallRiskLevel {
    if (overallRiskScore < 30) return RiskLevel.low;
    if (overallRiskScore < 60) return RiskLevel.medium;
    return RiskLevel.high;
  }

  // Format distance for display: metres below 1 km, km above.
  String get formattedDistance {
    if (totalDistanceMeters < 1000) {
      return '${totalDistanceMeters.round()} m';
    }
    return '${(totalDistanceMeters / 1000).toStringAsFixed(1)} km';
  }

  // Format duration for display
  String get formattedDuration {
    if (estimatedDurationMinutes < 60) {
      return '$estimatedDurationMinutes min';
    }
    int hours = estimatedDurationMinutes ~/ 60;
    int mins = estimatedDurationMinutes % 60;
    return '${hours}h ${mins}m';
  }

  // Get route type from routeId
  String get routeType => routeId;

  RouteOption copyWith({
    String? routeId,
    bool? isRecommended,
    List<RouteSegment>? segments,
    double? totalDistanceMeters,
    int? estimatedDurationMinutes,
    double? overallRiskScore,
    RouteAnalysis? analysis,
    List<RouteWaypoint>? waypoints,
  }) {
    return RouteOption(
      routeId: routeId ?? this.routeId,
      isRecommended: isRecommended ?? this.isRecommended,
      segments: segments ?? this.segments,
      totalDistanceMeters: totalDistanceMeters ?? this.totalDistanceMeters,
      estimatedDurationMinutes:
          estimatedDurationMinutes ?? this.estimatedDurationMinutes,
      overallRiskScore: overallRiskScore ?? this.overallRiskScore,
      analysis: analysis ?? this.analysis,
      waypoints: waypoints ?? this.waypoints,
    );
  }
}

class RouteSegment {
  final RouteWaypoint start;
  final RouteWaypoint end;
  final double distanceMeters;
  final double riskScore; // 0-100
  final List<RiskZone> nearbyRiskZones;
  final String instruction;

  RouteSegment({
    required this.start,
    required this.end,
    required this.distanceMeters,
    required this.riskScore,
    required this.nearbyRiskZones,
    required this.instruction,
  });

  // Check if this segment passes through any high-risk zones
  bool get isHighRisk => riskScore > 60;
  bool get isMediumRisk => riskScore > 30 && riskScore <= 60;
  bool get isLowRisk => riskScore <= 30;

  RiskLevel get riskLevel {
    if (riskScore < 30) return RiskLevel.low;
    if (riskScore < 60) return RiskLevel.medium;
    return RiskLevel.high;
  }

  // Format distance for display: metres below 1 km, km above.
  String get formattedDistance {
    if (distanceMeters < 1000) {
      return '${distanceMeters.round()} m';
    }
    return '${(distanceMeters / 1000).toStringAsFixed(1)} km';
  }
}

class RouteWaypoint {
  final double latitude;
  final double longitude;
  final String? name;
  final WaypointType type;

  RouteWaypoint({
    required this.latitude,
    required this.longitude,
    this.name,
    required this.type,
  });
}

enum WaypointType {
  start,
  intermediate,
  destination,
}

class RouteAnalysis {
  final String summary;
  final List<String> safetyReasons;
  final List<RiskEvidence> riskEvidence;
  final List<String> avoidedZones;
  final ComparisonData? comparisonWithAlternative;
  /// B2: Crime evidence assessment for this route.
  final CrimeRiskAssessment? crimeAssessment;

  RouteAnalysis({
    required this.summary,
    required this.safetyReasons,
    required this.riskEvidence,
    required this.avoidedZones,
    this.comparisonWithAlternative,
    this.crimeAssessment,
  });

  // Get a concise explanation for the user
  String get briefExplanation {
    if (safetyReasons.isEmpty) {
      return summary;
    }
    return '$summary. ${safetyReasons.first}';
  }
}

class RiskEvidence {
  final String zoneName;
  final RiskLevel riskLevel;
  final String description;
  final double distanceFromRouteMeters;
  final bool routePassesThrough;

  RiskEvidence({
    required this.zoneName,
    required this.riskLevel,
    required this.description,
    required this.distanceFromRouteMeters,
    required this.routePassesThrough,
  });

  String get formattedDistance {
    if (distanceFromRouteMeters < 1000) {
      return '${distanceFromRouteMeters.round()} m';
    }
    return '${(distanceFromRouteMeters / 1000).toStringAsFixed(1)} km';
  }

  String get evidenceStatement {
    if (routePassesThrough) {
      return 'Route passes through $zoneName (${riskLevel.displayName})';
    }
    return '$zoneName is $formattedDistance from route';
  }
}

class ComparisonData {
  final String alternativeRouteName;
  final double riskDifferencePercentage;
  final String reason;

  ComparisonData({
    required this.alternativeRouteName,
    required this.riskDifferencePercentage,
    required this.reason,
  });

  String get comparisonStatement {
    if (riskDifferencePercentage > 0) {
      return 'This route is ${riskDifferencePercentage.toStringAsFixed(0)}% safer than $alternativeRouteName because $reason';
    }
    return 'This route has similar safety to $alternativeRouteName';
  }
}
