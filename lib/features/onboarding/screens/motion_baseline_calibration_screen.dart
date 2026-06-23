import 'package:flutter/material.dart';
import 'dart:async';
import 'package:uuid/uuid.dart';
import '../../../models/labeled_motion_sample.dart';
import '../../../services/motion_baseline_service.dart';
import '../../../services/event_log_service.dart';
import '../../../services/motion_dataset_service.dart';
import '../../../models/event_log.dart';

/// Screen for calibrating personalized motion baseline
/// 
/// This collects motion data during normal walking to establish
/// a user-specific baseline for anomaly detection.
class MotionBaselineCalibrationScreen extends StatefulWidget {
  /// Whether this is part of onboarding (will show next step)
  final bool isOnboarding;
  
  /// Callback when calibration is complete
  final VoidCallback? onComplete;
  
  /// Callback to go back
  final VoidCallback? onBack;

  const MotionBaselineCalibrationScreen({
    super.key,
    this.isOnboarding = false,
    this.onComplete,
    this.onBack,
  });

  @override
  State<MotionBaselineCalibrationScreen> createState() => 
      _MotionBaselineCalibrationScreenState();
}

class _MotionBaselineCalibrationScreenState 
    extends State<MotionBaselineCalibrationScreen> {
  static const int calibrationDuration = 30; // seconds
  
  final MotionBaselineService _motionService = MotionBaselineService();
  final EventLogService _eventLogService = EventLogService();
  
  int _countdown = 3;
  int _secondsRemaining = calibrationDuration;
  bool _isCountingDown = false;
  bool _isCalibrating = false;
  bool _isComplete = false;
  double _progress = 0.0;
  String _statusMessage = '';
  Timer? _countdownTimer;  // 3-2-1 countdown
  Timer? _uiTickTimer;     // drives the progress display every second
  
  // Real-time display
  double _currentMagnitude = 0.0;
  int _samplesProcessed = 0;
  int _stepsDetected = 0;
  bool _calibrationFailed = false;

  @override
  void initState() {
    super.initState();
    _initializeService();
  }

  Future<void> _initializeService() async {
    await _motionService.initialize();
    
    // Check if already calibrated
    if (_motionService.isCalibrated) {
      setState(() {
        _isComplete = true;
        _statusMessage = 'Motion baseline already calibrated';
      });
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _uiTickTimer?.cancel();
    _motionService.cancelCalibration();
    super.dispose();
  }

  void _startCountdown() {
    setState(() {
      _isCountingDown = true;
      _countdown = 3;
      _statusMessage = 'Get ready to walk...';
    });

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _countdown--;
      });

      if (_countdown == 0) {
        timer.cancel();
        _startCalibration();
      }
    });
  }

  Future<void> _startCalibration() async {
    setState(() {
      _isCountingDown = false;
      _isCalibrating = true;
      _secondsRemaining = calibrationDuration;
      _progress = 0.0;
      _samplesProcessed = 0;
      _stepsDetected = 0;
      _calibrationFailed = false;
      _statusMessage = 'Walk normally at your usual pace...';
    });

    // Set up callbacks — all update UI with setState
    _motionService.onCalibrationProgress = (progress) {
      if (mounted) setState(() => _progress = progress);
    };
    _motionService.onWindowProcessed = (features) {
      if (mounted) {
        setState(() {
          _currentMagnitude = features.meanMagnitude;
          _samplesProcessed = _motionService.walkingWindowCount;
          _stepsDetected = _motionService.calibrationStepCount;
        });
      }
    };
    _motionService.onStepUpdate = (walkingSamples, totalSteps) {
      if (mounted) {
        setState(() {
          _samplesProcessed = walkingSamples;
          _stepsDetected = totalSteps;
        });
      }
    };
    _motionService.onCalibrationFailed = (reason) {
      _uiTickTimer?.cancel();
      if (mounted) {
        setState(() {
          _isCalibrating = false;
          _calibrationFailed = true;
          _statusMessage = reason;
        });
      }
    };

    // A real per-second timer to tick the countdown display
    _secondsRemaining = calibrationDuration;
    _uiTickTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || !_isCalibrating) {
        timer.cancel();
        return;
      }
      setState(() {
        if (_secondsRemaining > 0) _secondsRemaining--;
      });
    });

    try {
      await _motionService.startCalibration(calibrationDuration);
      _uiTickTimer?.cancel();

      if (!mounted) return;

      if (_motionService.isCalibrated) {
        _eventLogService.logEvent(
          type: EventType.motionBaselineCalibrated,
          outcome: EventOutcome.success,
          description: 'Motion baseline calibrated — '
              '${_motionService.baseline?.sampleCount ?? 0} samples',
          metadata: {
            'sampleCount': _motionService.baseline?.sampleCount,
            'meanMagnitude': _motionService.baseline?.meanMagnitude,
            'stepRate': _motionService.baseline?.stepRate,
          },
        );
        // ── Seed Motion Dataset with the Normal Walk windows ────────────
        // The same validated walking windows used for baseline are added to
        // the dataset service so the user doesn't have to collect them again.
        final calibFeatures = _motionService.lastCalibrationFeatures;
        if (calibFeatures.isNotEmpty) {
          final sessionId =
              'baseline_calib_${const Uuid().v4().substring(0, 8)}';
          MotionDatasetService().addExternalSamples(
            sessionId,
            MotionLabel.normalWalk,
            calibFeatures,
          );
          debugPrint(
              '[Calibration] Seeded ${calibFeatures.length} Normal Walk '
              'samples into dataset');
        }
        setState(() {
          _isCalibrating = false;
          _isComplete = true;
          _statusMessage = 'Calibration successful!';
        });
      }
      // If isCalibrated is still false, onCalibrationFailed already ran
    } catch (e) {
      _uiTickTimer?.cancel();
      if (mounted) {
        setState(() {
          _isCalibrating = false;
          _statusMessage = e.toString().contains('cancelled')
              ? 'Calibration cancelled'
              : 'Calibration error: $e';
        });
      }
    }
  }

  void _recalibrate() {
    setState(() {
      _isComplete = false;
      _progress = 0.0;
      _samplesProcessed = 0;
      _stepsDetected = 0;
      _calibrationFailed = false;
      _secondsRemaining = calibrationDuration;
      _statusMessage = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5EDE8),
      appBar: AppBar(
        leading: widget.onBack != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBack,
              )
            : null,
        title: Text(widget.isOnboarding ? 'Safety Mode Setup' : 'Motion Calibration'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: MediaQuery.of(context).size.height -
                  MediaQuery.of(context).padding.top -
                  MediaQuery.of(context).padding.bottom -
                  kToolbarHeight -
                  48,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Calibrate Your Motion',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _isComplete
                          ? 'Your personalized motion baseline is ready. Safety Mode will now detect unusual movement patterns accurately.'
                          : _calibrationFailed
                              ? 'Calibration did not succeed. Please try again while walking.'
                              : widget.isOnboarding
                                  ? 'Safety Mode uses your walking pattern to detect danger. Walk normally for 30 seconds to set this up — it takes less than a minute.'
                                  : 'Walk normally for 30 seconds so the app can learn your natural movement patterns.',
                      style: const TextStyle(fontSize: 16),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Center(
                  child: _isComplete
                      ? _buildCompletedView()
                      : _calibrationFailed
                          ? _buildFailedView()
                          : _isCountingDown
                              ? _buildCountdownView()
                              : _isCalibrating
                                  ? _buildCalibratingView()
                                  : _buildReadyView(),
                ),
                const SizedBox(height: 24),
                if (_statusMessage.isNotEmpty)
                  Card(
                    color: _isComplete 
                        ? const Color(0xFFF8D7E3)
                        : _calibrationFailed
                            ? Colors.red.shade50
                            : const Color(0xFFEDE7F6),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Row(
                        children: [
                          Icon(
                            _isComplete 
                                ? Icons.check_circle 
                                : _calibrationFailed
                                    ? Icons.warning_amber_rounded
                                    : Icons.info,
                            color: _isComplete 
                                ? const Color(0xFFB07080)
                                : _calibrationFailed
                                    ? Colors.red.shade700
                                    : const Color(0xFF9B72CB),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _statusMessage,
                              style: TextStyle(
                                color: _isComplete 
                                    ? const Color(0xFFB07080)
                                    : _calibrationFailed
                                        ? Colors.red.shade700
                                        : const Color(0xFF9B72CB),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                _buildBottomButtons(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReadyView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 150,
          height: 150,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFFEDE7F6),
          ),
          child: const Icon(
            Icons.directions_walk,
            size: 80,
            color: Color(0xFF9B72CB),
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Ready to Calibrate',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Hold your phone naturally and walk',
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey,
          ),
        ),
      ],
    );
  }

  Widget _buildCountdownView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 150,
          height: 150,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFFF8D7E3),
          ),
          child: Center(
            child: Text(
              '$_countdown',
              style: const TextStyle(
                fontSize: 72,
                fontWeight: FontWeight.bold,
                color: Color(0xFFB07080),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Get Ready!',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Start walking when the countdown ends',
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey,
          ),
        ),
      ],
    );
  }

  Widget _buildCalibratingView() {
    final percentComplete = (_progress * 100).round();
    
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 150,
              height: 150,
              child: CircularProgressIndicator(
                value: _progress,
                strokeWidth: 8,
                backgroundColor: const Color(0xFFF8D7E3),
                valueColor: const AlwaysStoppedAnimation(Color(0xFFB07080)),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$percentComplete%',
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFB07080),
                  ),
                ),
                Text(
                  '$_secondsRemaining s left',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 24),
        const Text(
          'Calibrating...',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Keep walking naturally',
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey.shade600,
          ),
        ),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Motion magnitude:'),
                    Text(
                      _currentMagnitude.toStringAsFixed(1),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Steps detected (need ${MotionBaselineService.requiredSteps}):'),
                    Text(
                      '$_stepsDetected',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: _stepsDetected >= MotionBaselineService.requiredSteps
                            ? const Color(0xFFB07080)
                            : const Color(0xFFE8956D),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Feature windows:'),
                    Text(
                      '$_samplesProcessed',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: _samplesProcessed >= 3
                            ? const Color(0xFFB07080)
                            : const Color(0xFFE8956D),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (_stepsDetected == 0 && _secondsRemaining < calibrationDuration - 3)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              '⚠️ No steps detected — make sure you are walking!',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.red.shade700, fontSize: 13),
            ),
          ),
      ],
    );
  }

  Widget _buildFailedView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 150,
          height: 150,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFFFFF3E0),
          ),
          child: const Icon(
            Icons.directions_walk_outlined,
            size: 80,
            color: Color(0xFFB8924F),
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Not Enough Walking Detected',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Color(0xFF4E342E),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          color: const Color(0xFFFFF8F2),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFFD7B896)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Results from this attempt:',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF6D4C41),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '• Steps detected: $_stepsDetected (need ≥ ${MotionBaselineService.requiredSteps})',
                  style: const TextStyle(color: Color(0xFF795548), fontSize: 13),
                ),
                Text(
                  '• Feature windows: $_samplesProcessed (need ≥ 3)',
                  style: const TextStyle(color: Color(0xFF795548), fontSize: 13),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Tips:\n'
                  '• Stand up and walk around the room\n'
                  '• Hold the phone in your hand or pocket\n'
                  '• Take steady steps for the full 30 seconds\n'
                  '• Don\'t sit or stand still during calibration',
                  style: TextStyle(fontSize: 13, height: 1.5, color: Color(0xFF5D4037)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCompletedView() {
    final baseline = _motionService.baseline;
    
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 150,
          height: 150,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFFF8D7E3),
          ),
          child: const Icon(
            Icons.check_circle,
            size: 80,
            color: Color(0xFFB07080),
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Calibration Complete!',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Your motion baseline is ready',
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey,
          ),
        ),
        if (baseline != null) ...[
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Baseline Stats',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildStatRow(
                    'Motion intensity',
                    '${baseline.meanMagnitude.toStringAsFixed(1)} m/s²',
                  ),
                  _buildStatRow(
                    'Movement variability',
                    '±${baseline.stdMagnitude.toStringAsFixed(2)}',
                  ),
                  _buildStatRow(
                    'Step rate',
                    '${baseline.stepRate.toStringAsFixed(1)} steps/sec',
                  ),
                  _buildStatRow(
                    'Samples collected',
                    '${baseline.sampleCount}',
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomButtons() {
    if (_isComplete) {
      return Column(
        children: [
          ElevatedButton(
            onPressed: widget.onComplete ?? () => Navigator.of(context).pop(),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: const Color(0xFFB07080),
              foregroundColor: Colors.white,
            ),
            child: Text(
              widget.isOnboarding ? 'Continue' : 'Done',
              style: const TextStyle(fontSize: 18),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _recalibrate,
            child: const Text(
              'Recalibrate',
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
          ),
        ],
      );
    }

    if (_isCalibrating) {
      return OutlinedButton(
        onPressed: () async {
          _uiTickTimer?.cancel();
          await _motionService.cancelCalibration();
          if (mounted) {
            setState(() {
              _isCalibrating = false;
              _statusMessage = 'Calibration cancelled';
            });
          }
        },
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
        child: const Text(
          'Cancel',
          style: TextStyle(fontSize: 18),
        ),
      );
    }

    if (_calibrationFailed) {
      return Column(
        children: [
          ElevatedButton.icon(
            onPressed: () {
              _recalibrate();
              _startCountdown();
            },
            icon: const Icon(Icons.refresh),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: const Color(0xFFE8956D),
              foregroundColor: Colors.white,
            ),
            label: const Text(
              'Retry Calibration',
              style: TextStyle(fontSize: 18),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: widget.isOnboarding
                ? (widget.onBack ?? () => Navigator.of(context).pop())
                : () => Navigator.of(context).pop(),
            child: const Text(
              'Go Back',
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
          ),
        ],
      );
    }

    if (_isCountingDown) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ElevatedButton(
          onPressed: _startCountdown,
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 20),
            backgroundColor: const Color(0xFFB07080),
            foregroundColor: Colors.white,
          ),
          child: const Text(
            'Start Calibration',
            style: TextStyle(fontSize: 18),
          ),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: widget.isOnboarding
              ? widget.onComplete
              : () => Navigator.of(context).pop(),
          child: const Text(
            'Not now',
            style: TextStyle(fontSize: 16, color: Colors.grey),
          ),
        ),
      ],
    );
  }
}
