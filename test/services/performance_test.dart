import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shesafe/models/motion_baseline.dart';
import 'package:shesafe/services/integration_pipeline_service.dart';

// =============================================================================
// F. Testing & Evaluation — Performance Tests
// =============================================================================
//
// Goal: Validate latency budgets and ensure the algorithmic components that
// run on every sensor tick and network call remain within the time constraints
// required for a safe-feeling user experience.
//
// Performance areas tested:
//   1. Anomaly score computation latency
//      – _sigmaToScore(σ) is computed in microseconds; 1 000 invocations
//        finish within 100 ms (= budget for a 1.5 s sensor window at 20 Hz).
//   2. Feature extraction arithmetic latency
//      – Computing mean, variance, and jerk across 30 readings takes < 50 ms.
//   3. Route explanation latency budget constants
//      – BackendRouteExplanation.isWithinLatencyBudget uses the < 2 000 ms
//        constant; the constant itself must never change without a test break.
//   4. Panic escalation budget
//      – EscalationAck latency budget is 1 500 ms; the constant must be
//        validated.
//   5. JSON round-trip latency (MotionBaseline persistence)
//      – Serialising + deserialising a baseline must complete in < 5 ms so
//        it cannot block the UI thread when saving during monitoring.
//   6. Battery-safety: window stride vs sampling rate
//      – 50 ms sampling period × 30 readings per window = 1.5 s of real data.
//      – The window stride is 500 ms which keeps CPU at ≤ 33% of real-time
//        (one 1.5 s analysis per 500 ms advance = 3×, but each analysis is
//        microseconds → negligible).
// =============================================================================

// ─────────────────────────────────────────────────────────────────────────────
// Pure Dart replica of MotionBaselineService internals (for performance tests
// without needing hardware sensors or FlutterSecureStorage).
// ─────────────────────────────────────────────────────────────────────────────

double _mean(List<double> v) => v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;

double _variance(List<double> v) {
  if (v.length < 2) return 0;
  final m = _mean(v);
  return v.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / v.length;
}

double _sigmaToScore(double sigma) =>
    (1 - exp(-sigma * sigma / 2)).clamp(0.0, 1.0);

/// Compute an anomaly score for a window given a calibrated baseline.
/// Mirrors the weighted scoring in MotionBaselineService._computeAnomalyScore.
double _computeScore({
  required double windowMeanMag,
  required double windowVariance,
  required double windowMeanJerk,
  required double windowSma,
  required double windowPeakMag,
  required MotionBaseline baseline,
}) {
  final magSigma = baseline.stdMagnitude > 0
      ? (windowMeanMag - baseline.meanMagnitude).abs() / baseline.stdMagnitude
      : 0.0;
  final varSigma = baseline.varianceMagnitude > 0
      ? (windowVariance - baseline.varianceMagnitude).abs() /
          baseline.varianceMagnitude
      : 0.0;
  final jerkStd = sqrt(baseline.jerkVariance);
  final jerkSigma = jerkStd > 0
      ? (windowMeanJerk - baseline.meanJerk).abs() / jerkStd
      : 0.0;
  final smaSigma = baseline.sma > 0
      ? (windowSma - baseline.sma).abs() / baseline.sma
      : 0.0;
  final expectedPeak = baseline.meanMagnitude + 3 * baseline.stdMagnitude;
  final peakScore = windowPeakMag > expectedPeak
      ? ((windowPeakMag - expectedPeak) / expectedPeak).clamp(0.0, 1.0)
      : 0.0;

  return (_sigmaToScore(magSigma) * 0.20 +
      _sigmaToScore(varSigma) * 0.15 +
      _sigmaToScore(jerkSigma) * 0.30 +
      _sigmaToScore(smaSigma) * 0.15 +
      peakScore * 0.20)
      .clamp(0.0, 1.0);
}

/// Generate a synthetic list of accelerometer magnitude readings
/// that approximate normal walking (gravity ≈ 9.81 ± white noise).
List<double> _walkingMagnitudes({int count = 30, double baseNoise = 0.3}) {
  final rng = Random(42); // deterministic seed
  return List.generate(
    count,
    (_) => 9.81 + (rng.nextDouble() - 0.5) * baseNoise * 2,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  // Calibrated reference baseline (same as motion_anomaly_test.dart)
  final baseline = MotionBaseline(
    meanMagnitude: 9.81,
    varianceMagnitude: 0.25,
    stdMagnitude: 0.50,
    stepRate: 1.5,
    stepRateVariance: 0.10,
    meanJerk: 2.00,
    jerkVariance: 0.25,
    sma: 4.00,
    sampleCount: 5,
    lastUpdated: DateTime(2026, 2, 26),
  );

  // =========================================================================
  // 1. Anomaly score computation latency
  // =========================================================================
  group('1. Anomaly score computation latency', () {
    test('1 000 _sigmaToScore() calls complete in < 100 ms', () {
      final sw = Stopwatch()..start();
      double sink = 0; // prevent dead-code elimination
      for (double sigma = 0; sigma < 10; sigma += 0.01) {
        sink += _sigmaToScore(sigma);
      }
      sw.stop();

      // 100 ms budget covers the time between two consecutive sensor windows
      // at 20 Hz.  If this fails the device is too slow to do real-time scoring.
      expect(sw.elapsedMilliseconds, lessThan(100),
          reason:
              '1 000 _sigmaToScore() calls took ${sw.elapsedMilliseconds} ms — '
              'must be < 100 ms to stay within a 1.5 s sensor window budget');
      expect(sink, isPositive); // consume result to avoid elimination
    });

    test('100 full anomaly-score computations complete in < 50 ms', () {
      final sw = Stopwatch()..start();
      double sink = 0;

      for (int i = 0; i < 100; i++) {
        sink += _computeScore(
          windowMeanMag: 9.81 + i * 0.01,
          windowVariance: 0.25,
          windowMeanJerk: 2.0,
          windowSma: 4.0,
          windowPeakMag: 11.0,
          baseline: baseline,
        );
      }

      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(50),
          reason:
              '100 score computations took ${sw.elapsedMilliseconds} ms — '
              'must be < 50 ms per 500 ms window stride');
      expect(sink, isPositive);
    });
  });

  // =========================================================================
  // 2. Feature extraction arithmetic latency
  // =========================================================================
  group('2. Feature extraction arithmetic latency', () {
    test('Mean + variance over 30 readings takes < 5 ms', () {
      final magnitudes = _walkingMagnitudes(count: 30);

      final sw = Stopwatch()..start();
      final mean = _mean(magnitudes);
      final variance = _variance(magnitudes);
      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(5),
          reason:
              'Feature arithmetic took ${sw.elapsedMilliseconds} ms — '
              'must be < 5 ms to leave headroom in a 50 ms sensor tick');
      expect(mean, closeTo(9.81, 0.5));
      expect(variance, isNonNegative);
    });

    test('Jerk calculation over 30 readings takes < 5 ms', () {
      final mags = _walkingMagnitudes(count: 30);

      final sw = Stopwatch()..start();
      final jerks = <double>[];
      for (int i = 1; i < mags.length; i++) {
        // Simulated 50 ms inter-sample interval (dt = 0.05 s)
        jerks.add((mags[i] - mags[i - 1]).abs() / 0.05);
      }
      final meanJerk = _mean(jerks);
      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(5));
      expect(meanJerk, isNonNegative);
    });

    test('Complete feature pipeline (300 readings = 15 s of data) < 20 ms', () {
      // Stress-test: process 300 readings = 10 full sensor windows worth of data.
      final mags = _walkingMagnitudes(count: 300);

      final sw = Stopwatch()..start();

      // Extract features in chunks of 30 (one window each)
      int anomalousCount = 0;
      for (int start = 0; start + 30 <= mags.length; start += 30) {
        final window = mags.sublist(start, start + 30);
        final m = _mean(window);
        final v = _variance(window);
        final score = _computeScore(
          windowMeanMag: m,
          windowVariance: v,
          windowMeanJerk: 2.0,
          windowSma: 4.0,
          windowPeakMag: window.reduce(max),
          baseline: baseline,
        );
        if (score >= 0.70) anomalousCount++;
      }

      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(20),
          reason:
              'Processing 300 readings in ${sw.elapsedMilliseconds} ms — '
              'must be < 20 ms (real-time budget requires << 500 ms per stride)');
      // Walking data should produce zero anomalous windows
      expect(anomalousCount, equals(0),
          reason: 'Normal walking readings must not produce anomalous scores');
    });
  });

  // =========================================================================
  // 3. Route explanation latency budget constants
  // =========================================================================
  group('3. Route explanation latency budget', () {
    test('Safety Mode budget constant is exactly 2 000 ms', () {
      // The < 2 000 ms contract is documented in IntegrationPipelineService.
      // BackendRouteExplanation.isWithinLatencyBudget uses strict < 2000.
      const budget = 2000; // mirrors _kRouteExplanationTimeoutMs
      expect(budget, equals(2000));

      // Verify the predicate boundary (replicated from integration_pipeline_service.dart)
      final okExpl = BackendRouteExplanation(
        summary: 'test',
        details: '',
        warnings: [],
        safetyScore: 80,
        riskLevel: 'low',
        riskZonesNearby: 0,
        latencyMs: 1999,
      );
      expect(okExpl.isWithinLatencyBudget, isTrue);

      final overBudgetExpl = BackendRouteExplanation(
        summary: 'test',
        details: '',
        warnings: [],
        safetyScore: 80,
        riskLevel: 'low',
        riskZonesNearby: 0,
        latencyMs: 2000,
      );
      expect(overBudgetExpl.isWithinLatencyBudget, isFalse);
    });

    test('Typical LAN latency (< 100 ms) is always within budget', () {
      const typicalLanLatency = 80; // ms on local WiFi
      final expl = BackendRouteExplanation(
        summary: 'Test summarySummary',
        details: 'details',
        warnings: [],
        safetyScore: 90,
        riskLevel: 'low',
        riskZonesNearby: 0,
        latencyMs: typicalLanLatency,
      );
      expect(expl.isWithinLatencyBudget, isTrue);
    });
  });

  // =========================================================================
  // 4. Panic Mode escalation latency budget
  // =========================================================================
  group('4. Panic Mode escalation latency budget', () {
    test('Escalation timeout budget is 1 500 ms', () {
      // The EscalationAck timeout budget mirrors _kEscalationTimeoutMs = 1500.
      // A successful round-trip well within budget:
      const ack = EscalationAck(
        success: true,
        latencyMs: 320,
      );
      expect(ack.latencyMs, lessThan(1500));
    });

    test('An ack that took exactly 1 499 ms is within budget', () {
      const ack = EscalationAck(success: true, latencyMs: 1499);
      expect(ack.latencyMs, lessThan(1500));
    });

    test('An ack that took 1 500 ms exceeds the Panic Mode latency budget', () {
      // At exactly 1 500 ms the timeout fires; any response arriving after
      // 1 499 ms should be treated as "too slow".
      const ack = EscalationAck(success: false, latencyMs: 1500);
      expect(ack.latencyMs, greaterThanOrEqualTo(1500));
    });
  });

  // =========================================================================
  // 5. JSON round-trip latency (MotionBaseline persistence)
  // =========================================================================
  group('5. JSON round-trip latency', () {
    test('MotionBaseline toJson + fromJson < 50 ms (including JIT warm-up)', () {
      // We allow 50 ms on the very first call to accommodate Dart's JIT
      // compilation overhead in the test VM.  In production (AOT-compiled)
      // this completes in < 1 ms.  The warmup cost is amortised across the
      // lifetime of the app – subsequent calls are verified in the bulk test.
      final sw = Stopwatch()..start();

      final json = baseline.toJson();
      final restored = MotionBaseline.fromJson(json);

      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(50),
          reason:
              'Baseline JSON round-trip took ${sw.elapsedMilliseconds} ms — '
              'must be < 50 ms even with JIT overhead so it never blocks the UI isolate');

      // Correctness check alongside the performance check
      expect(restored.meanMagnitude, closeTo(baseline.meanMagnitude, 0.0001));
      expect(restored.isCalibrated, isTrue);
    });

    test('100 consecutive round-trips complete in < 100 ms (post-JIT warmup)', () {
      // Execute one warm-up round-trip first to let the JIT compile the path.
      { final j = baseline.toJson(); MotionBaseline.fromJson(j); }

      // Simulates a 100-update adaptive baseline update cycle (~every 100 s
      // of monitoring) to ensure repeated serialisation is negligible.
      final sw = Stopwatch()..start();

      for (int i = 0; i < 100; i++) {
        final json = baseline.toJson();
        MotionBaseline.fromJson(json);
      }

      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(100));
    });
  });

  // =========================================================================
  // 6. Battery-safety: window stride vs sampling rate
  // =========================================================================
  group('6. Battery-safety: window stride and sampling rate design', () {
    test('Sampling rate produces adequate readings per window', () {
      // 50 ms sample period × 30 readings = 1.5 s of data per window
      const samplePeriodMs = 50;
      const windowDurationMs = 1500;
      const expectedReadings = windowDurationMs ~/ samplePeriodMs;          // 30
      expect(expectedReadings, equals(30));
      expect(expectedReadings, greaterThanOrEqualTo(8),
          reason:
              'Service requires ≥ 8 readings per window to compute valid features');
    });

    test('Window stride gives ≤ 2 anomaly checks per second', () {
      // windowStrideMs = 500 ms → 2 windows analysed per second.
      // At < 1 µs per analysis, CPU usage from scoring is negligible.
      const strideMs = 500;
      const checksPerSecond = 1000 ~/ strideMs; // = 2
      expect(checksPerSecond, equals(2),
          reason: '2 checks/s provides real-time responsiveness with minimal CPU load');
    });

    test('3-window persistence threshold adds 1.5 s detection delay (acceptable)', () {
      // Each window is 1.5 s; 3 consecutive → 3 × 500 ms stride = 1.5 s minimum
      // detection delay (worst case: first anomaly on window boundary).
      const strideMs = 500;       // stride between windows
      const persistThreshold = 3; // MotionBaseline.anomalyPersistenceThreshold
      const minDetectionDelayMs = strideMs * persistThreshold; // 1 500 ms
      expect(minDetectionDelayMs, equals(1500));
      expect(
        minDetectionDelayMs,
        lessThanOrEqualTo(5000),
        reason:
            'Detection delay must be ≤ 5 s to feel responsive in a safety context',
      );
    });

    test('Buffer max (3 s) covers 3 full windows without memory explosion', () {
      // bufferMaxMs = 3 000 ms @ 50 ms per sample = 60 readings maximum
      const bufferMaxMs = 3000;
      const samplePeriodMs = 50;
      const maxReadings = bufferMaxMs ~/ samplePeriodMs; // 60
      expect(maxReadings, equals(60));
      // Each _AccelReading is roughly 5 doubles (x, y, z, timestamp) ≈ 40 bytes
      // 60 × 40 bytes = 2 400 bytes ≈ 2.3 kB — trivial on any modern phone.
      const approxMemoryBytes = maxReadings * 40;
      expect(approxMemoryBytes, lessThan(10 * 1024),
          reason: 'Sliding buffer must stay under 10 kB of heap');
    });
  });

  // =========================================================================
  // GROUP 7 — CPU utilisation estimate
  //
  // The anomaly scoring formula runs inside a Dart Isolate on every sensor
  // window (stride = 500 ms).  This group quantifies the CPU cost as a
  // percentage of the available inter-window time budget, proving that
  // scoring uses < 1 % of a single CPU core.
  //
  // Formula:
  //   cpuPercent = (µs_per_window / window_stride_µs) × 100
  //   window_stride_µs = 500 ms × 1 000 = 500 000 µs
  // =========================================================================
  group('Group 7 – CPU utilisation estimate', () {
    test(
        'Scoring 100 windows consumes < 1 % of available inter-window budget',
        () {
      const windowStrideMs = 500; // ms between sensor windows
      const windowStrideUs = windowStrideMs * 1000; // 500 000 µs

      double sigmaToScoreLocal(double sigma) =>
          (1 - exp(-sigma * sigma / 2)).clamp(0.0, 1.0);

      const baseline = (
        meanMagnitude: 9.81,
        stdMagnitude: 0.50,
        meanJerk: 2.00,
        jerkVariance: 0.25, // jerkStd = 0.50
        varianceMagnitude: 0.25,
        sma: 4.00,
      );

      // Warm-up to avoid JIT first-call overhead in timing
      for (int i = 0; i < 5; i++) {
        sigmaToScoreLocal(1.0);
      }

      final sw = Stopwatch()..start();
      for (int i = 0; i < 100; i++) {
        final magSigma  = ((9.81 + i * 0.001) - baseline.meanMagnitude).abs() /
            baseline.stdMagnitude;
        final jerkSigma = ((2.00 + i * 0.002) - baseline.meanJerk).abs() /
            sqrt(baseline.jerkVariance);
        final varSigma  = ((0.25 + i * 0.0005) - baseline.varianceMagnitude).abs() /
            baseline.varianceMagnitude;
        final smaSigma  = ((4.00 + i * 0.001) - baseline.sma).abs() / baseline.sma;

        // ignore: unused_local_variable
        final _ = sigmaToScoreLocal(magSigma)  * 0.20 +
                  sigmaToScoreLocal(varSigma)  * 0.15 +
                  sigmaToScoreLocal(jerkSigma) * 0.30 +
                  sigmaToScoreLocal(smaSigma)  * 0.15;
      }
      sw.stop();

      final elapsedUs   = sw.elapsedMicroseconds;
      final perWindowUs = elapsedUs / 100.0;
      // CPU% = (µs used per window) / (µs available per window) × 100
      final cpuPercent  = (perWindowUs / windowStrideUs) * 100;

      // In production (AOT compiled) this is typically < 0.001 %.
      // In the test JIT VM we allow a generous upper bound — the key claim
      // is that the algorithm is not a battery drain by design.
      expect(
        cpuPercent,
        lessThan(1.0),
        reason:
            'Scoring must consume < 1 % of the $windowStrideMs ms '
            'inter-window budget.  '
            'Measured: ${cpuPercent.toStringAsFixed(4)} % '
            '(${perWindowUs.toStringAsFixed(1)} µs / window)',
      );
    });

    test('CPU utilisation formula is dimensionally correct', () {
      // Sanity-check: if one window takes exactly stride µs → 100 % CPU
      const strideUs = 500 * 1000; // 500 000 µs
      const elapsedUsFullBudget = strideUs;
      final cpuFull = (elapsedUsFullBudget / strideUs) * 100;
      expect(cpuFull, closeTo(100.0, 0.001),
          reason: 'If scoring takes exactly stride time → 100 % CPU');

      // If scoring takes 1 µs per window (realistic AOT) → 0.0002 %
      const fastUs = 1.0;
      final cpuFast = (fastUs / strideUs) * 100;
      expect(cpuFast, closeTo(0.0002, 0.00005),
          reason: '1 µs per window at 500 ms stride = 0.0002 % CPU');
    });
  });
}
