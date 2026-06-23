class RiskZone {
  final double latitude;
  final double longitude;
  final double radiusMeters;
  final RiskLevel riskLevel;
  // risk_score and severity come directly from the LatinHypercube CSV (columns 4–5)
  final double riskScore;  // 0-100 composite score
  final int severity;       // 1-5 ordinal severity
  final String zoneName;
  final String description;

  RiskZone({
    required this.latitude,
    required this.longitude,
    required this.radiusMeters,
    required this.riskLevel,
    required this.riskScore,
    required this.severity,
    required this.zoneName,
    required this.description,
  });

  /// CSV column order (8 columns):
  /// 0:latitude  1:longitude  2:radius_meters  3:risk_level
  /// 4:risk_score  5:severity  6:zone_name  7:description
  factory RiskZone.fromCsvRow(List<String> row) {
    return RiskZone(
      latitude: double.parse(row[0]),
      longitude: double.parse(row[1]),
      radiusMeters: double.parse(row[2]),
      riskLevel: _parseRiskLevel(row[3]),
      riskScore: double.parse(row[4]),
      severity: int.parse(row[5]),
      zoneName: row[6],
      description: row[7],
    );
  }

  /// Serialize to a JSON map for local cache storage.
  Map<String, dynamic> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        'radiusMeters': radiusMeters,
        'riskLevel': riskLevel.name,
        'riskScore': riskScore,
        'severity': severity,
        'zoneName': zoneName,
        'description': description,
      };

  /// Deserialize from a JSON map written by [toJson].
  factory RiskZone.fromJson(Map<String, dynamic> json) {
    return RiskZone(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      radiusMeters: (json['radiusMeters'] as num).toDouble(),
      riskLevel: _parseRiskLevel(json['riskLevel'] as String),
      riskScore: (json['riskScore'] as num).toDouble(),
      severity: json['severity'] as int,
      zoneName: json['zoneName'] as String,
      description: json['description'] as String,
    );
  }

  static RiskLevel _parseRiskLevel(String level) {
    switch (level.toLowerCase()) {
      case 'high':
        return RiskLevel.high;
      case 'medium':
        return RiskLevel.medium;
      case 'low':
        return RiskLevel.low;
      default:
        return RiskLevel.medium;
    }
  }

  // Calculate distance from a point to this zone's center
  double distanceFromPoint(double lat, double lon) {
    // Haversine formula for distance calculation
    const double earthRadius = 6371000; // meters
    
    double dLat = _toRadians(latitude - lat);
    double dLon = _toRadians(longitude - lon);
    
    double a = _sin(dLat / 2) * _sin(dLat / 2) +
        _cos(_toRadians(lat)) * _cos(_toRadians(latitude)) *
        _sin(dLon / 2) * _sin(dLon / 2);
    
    double c = 2 * _atan2(_sqrt(a), _sqrt(1 - a));
    
    return earthRadius * c;
  }

  // Check if a point is within this risk zone
  bool containsPoint(double lat, double lon) {
    return distanceFromPoint(lat, lon) <= radiusMeters;
  }

  /// Get risk score based on distance (0-100, higher = more risky).
  /// Uses the CSV-provided [riskScore] as the zone maximum, attenuated
  /// by proximity so that the edge of the zone contributes zero.
  double getRiskScoreForDistance(double distanceMeters) {
    if (distanceMeters > radiusMeters) {
      return 0.0; // Outside the zone
    }

    // Proximity factor: 1.0 at centre, 0.0 at edge
    final double proximityFactor = 1.0 - (distanceMeters / radiusMeters);
    // Use the dataset's own risk_score as the ceiling (not the enum base).
    return riskScore * proximityFactor;
  }

  static double _toRadians(double degrees) => degrees * 3.141592653589793 / 180.0;
  static double _sin(double x) => _sinApprox(x);
  static double _cos(double x) => _sinApprox(x + 3.141592653589793 / 2);
  static double _sqrt(double x) {
    if (x == 0) return 0;
    double guess = x / 2;
    for (int i = 0; i < 10; i++) {
      guess = (guess + x / guess) / 2;
    }
    return guess;
  }
  static double _atan2(double y, double x) {
    if (x > 0) return _atanApprox(y / x);
    if (x < 0 && y >= 0) return _atanApprox(y / x) + 3.141592653589793;
    if (x < 0 && y < 0) return _atanApprox(y / x) - 3.141592653589793;
    if (x == 0 && y > 0) return 3.141592653589793 / 2;
    if (x == 0 && y < 0) return -3.141592653589793 / 2;
    return 0;
  }
  
  static double _sinApprox(double x) {
    // Taylor series approximation for sin
    x = x % (2 * 3.141592653589793);
    if (x > 3.141592653589793) x -= 2 * 3.141592653589793;
    if (x < -3.141592653589793) x += 2 * 3.141592653589793;
    double result = x;
    double term = x;
    for (int n = 1; n < 10; n++) {
      term *= -x * x / ((2 * n) * (2 * n + 1));
      result += term;
    }
    return result;
  }
  
  static double _atanApprox(double x) {
    // Approximation for atan
    if (x.abs() > 1) {
      return (3.141592653589793 / 2) * (x > 0 ? 1 : -1) - _atanApprox(1 / x);
    }
    double result = x;
    double term = x;
    for (int n = 1; n < 10; n++) {
      term *= -x * x;
      result += term / (2 * n + 1);
    }
    return result;
  }
}

enum RiskLevel {
  low(baseScore: 20.0, displayName: 'Low Risk', color: 0xFF4CAF50),
  medium(baseScore: 50.0, displayName: 'Medium Risk', color: 0xFFFFA726),
  high(baseScore: 85.0, displayName: 'High Risk', color: 0xFFF44336);

  final double baseScore;
  final String displayName;
  final int color;

  const RiskLevel({
    required this.baseScore,
    required this.displayName,
    required this.color,
  });
}
