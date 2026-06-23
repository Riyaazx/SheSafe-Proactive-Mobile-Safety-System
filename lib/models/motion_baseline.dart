/// Model representing personalized motion baseline statistics
/// 
/// This stores aggregated motion statistics per user to enable
/// personalized anomaly detection without storing raw sensor data.
class MotionBaseline {
  /// Mean magnitude of accelerometer readings (m/s²)
  final double meanMagnitude;
  
  /// Variance of accelerometer magnitude
  final double varianceMagnitude;
  
  /// Standard deviation of accelerometer magnitude
  final double stdMagnitude;
  
  /// Mean step rate (steps per second) from calibration
  final double stepRate;
  
  /// Variance of step intervals
  final double stepRateVariance;
  
  /// Mean jerk (rate of change of acceleration)
  final double meanJerk;
  
  /// Variance of jerk magnitude
  final double jerkVariance;
  
  /// Signal magnitude area (SMA) - overall activity level
  final double sma;
  
  /// Number of calibration samples collected
  final int sampleCount;
  
  /// When the baseline was last updated
  final DateTime lastUpdated;
  
  /// Minimum feature windows required for computing baseline statistics.
  /// Just need enough data-points for mean/variance; steps are the real gate.
  static const int minCalibrationWindows = 3;
  
  /// Window size for feature extraction (milliseconds)
  static const int windowSizeMs = 1000;
  
  /// Number of windows that must show anomaly before triggering.
  /// 5 × 500 ms stride = 2.5 s of sustained unusual motion required,
  /// preventing brief handling or single-event spikes from escalating.
  static const int anomalyPersistenceThreshold = 5;

  MotionBaseline({
    required this.meanMagnitude,
    required this.varianceMagnitude,
    required this.stdMagnitude,
    required this.stepRate,
    required this.stepRateVariance,
    required this.meanJerk,
    required this.jerkVariance,
    required this.sma,
    required this.sampleCount,
    required this.lastUpdated,
  });

  /// Create an empty baseline for new users
  factory MotionBaseline.empty() {
    return MotionBaseline(
      meanMagnitude: 0.0,
      varianceMagnitude: 0.0,
      stdMagnitude: 0.0,
      stepRate: 0.0,
      stepRateVariance: 0.0,
      meanJerk: 0.0,
      jerkVariance: 0.0,
      sma: 0.0,
      sampleCount: 0,
      lastUpdated: DateTime.now(),
    );
  }

  /// Check if baseline has enough data for reliable detection
  bool get isCalibrated => sampleCount >= minCalibrationWindows;

  /// Create from JSON
  factory MotionBaseline.fromJson(Map<String, dynamic> json) {
    return MotionBaseline(
      meanMagnitude: (json['meanMagnitude'] as num?)?.toDouble() ?? 0.0,
      varianceMagnitude: (json['varianceMagnitude'] as num?)?.toDouble() ?? 0.0,
      stdMagnitude: (json['stdMagnitude'] as num?)?.toDouble() ?? 0.0,
      stepRate: (json['stepRate'] as num?)?.toDouble() ?? 0.0,
      stepRateVariance: (json['stepRateVariance'] as num?)?.toDouble() ?? 0.0,
      meanJerk: (json['meanJerk'] as num?)?.toDouble() ?? 0.0,
      jerkVariance: (json['jerkVariance'] as num?)?.toDouble() ?? 0.0,
      sma: (json['sma'] as num?)?.toDouble() ?? 0.0,
      sampleCount: (json['sampleCount'] as num?)?.toInt() ?? 0,
      lastUpdated: json['lastUpdated'] != null 
          ? DateTime.parse(json['lastUpdated'] as String)
          : DateTime.now(),
    );
  }

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'meanMagnitude': meanMagnitude,
      'varianceMagnitude': varianceMagnitude,
      'stdMagnitude': stdMagnitude,
      'stepRate': stepRate,
      'stepRateVariance': stepRateVariance,
      'meanJerk': meanJerk,
      'jerkVariance': jerkVariance,
      'sma': sma,
      'sampleCount': sampleCount,
      'lastUpdated': lastUpdated.toIso8601String(),
    };
  }

  /// Create a copy with updated values
  MotionBaseline copyWith({
    double? meanMagnitude,
    double? varianceMagnitude,
    double? stdMagnitude,
    double? stepRate,
    double? stepRateVariance,
    double? meanJerk,
    double? jerkVariance,
    double? sma,
    int? sampleCount,
    DateTime? lastUpdated,
  }) {
    return MotionBaseline(
      meanMagnitude: meanMagnitude ?? this.meanMagnitude,
      varianceMagnitude: varianceMagnitude ?? this.varianceMagnitude,
      stdMagnitude: stdMagnitude ?? this.stdMagnitude,
      stepRate: stepRate ?? this.stepRate,
      stepRateVariance: stepRateVariance ?? this.stepRateVariance,
      meanJerk: meanJerk ?? this.meanJerk,
      jerkVariance: jerkVariance ?? this.jerkVariance,
      sma: sma ?? this.sma,
      sampleCount: sampleCount ?? this.sampleCount,
      lastUpdated: lastUpdated ?? this.lastUpdated,
    );
  }

  @override
  String toString() {
    return 'MotionBaseline(magnitude: $meanMagnitude±$stdMagnitude, '
        'stepRate: $stepRate, samples: $sampleCount, '
        'calibrated: $isCalibrated)';
  }
}

/// Represents extracted features from a motion window
class MotionWindowFeatures {
  /// Mean magnitude in this window
  final double meanMagnitude;

  /// Standard deviation of magnitude
  final double stdMagnitude;

  /// Variance of magnitude
  final double variance;

  /// Signal magnitude area
  final double sma;

  /// Mean jerk (change in acceleration)
  final double meanJerk;

  /// Peak (maximum) instantaneous jerk — much more sensitive to sudden stops
  /// than mean jerk, which averages the spike away.
  final double maxJerk;

  /// Signal energy: mean of squared magnitudes.
  /// Running generates ~2–4× the energy of walking.
  final double energy;

  /// Kurtosis: fourth central moment / variance².
  /// Normal walk ≈ 2–4; sudden stop has one large spike → kurtosis > 8.
  final double kurtosis;

  /// Peak magnitude in window
  final double peakMagnitude;

  /// Number of zero crossings (activity indicator)
  final int zeroCrossings;

  /// Timestamp of this window
  final DateTime timestamp;

  MotionWindowFeatures({
    required this.meanMagnitude,
    required this.stdMagnitude,
    required this.variance,
    required this.sma,
    required this.meanJerk,
    this.maxJerk = 0.0,
    this.energy = 0.0,
    this.kurtosis = 3.0,
    required this.peakMagnitude,
    required this.zeroCrossings,
    required this.timestamp,
  });

  @override
  String toString() {
    return 'WindowFeatures(mag: $meanMagnitude±$stdMagnitude, '
        'peak: $peakMagnitude, jerk: $meanJerk, maxJerk: $maxJerk, '
        'energy: $energy, kurtosis: $kurtosis)';
  }
}

/// Represents an anomaly detection result
class AnomalyResult {
  /// Overall anomaly score (0-1, higher = more anomalous)
  final double score;
  
  /// Whether this is considered anomalous based on threshold
  final bool isAnomalous;
  
  /// Deviation from baseline in standard deviations
  final double deviationSigma;
  
  /// Contributing factors to the anomaly
  final Map<String, double> factorScores;
  
  /// Human-readable description
  final String description;
  
  /// Timestamp of detection
  final DateTime timestamp;

  AnomalyResult({
    required this.score,
    required this.isAnomalous,
    required this.deviationSigma,
    required this.factorScores,
    required this.description,
    required this.timestamp,
  });

  /// Create a normal (non-anomalous) result
  factory AnomalyResult.normal() {
    return AnomalyResult(
      score: 0.0,
      isAnomalous: false,
      deviationSigma: 0.0,
      factorScores: {},
      description: 'Movement within normal range',
      timestamp: DateTime.now(),
    );
  }

  @override
  String toString() {
    return 'AnomalyResult(score: ${score.toStringAsFixed(2)}, '
        'anomalous: $isAnomalous, sigma: ${deviationSigma.toStringAsFixed(1)})';
  }
}
