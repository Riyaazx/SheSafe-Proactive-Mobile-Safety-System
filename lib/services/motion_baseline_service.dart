import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/motion_baseline.dart';

/// Service for personalized motion baseline tracking and anomaly detection
/// 
/// Privacy-focused: Only stores aggregated statistics, never raw sensor data.
/// Implements Isolation Forest-inspired anomaly scoring for detecting
/// movement patterns that deviate significantly from the user's baseline.
class MotionBaselineService {
  static final MotionBaselineService _instance = MotionBaselineService._internal();
  factory MotionBaselineService() => _instance;
  MotionBaselineService._internal();

  final _secureStorage = const FlutterSecureStorage();
  static const String _baselineKey = 'motion_baseline_v1';
  static const String _sensitivityKey = 'motion_sensitivity_threshold';

  // Baseline data
  MotionBaseline? _baseline;
  bool _isInitialized = false;

  // Live monitoring state
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  bool _isMonitoring = false;
  bool _isCalibrating = false;
  Completer<void>? _calibrationCompleter;
  Timer? _calibrationTimer;
  Timer? _progressTimer;

  // Raw readings buffer — sliding buffer keeps up to 3 seconds of data
  final List<_AccelReading> _currentWindowReadings = [];
  DateTime? _windowStartTime;
  DateTime? _lastWindowProcessedAt;  // For sliding window stride

  // ── Continuous step detection (completely independent of windows) ──
  // We keep the last 3 magnitude samples for local-max peak detection.
  // When a peak is found and the interval from the previous peak is
  // 350–900 ms, we count one step immediately.  No windows involved.
  final List<double> _peakBufMag = [];       // last 3 magnitudes
  final List<DateTime> _peakBufTime = [];    // last 3 timestamps
  DateTime? _lastStepTime;
  double _magEma = 0;          // running EMA of magnitude for adaptive threshold
  bool _magEmaInit = false;

  // Feature history for calibration (not persisted)
  final List<MotionWindowFeatures> _calibrationFeatures = [];

  // Features from the most recent successful calibration — kept so external
  // services (e.g. MotionDatasetService) can reuse them as labeled samples.
  final List<MotionWindowFeatures> _lastCalibrationFeatures = [];

  // Anomaly persistence tracking
  final List<AnomalyResult> _recentAnomalies = [];
  int _consecutiveAnomalyWindows = 0;
  AnomalyResult? _lastAnomalyResult;
  final _anomalyResultController = StreamController<AnomalyResult>.broadcast();

  // Step counting during calibration
  int _calibrationStepCount = 0;
  int _walkingWindowCount = 0;

  // Callbacks
  void Function(MotionWindowFeatures)? onWindowProcessed;
  void Function(AnomalyResult)? onAnomalyDetected;
  void Function(bool)? onMotionConcernTriggered;
  void Function(double)? onCalibrationProgress;
  void Function(String)? onCalibrationFailed;
  /// Reports (walkingSamples, totalSteps) so the UI can show live step count
  void Function(int walkingSamples, int totalSteps)? onStepUpdate;

  // Configuration
  /// Sliding window: analyse the most recent [_windowDurationMs] of data
  /// but advance the window by [_windowStrideMs] each time (50% overlap).
  static const int _windowDurationMs = 1500; // 1.5 s analysis window
  static const int _windowStrideMs = 500;    // advance every 0.5 s
  static const int _bufferMaxMs = 3000;      // keep 3 s of readings
  double _anomalyThreshold = 0.7;
  static const int _maxAnomalyHistory = 10;
  static const double _baselineLearningRate = 0.1;

  /// Minimum standard deviation (m/s²) of overall magnitude.
  /// Sitting phone ≈ 0.01–0.08; walking ≈ 0.15+.
  static const double _walkingStdThreshold = 0.1;

  /// Maximum overall peak magnitude (m/s²).  Walking < 25; shaking 30–60+.
  static const double _walkingPeakMagMax = 30.0;

  /// Maximum mean jerk (m/s³).  Walking < 15; shaking 25–100+.
  static const double _walkingJerkMax = 25.0;

  /// Minimum total real steps required before we accept a calibration.
  static const int requiredSteps = 20;

  /// Initialize the service and load stored baseline
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      final storedJson = await _secureStorage.read(key: _baselineKey);
      if (storedJson != null) {
        final json = jsonDecode(storedJson) as Map<String, dynamic>;
        _baseline = MotionBaseline.fromJson(json);
        debugPrint('✅ Motion baseline loaded: $_baseline');
      } else {
        _baseline = MotionBaseline.empty();
        debugPrint('📊 No stored baseline, starting fresh');
      }
      // Load saved sensitivity threshold
      final savedThreshold = await _secureStorage.read(key: _sensitivityKey);
      if (savedThreshold != null) {
        _anomalyThreshold = double.tryParse(savedThreshold) ?? 0.7;
      }
      _isInitialized = true;
    } catch (e) {
      debugPrint('❌ Error loading motion baseline: $e');
      _baseline = MotionBaseline.empty();
      _isInitialized = true;
    }
  }

  /// Current anomaly threshold (0.6 = high sensitivity, 0.7 = normal, 0.8 = low)
  double get anomalyThreshold => _anomalyThreshold;

  /// Update and persist the anomaly threshold.
  Future<void> setAnomalyThreshold(double threshold) async {
    _anomalyThreshold = threshold.clamp(0.5, 0.9);
    await _secureStorage.write(
        key: _sensitivityKey, value: _anomalyThreshold.toString());
    debugPrint('🎚️ Motion sensitivity threshold set to $_anomalyThreshold');
  }

  /// Get current baseline
  MotionBaseline? get baseline => _baseline;

  /// Check if baseline is calibrated
  bool get isCalibrated => _baseline?.isCalibrated ?? false;

  /// Check if currently monitoring
  bool get isMonitoring => _isMonitoring;

  /// Check if currently calibrating
  bool get isCalibrating => _isCalibrating;

  /// Save baseline to secure storage
  Future<void> _saveBaseline() async {
    if (_baseline == null) return;
    
    try {
      final json = jsonEncode(_baseline!.toJson());
      await _secureStorage.write(key: _baselineKey, value: json);
      debugPrint('💾 Motion baseline saved');
    } catch (e) {
      debugPrint('❌ Error saving motion baseline: $e');
    }
  }

  /// Start baseline calibration
  /// 
  /// Collects motion data for [durationSeconds] to establish
  /// the user's personalized baseline.
  Future<void> startCalibration(int durationSeconds) async {
    if (_isCalibrating) return;
    if (!_isInitialized) await initialize();

    _isCalibrating = true;
    _calibrationFeatures.clear();
    _currentWindowReadings.clear();
    _windowStartTime = null;
    _calibrationCompleter = Completer<void>();
    _calibrationStepCount = 0;
    _walkingWindowCount = 0;
    _lastWindowProcessedAt = null;
    // Reset continuous step detector
    _peakBufMag.clear();
    _peakBufTime.clear();
    _lastStepTime = null;
    _consecutiveValidPeaks = 0;
    _magEma = 0;
    _magEmaInit = false;

    debugPrint('🎯 Starting motion baseline calibration for ${durationSeconds}s');

    final startTime = DateTime.now();
    int windowsCollected = 0;

    // Drive completion with a Timer — never relies on sensor events for timing
    _calibrationTimer = Timer(Duration(seconds: durationSeconds), () {
      if (!_calibrationCompleter!.isCompleted) {
        debugPrint('⏱️ Calibration timer fired after ${durationSeconds}s, '
            'windows=$windowsCollected');
        _calibrationCompleter!.complete();
      }
    });

    // Also fire a periodic progress tick independent of sensor rate
    _progressTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!_isCalibrating) return;
      final elapsed = DateTime.now().difference(startTime).inMilliseconds;
      final progress = (elapsed / (durationSeconds * 1000)).clamp(0.0, 1.0);
      onCalibrationProgress?.call(progress);
    });

    // 50 ms sampling → ~20 readings/sec, plenty to fill a 1-second window
    _accelerometerSubscription = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 50),
    ).listen((event) {
      if (!_isCalibrating) return;

      _addReading(event);

      // Continuous step detection (every reading, no windows)
      _checkContinuousStep(event);

      // Window-based feature extraction (for baseline quality only)
      if (_shouldProcessWindow()) {
        final windowReadings = _getWindowReadings();
        if (windowReadings.length >= 8) {
          final features = _extractFeaturesFrom(windowReadings);
          if (features != null) {
            // Walking validation only gates feature collection, not steps
            final failReasons = <String>[];
            if (features.stdMagnitude < _walkingStdThreshold) {
              failReasons.add('std too low');
            }
            if (features.peakMagnitude > _walkingPeakMagMax) {
              failReasons.add('peak too high');
            }
            if (features.meanJerk > _walkingJerkMax) {
              failReasons.add('jerk too high');
            }

            if (failReasons.isEmpty) {
              _calibrationFeatures.add(features);
              _walkingWindowCount++;
              windowsCollected++;
              onWindowProcessed?.call(features);
              onStepUpdate?.call(_walkingWindowCount, _calibrationStepCount);
              debugPrint('Walking sample $windowsCollected - steps_so_far=$_calibrationStepCount');
            }
          }
        }
        _advanceWindow();
      }
    });

    // Wait for the timer (or cancel signal)
    try {
      await _calibrationCompleter!.future;
      await _finishCalibration();
    } catch (_) {
      // Cancelled externally — _finishCalibration already skipped
      debugPrint('🛑 Calibration was cancelled, skipping finalization');
    }
  }

  /// Finish calibration and compute baseline
  Future<void> _finishCalibration() async {
    _calibrationTimer?.cancel();
    _progressTimer?.cancel();
    _calibrationTimer = null;
    _progressTimer = null;
    await _accelerometerSubscription?.cancel();
    _accelerometerSubscription = null;

    // ── Validate enough walking was detected ───────────────────────────
    // Steps are the primary gate — they prove real walking happened.
    // Feature windows are secondary; we just need a few for statistics.
    if (_calibrationStepCount < requiredSteps) {
      final msg = 'Only $_calibrationStepCount steps detected '
          '(need $requiredSteps). '
          'Please walk steadily for the full calibration.';
      debugPrint('⚠️ $msg');
      onCalibrationFailed?.call(msg);
      _isCalibrating = false;
      return;
    }

    if (_calibrationFeatures.length < MotionBaseline.minCalibrationWindows) {
      final msg = 'Not enough motion data collected '
          '(${_calibrationFeatures.length} feature windows). '
          'Try again while walking.';
      debugPrint('⚠️ $msg');
      onCalibrationFailed?.call(msg);
      _isCalibrating = false;
      return;
    }

    // Compute baseline statistics from collected features
    final magnitudes = _calibrationFeatures.map((f) => f.meanMagnitude).toList();
    final jerks = _calibrationFeatures.map((f) => f.meanJerk).toList();
    final smas = _calibrationFeatures.map((f) => f.sma).toList();

    final meanMag = _mean(magnitudes);
    final varMag = _variance(magnitudes);
    final stdMag = sqrt(varMag);

    final meanJerk = _mean(jerks);
    final jerkVar = _variance(jerks);

    final meanSma = _mean(smas);

    // Estimate step rate from zero crossings
    final zeroCrossings = _calibrationFeatures.map((f) => f.zeroCrossings.toDouble()).toList();
    final stepRate = _mean(zeroCrossings) / (_windowDurationMs / 1000);
    final stepRateVar = _variance(zeroCrossings.map((z) => z / (_windowDurationMs / 1000)).toList());

    _baseline = MotionBaseline(
      meanMagnitude: meanMag,
      varianceMagnitude: varMag,
      stdMagnitude: stdMag,
      stepRate: stepRate,
      stepRateVariance: stepRateVar,
      meanJerk: meanJerk,
      jerkVariance: jerkVar,
      sma: meanSma,
      sampleCount: _calibrationFeatures.length,
      lastUpdated: DateTime.now(),
    );

    await _saveBaseline();
    // Keep a copy for external use (e.g. seeding the motion dataset)
    _lastCalibrationFeatures
      ..clear()
      ..addAll(_calibrationFeatures);
    _calibrationFeatures.clear();
    _isCalibrating = false;

    debugPrint('✅ Baseline calibration complete: $_baseline');
  }

  /// Start live monitoring for anomalies
  void startMonitoring() {
    if (_isMonitoring || _isCalibrating) return;
    if (!_isInitialized) {
      debugPrint('⚠️ Service not initialized');
      return;
    }

    _isMonitoring = true;
    _currentWindowReadings.clear();
    _windowStartTime = null;
    _consecutiveAnomalyWindows = 0;
    _recentAnomalies.clear();

    debugPrint('👁️ Started motion monitoring');

    _accelerometerSubscription = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 50),
    ).listen((event) {
      if (!_isMonitoring) return;

      _addReading(event);

      if (_shouldProcessWindow()) {
        final windowReadings = _getWindowReadings();
        if (windowReadings.length >= 8) {
          final features = _extractFeaturesFrom(windowReadings);
          if (features != null) {
            onWindowProcessed?.call(features);
            
            // Score for anomaly
            final anomalyResult = _computeAnomalyScore(features);
            _handleAnomalyResult(anomalyResult);
            
            // Update baseline adaptively (slow learning)
            if (!anomalyResult.isAnomalous) {
              _updateBaselineAdaptively(features);
            }
          }
        }
        _advanceWindow();
      }
    });
  }

  /// Stop monitoring
  Future<void> stopMonitoring() async {
    _isMonitoring = false;
    await _accelerometerSubscription?.cancel();
    _accelerometerSubscription = null;
    _currentWindowReadings.clear();
    _lastWindowProcessedAt = null;
    _peakBufMag.clear();
    _peakBufTime.clear();
    _lastStepTime = null;
    _consecutiveValidPeaks = 0;
    _magEma = 0;
    _magEmaInit = false;
    debugPrint('⏹️ Stopped motion monitoring');
  }

  /// Cancel calibration
  Future<void> cancelCalibration() async {
    _isCalibrating = false;
    _calibrationTimer?.cancel();
    _progressTimer?.cancel();
    _calibrationTimer = null;
    _progressTimer = null;
    // Unblock startCalibration if it's awaiting the completer
    if (_calibrationCompleter != null && !_calibrationCompleter!.isCompleted) {
      _calibrationCompleter!.completeError('cancelled');
    }
    await _accelerometerSubscription?.cancel();
    _accelerometerSubscription = null;
    _calibrationFeatures.clear();
    _currentWindowReadings.clear();
    _peakBufMag.clear();
    _peakBufTime.clear();
    _lastStepTime = null;
    _consecutiveValidPeaks = 0;
    _magEma = 0;
    _magEmaInit = false;
    debugPrint('❌ Calibration cancelled');
  }

  // ===== Continuous Step Detection =====

  /// Called on every accelerometer reading.  Maintains a tiny 3-sample
  /// buffer and checks whether the middle sample is a local maximum.  If
  /// the interval since the previous accepted step is 350-900 ms the peak
  /// is counted as one step immediately, with no window boundaries.
  ///
  /// To avoid false positives while sitting, we:
  ///   - Require peak >= EMA + 0.35 m/s²  (sitting noise is ~±0.05)
  ///   - Don't count the very first peak (it only seeds the cadence chain)
  ///   - Require 2 consecutive valid-cadence peaks before counting begins
  int _consecutiveValidPeaks = 0;   // how many valid-cadence peaks in a row

  void _checkContinuousStep(AccelerometerEvent e) {
    final mag = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    final now = DateTime.now();

    // Update exponential moving average (time-constant ~ 20 samples = 1 s)
    if (!_magEmaInit) {
      _magEma = mag;
      _magEmaInit = true;
    } else {
      _magEma = _magEma * 0.95 + mag * 0.05;
    }

    // Push into 3-sample ring buffer
    _peakBufMag.add(mag);
    _peakBufTime.add(now);
    if (_peakBufMag.length > 3) {
      _peakBufMag.removeAt(0);
      _peakBufTime.removeAt(0);
    }
    if (_peakBufMag.length < 3) return; // need 3 samples

    // Is the middle sample a local maximum?
    final prev = _peakBufMag[0];
    final curr = _peakBufMag[1];
    final next = _peakBufMag[2];
    if (curr <= prev || curr <= next) return; // not a peak

    // Peak must be meaningfully above the running average.
    // Sitting: magnitude hovers at ~9.81 +/- 0.05 -> never exceeds +0.35.
    // Walking: foot-strike peaks reach +0.3 to 1.5 above mean.
    if (curr < _magEma + 0.35) return;

    final peakTime = _peakBufTime[1];

    if (_lastStepTime == null) {
      // First qualifying peak ever - just seed the cadence chain, don't count
      _lastStepTime = peakTime;
      _consecutiveValidPeaks = 0;
      debugPrint('Peak seed (mag=${curr.toStringAsFixed(2)}, ema=${_magEma.toStringAsFixed(2)})');
      return;
    }

    final intervalMs = peakTime.difference(_lastStepTime!).inMilliseconds;

    // Valid walking cadence: 350-900 ms per step
    // ( ~67-171 steps/min covers slow stroll to brisk walk )
    if (intervalMs >= 350 && intervalMs <= 900) {
      _lastStepTime = peakTime;
      _consecutiveValidPeaks++;

      // Require at least 2 consecutive valid-cadence peaks before counting.
      // This filters out random one-off movements while sitting.
      if (_consecutiveValidPeaks >= 2) {
        _calibrationStepCount++;
        debugPrint('Step #$_calibrationStepCount '
            '(interval=${intervalMs}ms, mag=${curr.toStringAsFixed(2)})');
        if (_isCalibrating) {
          onStepUpdate?.call(_walkingWindowCount, _calibrationStepCount);
        }
      } else {
        debugPrint('Peak valid-cadence #$_consecutiveValidPeaks '
            '(interval=${intervalMs}ms, waiting for 2 consecutive)');
      }
    } else if (intervalMs > 900) {
      // Cadence chain broken (paused or first step after idle).
      // Re-seed; don't count.
      _lastStepTime = peakTime;
      _consecutiveValidPeaks = 0;
    }
    // intervalMs < 350 -> too fast (vibration/shaking) -> ignore
  }
  // ===== Private Methods =====

  void _addReading(AccelerometerEvent event) {
    final reading = _AccelReading(
      x: event.x,
      y: event.y,
      z: event.z,
      timestamp: DateTime.now(),
    );
    _windowStartTime ??= reading.timestamp;
    _currentWindowReadings.add(reading);

    // Trim buffer: drop readings older than _bufferMaxMs
    final cutoff =
        reading.timestamp.subtract(const Duration(milliseconds: _bufferMaxMs));
    while (_currentWindowReadings.isNotEmpty &&
        _currentWindowReadings.first.timestamp.isBefore(cutoff)) {
      _currentWindowReadings.removeAt(0);
    }
  }

  bool _shouldProcessWindow() {
    if (_currentWindowReadings.isEmpty) return false;
    final now = DateTime.now();
    // First window: wait until we have _windowDurationMs of data
    if (_lastWindowProcessedAt == null) {
      if (_windowStartTime == null) return false;
      return now.difference(_windowStartTime!).inMilliseconds >= _windowDurationMs;
    }
    // Subsequent windows: advance by _windowStrideMs
    return now.difference(_lastWindowProcessedAt!).inMilliseconds >= _windowStrideMs;
  }

  /// Return the most recent _windowDurationMs of readings from the buffer.
  List<_AccelReading> _getWindowReadings() {
    if (_currentWindowReadings.isEmpty) return [];
    final now = _currentWindowReadings.last.timestamp;
    final cutoff =
        now.subtract(const Duration(milliseconds: _windowDurationMs));
    return _currentWindowReadings
        .where((r) => r.timestamp.isAfter(cutoff))
        .toList();
  }

  void _advanceWindow() {
    _lastWindowProcessedAt = DateTime.now();
    // Don’t clear _currentWindowReadings — the sliding buffer trims in _addReading
  }

  /// Extract features from the given readings window
  MotionWindowFeatures? _extractFeaturesFrom(List<_AccelReading> readings) {
    if (readings.length < 3) return null;
    
    // Compute magnitudes
    final magnitudes = readings.map((r) => sqrt(r.x * r.x + r.y * r.y + r.z * r.z)).toList();
    
    // Basic statistics
    final meanMag = _mean(magnitudes);
    final varMag = _variance(magnitudes);
    final stdMag = sqrt(varMag);
    final peakMag = magnitudes.reduce(max);

    // Signal Magnitude Area (sum of absolute values)
    double sma = 0;
    for (final r in readings) {
      sma += r.x.abs() + r.y.abs() + r.z.abs();
    }
    sma /= readings.length;

    // Jerk (rate of change of acceleration)
    final jerks = <double>[];
    for (int i = 1; i < readings.length; i++) {
      final dt = readings[i].timestamp.difference(readings[i - 1].timestamp).inMilliseconds / 1000.0;
      if (dt > 0) {
        final prevMag = magnitudes[i - 1];
        final currMag = magnitudes[i];
        jerks.add((currMag - prevMag).abs() / dt);
      }
    }
    final meanJerk = jerks.isNotEmpty ? _mean(jerks) : 0.0;
    // maxJerk: the single largest jerk in the window — a sudden stop produces
    // a momentary spike that the mean completely hides.
    final maxJerk = jerks.isNotEmpty ? jerks.reduce(max) : 0.0;

    // Energy: mean squared magnitude — running has ~2–4× more energy than walking.
    final energy = magnitudes
        .map((m) => m * m)
        .reduce((a, b) => a + b) /
        magnitudes.length;

    // Kurtosis: fourth central moment / variance².
    // Normal walk ≈ 2–4; sudden stop produces one large spike → kurtosis > 8.
    double kurtosis = 3.0; // default (normal distribution behaviour)
    if (varMag > 0) {
      final fourthMoment = magnitudes
          .map((m) => pow(m - meanMag, 4).toDouble())
          .reduce((a, b) => a + b) /
          magnitudes.length;
      kurtosis = fourthMoment / (varMag * varMag);
    }

    // Zero crossings (using deviation from mean as proxy)
    int zeroCrossings = 0;
    for (int i = 1; i < magnitudes.length; i++) {
      final prev = magnitudes[i - 1] - meanMag;
      final curr = magnitudes[i] - meanMag;
      if (prev * curr < 0) zeroCrossings++;
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
      zeroCrossings: zeroCrossings,
      timestamp: DateTime.now(),
    );
  }

  /// Compute anomaly score using Isolation Forest-inspired approach
  /// 
  /// Returns a score between 0 (normal) and 1 (highly anomalous)
  AnomalyResult _computeAnomalyScore(MotionWindowFeatures features) {
    if (_baseline == null || !_baseline!.isCalibrated) {
      return AnomalyResult.normal();
    }

    // Guard: a phone with negligible movement cannot represent a safety threat.
    // Sitting still produces stdMagnitude << 0.1; walking produces >= 0.15.
    // This prevents false positives when the phone is resting on a surface.
    if (features.stdMagnitude < _walkingStdThreshold) {
      return AnomalyResult.normal();
    }

    final baseline = _baseline!;
    final factorScores = <String, double>{};

    // All factor deviations are ONE-DIRECTIONAL: only flag when the current
    // measurement EXCEEDS the walking baseline. Being below baseline (less
    // movement than usual) is not a safety concern and must never score.

    // 1. Magnitude deviation score — only upward deviation is anomalous
    final magDeviation = features.meanMagnitude > baseline.meanMagnitude
        ? features.meanMagnitude - baseline.meanMagnitude
        : 0.0;
    final magSigma = baseline.stdMagnitude > 0
        ? magDeviation / baseline.stdMagnitude
        : 0.0;
    factorScores['magnitude'] = _sigmaToScore(magSigma);

    // 2. Variability deviation score — only MORE variable than baseline
    final varDeviation = features.variance > baseline.varianceMagnitude
        ? features.variance - baseline.varianceMagnitude
        : 0.0;
    final varSigma = baseline.varianceMagnitude > 0
        ? varDeviation / baseline.varianceMagnitude
        : 0.0;
    factorScores['variability'] = _sigmaToScore(varSigma);

    // 3. Mean jerk deviation score — only HIGHER jerk than baseline
    final jerkStd = sqrt(baseline.jerkVariance);
    final jerkDeviation = features.meanJerk > baseline.meanJerk
        ? features.meanJerk - baseline.meanJerk
        : 0.0;
    final jerkSigma = jerkStd > 0 ? jerkDeviation / jerkStd : 0.0;
    factorScores['jerk'] = _sigmaToScore(jerkSigma);

    // 4. Activity level deviation (SMA) — only MORE active than baseline
    final smaDeviation = features.sma > baseline.sma
        ? features.sma - baseline.sma
        : 0.0;
    final smaSigma = baseline.sma > 0 ? smaDeviation / baseline.sma : 0.0;
    factorScores['activity'] = _sigmaToScore(smaSigma);

    // 5. Peak magnitude anomaly (already directional)
    final expectedPeak = baseline.meanMagnitude + 3 * baseline.stdMagnitude;
    final peakScore = features.peakMagnitude > expectedPeak
        ? (features.peakMagnitude - expectedPeak) / expectedPeak
        : 0.0;
    factorScores['peak'] = peakScore.clamp(0.0, 1.0);

    // 6. Max jerk — detects the single impulsive spike of a sudden stop.
    //    Baseline estimates max as meanJerk + 3*jerkStd (99.7% of normal).
    //    Anything beyond that is genuinely anomalous.
    final expectedMaxJerk =
        baseline.meanJerk + 3 * (jerkStd > 0 ? jerkStd : baseline.meanJerk * 0.5 + 1);
    final maxJerkScore = features.maxJerk > expectedMaxJerk
        ? ((features.maxJerk - expectedMaxJerk) / (expectedMaxJerk + 1)).clamp(0.0, 1.0)
        : 0.0;
    factorScores['maxJerk'] = maxJerkScore;

    // 7. Energy deviation — only MORE energetic than baseline (running, rapid movement)
    final baselineEnergy = baseline.meanMagnitude * baseline.meanMagnitude +
        baseline.varianceMagnitude;
    final energyDeviation = features.energy > baselineEnergy
        ? features.energy - baselineEnergy
        : 0.0;
    final energySigma = baselineEnergy > 0 ? energyDeviation / baselineEnergy : 0.0;
    factorScores['energy'] = _sigmaToScore(energySigma * 0.5); // softer weight

    // Weighted combination.
    // maxJerk and jerk carry most weight for event detection;
    // energy distinguishes running; peak, magnitude and variability for overall shape.
    const weights = {
      'magnitude':   0.10,
      'variability': 0.10,
      'jerk':        0.20,
      'maxJerk':     0.25, // highest — best discriminator for sudden stop
      'activity':    0.10,
      'peak':        0.15,
      'energy':      0.10, // helps for running
    };

    double totalScore = 0;
    double totalWeight = 0;
    for (final entry in factorScores.entries) {
      totalScore += entry.value * (weights[entry.key] ?? 0.1);
      totalWeight += weights[entry.key] ?? 0.1;
    }
    final overallScore = (totalScore / totalWeight).clamp(0.0, 1.0);

    // Compute overall deviation in sigmas
    final avgSigma = (magSigma + varSigma + jerkSigma + smaSigma) / 4;

    // Determine if anomalous
    final isAnomalous = overallScore >= _anomalyThreshold;

    // Generate description
    String description;
    if (!isAnomalous) {
      description = 'Movement within normal range';
    } else {
      final topFactors = factorScores.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final topFactor = topFactors.first.key;
      description = 'Unusual ${_factorToDescription(topFactor)} detected';
    }

    return AnomalyResult(
      score: overallScore,
      isAnomalous: isAnomalous,
      deviationSigma: avgSigma,
      factorScores: factorScores,
      description: description,
      timestamp: DateTime.now(),
    );
  }

  /// Handle anomaly result with persistence checking
  void _handleAnomalyResult(AnomalyResult result) {
    _lastAnomalyResult = result;
    if (!_anomalyResultController.isClosed) {
      _anomalyResultController.add(result);
    }
    _recentAnomalies.add(result);
    if (_recentAnomalies.length > _maxAnomalyHistory) {
      _recentAnomalies.removeAt(0);
    }

    if (result.isAnomalous) {
      _consecutiveAnomalyWindows++;
      onAnomalyDetected?.call(result);

      // Check persistence threshold
      if (_consecutiveAnomalyWindows >= MotionBaseline.anomalyPersistenceThreshold) {
        debugPrint('🚨 Motion concern triggered! '
            '$_consecutiveAnomalyWindows consecutive anomalous windows');
        onMotionConcernTriggered?.call(true);
      }
    } else {
      // Reset if normal window detected
      if (_consecutiveAnomalyWindows > 0) {
        debugPrint('✅ Normal movement detected, resetting anomaly counter');
      }
      _consecutiveAnomalyWindows = 0;
      onMotionConcernTriggered?.call(false);
    }
  }

  /// Update baseline adaptively during normal operation
  void _updateBaselineAdaptively(MotionWindowFeatures features) {
    if (_baseline == null) return;

    // Only update if we have enough samples for a stable baseline
    if (_baseline!.sampleCount < MotionBaseline.minCalibrationWindows * 2) {
      return;
    }

    // Exponential moving average update
    final lr = _baselineLearningRate;
    
    _baseline = _baseline!.copyWith(
      meanMagnitude: _baseline!.meanMagnitude * (1 - lr) + features.meanMagnitude * lr,
      varianceMagnitude: _baseline!.varianceMagnitude * (1 - lr) + features.variance * lr,
      stdMagnitude: _baseline!.stdMagnitude * (1 - lr) + features.stdMagnitude * lr,
      meanJerk: _baseline!.meanJerk * (1 - lr) + features.meanJerk * lr,
      sma: _baseline!.sma * (1 - lr) + features.sma * lr,
      sampleCount: _baseline!.sampleCount + 1,
      lastUpdated: DateTime.now(),
    );

    // Save periodically (every 100 updates)
    if (_baseline!.sampleCount % 100 == 0) {
      _saveBaseline();
    }
  }

  // ===== Utility Methods =====

  double _mean(List<double> values) {
    if (values.isEmpty) return 0;
    return values.reduce((a, b) => a + b) / values.length;
  }

  double _variance(List<double> values) {
    if (values.length < 2) return 0;
    final mean = _mean(values);
    return values.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) / values.length;
  }

  /// Convert sigma (standard deviations) to anomaly score 0-1
  double _sigmaToScore(double sigma) {
    // Using CDF approximation: 3 sigma = ~0.997 confidence
    // Maps sigma to 0-1 range where 3+ sigma = 1.0
    return (1 - exp(-sigma * sigma / 2)).clamp(0.0, 1.0);
  }

  String _factorToDescription(String factor) {
    switch (factor) {
      case 'magnitude':   return 'movement intensity';
      case 'variability': return 'movement pattern';
      case 'jerk':        return 'sudden movement';
      case 'maxJerk':     return 'sudden stop or impact';
      case 'activity':    return 'activity level';
      case 'peak':        return 'peak acceleration';
      case 'energy':      return 'running or rapid movement';
      default:            return 'movement';
    }
  }

  /// Clear all stored baseline data
  Future<void> clearBaseline() async {
    await _secureStorage.delete(key: _baselineKey);
    _baseline = MotionBaseline.empty();
    debugPrint('🗑️ Motion baseline cleared');
  }

  /// Get current consecutive anomaly count
  int get consecutiveAnomalyWindows => _consecutiveAnomalyWindows;

  /// Live stream of every anomaly result (normal + anomalous) — for debug/eval UI.
  Stream<AnomalyResult> get anomalyResultStream => _anomalyResultController.stream;

  /// Most recent anomaly result, or null if monitoring has not started.
  AnomalyResult? get lastAnomalyResult => _lastAnomalyResult;

  /// Steps detected during the current/last calibration
  int get calibrationStepCount => _calibrationStepCount;

  /// Walking-only samples accepted during calibration
  int get walkingWindowCount => _walkingWindowCount;

  /// Get recent anomaly results 
  List<AnomalyResult> get recentAnomalies => List.unmodifiable(_recentAnomalies);

  /// Features collected during the most recent successful calibration.
  /// Available immediately after [startCalibration] completes.
  List<MotionWindowFeatures> get lastCalibrationFeatures =>
      List.unmodifiable(_lastCalibrationFeatures);

  /// Calibrate the baseline directly from an externally provided list of
  /// walking feature windows (e.g. from the Motion Dataset Normal Walk
  /// collection).  Returns true if the baseline was updated.
  Future<bool> calibrateFromFeatures(List<MotionWindowFeatures> features) async {
    if (!_isInitialized) await initialize();
    if (features.length < MotionBaseline.minCalibrationWindows) return false;

    final magnitudes = features.map((f) => f.meanMagnitude).toList();
    final jerks      = features.map((f) => f.meanJerk).toList();
    final smas       = features.map((f) => f.sma).toList();
    final zcs        = features.map((f) => f.zeroCrossings.toDouble()).toList();

    final meanMag  = _mean(magnitudes);
    final varMag   = _variance(magnitudes);
    final stdMag   = sqrt(varMag);
    final meanJerk = _mean(jerks);
    final jerkVar  = _variance(jerks);
    final meanSma  = _mean(smas);
    final stepRate    = _mean(zcs) / (_windowDurationMs / 1000);
    final stepRateVar = _variance(zcs.map((z) => z / (_windowDurationMs / 1000)).toList());

    _baseline = MotionBaseline(
      meanMagnitude:    meanMag,
      varianceMagnitude: varMag,
      stdMagnitude:     stdMag,
      stepRate:         stepRate,
      stepRateVariance: stepRateVar,
      meanJerk:         meanJerk,
      jerkVariance:     jerkVar,
      sma:              meanSma,
      sampleCount:      features.length,
      lastUpdated:      DateTime.now(),
    );
    await _saveBaseline();
    debugPrint('✅ Baseline calibrated from ${features.length} external features');
    return true;
  }

  /// Public wrapper around the anomaly scorer so external services (e.g.
  /// MotionDatasetService) can evaluate pre-extracted feature windows without
  /// needing to drive the sensor stream themselves.
  AnomalyResult scoreWindow(MotionWindowFeatures features) =>
      _computeAnomalyScore(features);

  /// Dispose resources
  Future<void> dispose() async {
    await stopMonitoring();
    await cancelCalibration();
  }
}

/// Internal class for accelerometer readings (not persisted)
class _AccelReading {
  final double x;
  final double y;
  final double z;
  final DateTime timestamp;

  _AccelReading({
    required this.x,
    required this.y,
    required this.z,
    required this.timestamp,
  });
}
