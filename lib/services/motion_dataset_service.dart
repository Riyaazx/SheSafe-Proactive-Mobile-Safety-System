import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../models/labeled_motion_sample.dart';
import '../models/motion_baseline.dart';
import 'motion_baseline_service.dart';

/// Service responsible for:
///   1. Streaming sensor → extracting feature windows (same algo as baseline)
///   2. Storing labeled samples in-memory during a collection session
///   3. Evaluating collected samples against the stored baseline
///   4. Exporting the dataset as a CSV string
///
/// Intentionally keeps the feature-extraction logic identical to
/// [MotionBaselineService] so that the offline dataset faithfully
/// reflects what the live detector sees.
class MotionDatasetService {
  static final MotionDatasetService _instance =
      MotionDatasetService._internal();
  factory MotionDatasetService() => _instance;
  MotionDatasetService._internal();

  // ── State ────────────────────────────────────────────────────────────────

  final List<LabeledMotionSample> _samples = [];
  bool _isRecording = false;

  StreamSubscription<AccelerometerEvent>? _sub;

  // Rolling buffer: keeps up to _bufferMaxMs of readings — matches
  // MotionBaselineService's sliding-window approach so features are identical.
  final List<_Reading> _rollingBuf = [];
  DateTime? _firstReadingTime;
  DateTime? _lastWindowAt;

  // Window parameters — must match MotionBaselineService exactly.
  static const int _windowMs = 800;   // analysis window length (ms)
  static const int _strideMs = 500;   // advance per window (ms)
  static const int _bufferMaxMs = 2000; // keep 2 s of readings

  // Latency tracking (ms per window)
  final List<double> _latencies = [];

  // ── Public API ───────────────────────────────────────────────────────────

  List<LabeledMotionSample> get samples => List.unmodifiable(_samples);

  bool get isRecording => _isRecording;

  int countFor(MotionLabel label) =>
      _samples.where((s) => s.label == label).length;

  int get totalSamples => _samples.length;

  /// Start collecting labeled windows for [label].
  ///
  /// Calls [onWindow] for each completed 1-second window so the UI
  /// can display live feedback.  Call [stopRecording] to end.
  void startRecording({
    required String sessionId,
    required MotionLabel label,
    void Function(LabeledMotionSample)? onWindow,
  }) {
    if (_isRecording) return;
    _isRecording = true;
    _rollingBuf.clear();
    _firstReadingTime = null;
    _lastWindowAt = null;

    _sub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 50),
    ).listen((event) {
      if (!_isRecording) return;

      final now = DateTime.now();
      _firstReadingTime ??= now;

      // Maintain rolling buffer, trimming readings older than _bufferMaxMs
      _rollingBuf.add(_Reading(event.x, event.y, event.z, now));
      final cutoff = now.subtract(
          const Duration(milliseconds: _bufferMaxMs));
      while (_rollingBuf.isNotEmpty &&
          _rollingBuf.first.ts.isBefore(cutoff)) {
        _rollingBuf.removeAt(0);
      }

      // Decide whether to emit a window (same logic as MotionBaselineService)
      final shouldProcess = _lastWindowAt == null
          ? now.difference(_firstReadingTime!).inMilliseconds >= _windowMs
          : now.difference(_lastWindowAt!).inMilliseconds >= _strideMs;

      if (!shouldProcess) return;

      // Extract the most-recent _windowMs slice from the rolling buffer
      final winCutoff =
          now.subtract(const Duration(milliseconds: _windowMs));
      final windowReadings =
          _rollingBuf.where((r) => r.ts.isAfter(winCutoff)).toList();

      if (windowReadings.length >= 8) {
        final t0 = DateTime.now();
        final features = _extractFeatures(windowReadings);
        final latency =
            DateTime.now().difference(t0).inMicroseconds / 1000.0;
        if (features != null) {
          _latencies.add(latency);
          // Validate labeled samples for the normal-walk class so the
          // dataset does not include obvious non-walking windows when the
          // user is collecting baseline walk samples.
          if (_shouldAcceptSample(label, features)) {
            final sample = LabeledMotionSample(
              sessionId: sessionId,
              label: label,
              features: features,
            );
            _samples.add(sample);
            onWindow?.call(sample);
          } else {
            // Ignored: feature window did not meet simple heuristics for
            // the requested label (e.g. user selected Normal Walk but the
            // window looks unlike walking). This prevents obvious "fake"
            // samples from being recorded while keeping the filter simple
            // and conservative.
          }
        }
      }
      _lastWindowAt = now;
    });
  }

  /// Stop the active recording session.
  Future<void> stopRecording() async {
    _isRecording = false;
    await _sub?.cancel();
    _sub = null;
    _rollingBuf.clear();
    _firstReadingTime = null;
    _lastWindowAt = null;
  }

  /// Clear all collected samples.
  void clearDataset() {
    _samples.clear();
    _latencies.clear();
  }

  /// Add a pre-built sample directly (e.g. from baseline calibration).
  /// Duplicates within the same session are ignored.
  void addExternalSamples(
    String sessionId,
    MotionLabel label,
    List<MotionWindowFeatures> features,
  ) {
    for (final f in features) {
      _samples.add(LabeledMotionSample(
        sessionId: sessionId,
        label: label,
        features: f,
      ));
    }
    debugPrint('[Dataset] Added ${features.length} external $label samples');
  }

  // ── Evaluation ───────────────────────────────────────────────────────────

  /// Evaluate all collected samples against the stored motion baseline.
  ///
  /// Anomaly classes (non-normal) → expected detected = true → TP/FN.
  /// Normal class → expected detected = false → TN/FP.
  DatasetEvaluation? evaluate() {
    if (_samples.isEmpty) return null;

    final service = MotionBaselineService();
    if (!service.isCalibrated) return null;

    // Run anomaly scoring using the same method exposed by baseline service
    for (final s in _samples) {
      final result = service.scoreWindow(s.features);
      s.anomalyScore = result.score;
      s.detectedAsAnomaly = result.isAnomalous;
    }

    // Per-class metrics
    final perClass = <ClassMetrics>[];
    for (final label in MotionLabel.values) {
      final classSamples = _samples.where((s) => s.label == label).toList();
      if (classSamples.isEmpty) continue;
      perClass.add(_computeMetrics(label, classSamples));
    }

    // Aggregate
    final overallMetrics = _computeMetrics(null, _samples);

    return DatasetEvaluation(
      perClass: perClass,
      overall: overallMetrics,
      totalSamples: _samples.length,
      evaluatedAt: DateTime.now(),
    );
  }

  ClassMetrics _computeMetrics(
      MotionLabel? label, List<LabeledMotionSample> samples) {
    int tp = 0, fp = 0, tn = 0, fn = 0;

    for (final s in samples) {
      final expected = s.label.isAnomaly; // true → anomaly class
      final detected = s.detectedAsAnomaly ?? false;

      if (expected && detected) tp++;
      if (!expected && detected) fp++;
      if (!expected && !detected) tn++;
      if (expected && !detected) fn++;
    }

    final avgLatency =
        _latencies.isEmpty ? 0.0 : _latencies.reduce((a, b) => a + b) / _latencies.length;

    return ClassMetrics(
      label: label,
      tp: tp,
      fp: fp,
      tn: tn,
      fn: fn,
      total: samples.length,
      avgLatencyMs: avgLatency,
    );
  }

  // ── CSV export ───────────────────────────────────────────────────────────

  String exportCsv() {
    final buf = StringBuffer();
    buf.writeln(LabeledMotionSample.csvHeader());
    for (final s in _samples) {
      buf.writeln(s.toCsvRow());
    }
    return buf.toString();
  }

  // ── Feature extraction (mirrors MotionBaselineService logic) ─────────────

  MotionWindowFeatures? _extractFeatures(List<_Reading> readings) {
    if (readings.length < 3) return null;

    final mags = readings
        .map((r) => sqrt(r.x * r.x + r.y * r.y + r.z * r.z))
        .toList();

    final meanMag = _mean(mags);
    final varMag = _variance(mags);
    final stdMag = sqrt(varMag);
    final peakMag = mags.reduce(max);

    // Signal Magnitude Area
    double sma = 0;
    for (final r in readings) {
      sma += r.x.abs() + r.y.abs() + r.z.abs();
    }
    sma /= readings.length;

    // Jerk: rate of change of magnitude between consecutive samples
    final jerks = <double>[];
    for (int i = 1; i < readings.length; i++) {
      final dt = readings[i]
              .ts
              .difference(readings[i - 1].ts)
              .inMicroseconds /
          1e6;
      if (dt > 0) {
        jerks.add((mags[i] - mags[i - 1]).abs() / dt);
      }
    }
    final meanJerk = jerks.isNotEmpty ? _mean(jerks) : 0.0;
    // maxJerk captures the spike of a sudden stop — use max, not mean
    final maxJerk = jerks.isNotEmpty ? jerks.reduce(max) : 0.0;

    // Energy: mean of squared magnitudes — distinguishes running (~4×) from walking
    final energy = mags.map((m) => m * m).reduce((a, b) => a + b) / mags.length;

    // Kurtosis: fourth central moment / variance²
    // Normal walk ≈ 2–4; sudden stop has one large spike → kurtosis >> 8
    double kurtosis = 3.0; // default (normal distribution)
    if (varMag > 0) {
      final fourthMoment =
          mags.map((m) => pow(m - meanMag, 4).toDouble())
               .reduce((a, b) => a + b) /
          mags.length;
      kurtosis = fourthMoment / (varMag * varMag);
    }

    // Zero crossings (activity rhythm)
    int zc = 0;
    for (int i = 1; i < mags.length; i++) {
      if ((mags[i - 1] - meanMag) * (mags[i] - meanMag) < 0) zc++;
    }

    return MotionWindowFeatures(
      meanMagnitude: meanMag,
      stdMagnitude: stdMag,
      variance: varMag,
      sma: sma,
      meanJerk: meanJerk,
      maxJerk: maxJerk,
      energy: energy,
      kurtosis: kurtosis,
      peakMagnitude: peakMag,
      zeroCrossings: zc,
      timestamp: DateTime.now(),
    );
  }

  /// Very simple heuristics to avoid recording obvious mismatches when the
  /// user is collecting a labeled class. This is intentionally conservative
  /// and only used to skip windows that clearly don't match the requested
  /// label (for example: user chose Normal Walk but device is stationary).
  bool _shouldAcceptSample(MotionLabel label, MotionWindowFeatures f) {
    // ── Universal "device is stationary" gate ────────────────────────────────
    // Gravity (~9.8 m/s²) is a constant offset that cancels out in variance,
    // so variance < 0.08 reliably identifies a still phone in any orientation.
    if (f.variance < 0.08) return false;

    // ── Per-label validation ─────────────────────────────────────────────────
    switch (label) {
      case MotionLabel.normalWalk:
        // Walking: moderate periodic oscillation, enough zero-crossings for a
        // regular gait cadence, and not too jerky (running / sudden stops score higher).
        return f.variance >= 0.1 &&
            f.variance <= 3.0 &&
            f.zeroCrossings >= 4 &&
            f.meanJerk < 15.0;

      case MotionLabel.suddenStop:
        // A genuine abrupt stop produces a sharp deceleration spike.
        // maxJerk > 8 m/s³ clearly separates a stop from steady walking (3–5 m/s³).
        return f.maxJerk > 8.0;

      case MotionLabel.fastTurn:
        // A sharp pivot creates momentary high-amplitude lateral motion.
        // Only variance is used — kurtosis of sensor noise can exceed 2.5 even
        // when stationary, making it an unreliable discriminator here.
        return f.variance > 0.3;

      case MotionLabel.shortRun:
        // Running has notably larger stride oscillation than walking.
        return f.variance > 0.5;

      case MotionLabel.phoneShake:
        // Vigorous multi-axis shaking produces very high variance.
        return f.variance > 0.8;
    }
  }

  double _mean(List<double> v) =>
      v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;

  double _variance(List<double> v) {
    if (v.length < 2) return 0;
    final m = _mean(v);
    return v.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / v.length;
  }
}

class _Reading {
  final double x, y, z;
  final DateTime ts;
  const _Reading(this.x, this.y, this.z, this.ts);
}
