import 'package:flutter/material.dart';
import 'motion_baseline.dart';

/// Labels for the five motion classes used in the dataset
enum MotionLabel {
  normalWalk,
  suddenStop,
  fastTurn,
  shortRun,
  phoneShake;

  /// Human-readable name shown in UI
  String get displayName {
    switch (this) {
      case normalWalk:  return 'Normal Walk';
      case suddenStop:  return 'Sudden Stop';
      case fastTurn:    return 'Fast Turn';
      case shortRun:    return 'Short Run';
      case phoneShake:  return 'Phone Shake';
    }
  }

  /// Short code written into CSV label column
  String get csvKey {
    switch (this) {
      case normalWalk:  return 'normal_walk';
      case suddenStop:  return 'sudden_stop';
      case fastTurn:    return 'fast_turn';
      case shortRun:    return 'short_run';
      case phoneShake:  return 'phone_shake';
    }
  }

  /// Whether this class is expected to trigger an anomaly
  bool get isAnomaly => this != normalWalk;

  /// Icon string for quick reference in UI
  String get emoji {
    switch (this) {
      case normalWalk:  return '🚶';
      case suddenStop:  return '🛑';
      case fastTurn:    return '↩️';
      case shortRun:    return '🏃';
      case phoneShake:  return '📳';
    }
  }

  /// Instruction shown to the user before recording starts
  String get instruction {
    switch (this) {
      case normalWalk:
        return 'Walk at a normal, comfortable pace (1.0–1.5 m/s). Hold the phone naturally in your hand or keep it in a front pocket. Maintain a steady gait — this is the baseline reference class.';
      case suddenStop:
        return 'Walk at a normal pace, then come to a complete, abrupt stop within one step. Wait 1–2 seconds, then repeat. Each stop creates a sharp deceleration impulse (max jerk > 15 m/s³).';
      case fastTurn:
        return 'Walk forward then pivot sharply through a 90–180° turn in less than one second. Keep the phone still in your hand. Repeat every 3–4 steps. Each turn creates a high-kurtosis lateral acceleration spike.';
      case shortRun:
        return 'Start walking, then break into a jog or run (2–4 m/s) for 3–5 seconds, then return to walking. Repeat throughout the session. Running generates 2–5× more energy than walking with step cadence ~150–200 steps/min.';
      case phoneShake:
        return 'Shake the phone vigorously in all directions (up/down, side-to-side, front/back) for 2–3 seconds. Pause briefly, then repeat. This produces chaotic high-amplitude acceleration in all axes.';
    }
  }

  /// Accurate, research-backed description of the motion class and its
  /// accelerometer signature. Used for display in the dataset screen.
  String get shortDescription {
    switch (this) {
      case normalWalk:
        return 'Typical steady walking. Regular periodic oscillation, moderate SMA and low jerk — used as the baseline class.';
      case suddenStop:
        return 'Abrupt stop with a short, high-jerk deceleration spike — a sudden anomaly event.';
      case fastTurn:
        return 'Sharp pivot/turn causing a lateral acceleration spike inside a short window.';
      case shortRun:
        return 'Short burst of running/jogging: higher energy and cadence than walking.';
      case phoneShake:
        return 'Vigorous multi-axis phone shake: chaotic, high-amplitude signal without periodic gait.';
    }
  }

  /// Material icon for each class (used in place of emojis)
  IconData get icon {
    switch (this) {
      case normalWalk:  return Icons.directions_walk_rounded;
      case suddenStop:  return Icons.pan_tool_rounded;
      case fastTurn:    return Icons.rotate_90_degrees_ccw_rounded;
      case shortRun:    return Icons.directions_run_rounded;
      case phoneShake:  return Icons.vibration_rounded;
    }
  }

  static MotionLabel? fromCsvKey(String key) {
    for (final label in MotionLabel.values) {
      if (label.csvKey == key) return label;
    }
    return null;
  }
}

/// A single labeled feature window collected during a dataset session
class LabeledMotionSample {
  final String sessionId;
  final MotionLabel label;
  final MotionWindowFeatures features;

  /// Anomaly score assigned by the in-app detector (null until evaluated)
  double? anomalyScore;
  bool? detectedAsAnomaly;

  LabeledMotionSample({
    required this.sessionId,
    required this.label,
    required this.features,
    this.anomalyScore,
    this.detectedAsAnomaly,
  });

  // ── CSV support ──────────────────────────────────────────────────────────

  static String csvHeader() {
    return 'session_id,label,is_anomaly,timestamp,'
        'mean_magnitude,std_magnitude,variance,sma,'
        'mean_jerk,max_jerk,energy,kurtosis,'
        'peak_magnitude,zero_crossings,'
        'anomaly_score,detected_as_anomaly';
  }

  String toCsvRow() {
    return [
      sessionId,
      label.csvKey,
      label.isAnomaly ? '1' : '0',
      features.timestamp.toIso8601String(),
      features.meanMagnitude.toStringAsFixed(6),
      features.stdMagnitude.toStringAsFixed(6),
      features.variance.toStringAsFixed(6),
      features.sma.toStringAsFixed(6),
      features.meanJerk.toStringAsFixed(6),
      features.maxJerk.toStringAsFixed(6),
      features.energy.toStringAsFixed(6),
      features.kurtosis.toStringAsFixed(6),
      features.peakMagnitude.toStringAsFixed(6),
      features.zeroCrossings.toString(),
      anomalyScore?.toStringAsFixed(6) ?? '',
      detectedAsAnomaly == null
          ? ''
          : (detectedAsAnomaly! ? '1' : '0'),
    ].join(',');
  }
}

/// In-app evaluation metrics for a single class or overall
class ClassMetrics {
  final MotionLabel? label;   // null → aggregate (overall)
  final int tp;
  final int fp;
  final int tn;
  final int fn;
  final int total;
  final double avgLatencyMs;

  ClassMetrics({
    this.label,
    required this.tp,
    required this.fp,
    required this.tn,
    required this.fn,
    required this.total,
    required this.avgLatencyMs,
  });

  double get precision =>
      (tp + fp) == 0 ? 0.0 : tp / (tp + fp);

  double get recall =>
      (tp + fn) == 0 ? 0.0 : tp / (tp + fn);

  double get f1 {
    final p = precision;
    final r = recall;
    return (p + r) == 0 ? 0.0 : 2 * p * r / (p + r);
  }

  /// For normal class: accuracy = tn / total (correctly not flagged)
  double get specificity =>
      (tn + fp) == 0 ? 0.0 : tn / (tn + fp);

  String get labelName => label?.displayName ?? 'Overall';
}

/// Holds evaluation results for all classes
class DatasetEvaluation {
  final List<ClassMetrics> perClass;
  final ClassMetrics overall;
  final int totalSamples;
  final DateTime evaluatedAt;

  DatasetEvaluation({
    required this.perClass,
    required this.overall,
    required this.totalSamples,
    required this.evaluatedAt,
  });
}
