import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:uuid/uuid.dart';
import '../../models/labeled_motion_sample.dart';
import '../../services/motion_dataset_service.dart';

/// Guides the user through a single-class recording session.
///
/// Shows:
///  • Animated countdown + instruction
///  • Live feature readout (magnitude, jerk, SMA) for each completed window
///  • Summary on completion
///
/// Returns via [Navigator.pop] when done; the parent screen re-reads
/// [MotionDatasetService.samples] for the updated counts.
class CollectionSessionScreen extends StatefulWidget {
  final MotionLabel label;

  /// How many seconds to record (one 1-second window per second)
  final int durationSeconds;

  const CollectionSessionScreen({
    super.key,
    required this.label,
    this.durationSeconds = 15,
  });

  @override
  State<CollectionSessionScreen> createState() =>
      _CollectionSessionScreenState();
}

class _CollectionSessionScreenState extends State<CollectionSessionScreen>
    with TickerProviderStateMixin {
  final _datasetService = MotionDatasetService();
  late final String _sessionId;

  // State
  _Phase _phase = _Phase.instruction;
  int _secondsLeft = 0;
  int _windowsCollected = 0;
  LabeledMotionSample? _latestSample;

  // Action-prompt flash (only for anomaly classes)
  bool _showActionPrompt = false;
  Timer? _promptTimer;

  // Live raw magnitude before first feature window arrives
  double _liveMagnitude = 0.0;
  StreamSubscription<AccelerometerEvent>? _liveAccelSub;

  Timer? _countdownTimer;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _sessionId = const Uuid().v4();
    _secondsLeft = widget.durationSeconds;

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);

    _pulseAnim = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _promptTimer?.cancel();
    _liveAccelSub?.cancel();
    _pulseController.dispose();
    _datasetService.stopRecording();
    super.dispose();
  }

  // ── Phase transitions ────────────────────────────────────────────────────

  void _startRecording() {
    setState(() {
      _phase = _Phase.recording;
      _windowsCollected = 0;
    });

    // Subscribe immediately so the UI shows live readings from the first sensor
    // tick (~50 ms), well before the first 1500 ms feature window is ready.
    _liveAccelSub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 50),
    ).listen((e) {
      if (!mounted) return;
      final mag = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
      setState(() => _liveMagnitude = mag);
    });

    _datasetService.startRecording(
      sessionId: _sessionId,
      label: widget.label,
      onWindow: (sample) {
        if (!mounted) return;
        setState(() {
          _windowsCollected++;
          _latestSample = sample;
        });
      },
    );

    _countdownTimer =
        Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) {
        _stopRecording();
      }
    });

    // For anomaly (non-normal) classes, show a periodic action-prompt flash
    // every 2.5 seconds so the user knows exactly when to perform the motion.
    // This aligns repeated events with the 0.5 s window stride, guaranteeing
    // each "DO IT NOW" pulse lands inside a fresh feature window.
    if (widget.label.isAnomaly) {
      _promptTimer = Timer.periodic(
        const Duration(milliseconds: 2500),
        (_) {
          if (!mounted || _phase != _Phase.recording) return;
          setState(() => _showActionPrompt = true);
          Future.delayed(const Duration(milliseconds: 600), () {
            if (mounted) setState(() => _showActionPrompt = false);
          });
        },
      );
    }
  }

  Future<void> _stopRecording() async {
    _countdownTimer?.cancel();
    _promptTimer?.cancel();
    _liveAccelSub?.cancel();
    _liveAccelSub = null;
    await _datasetService.stopRecording();
    if (!mounted) return;
    setState(() => _phase = _Phase.done);
    _pulseController.stop();
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF8FA),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFFF8FA),
        elevation: 0,
        foregroundColor: const Color(0xFF2C2530),
        title: Text('Record: ${widget.label.displayName}'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () async {
            if (_phase == _Phase.recording) await _stopRecording();
            if (!context.mounted) return;
            Navigator.pop(context);
          },
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_phase) {
      case _Phase.instruction:
        return _buildInstruction();
      case _Phase.recording:
        return _buildRecording();
      case _Phase.done:
        return _buildDone();
    }
  }

  // ── Instruction ──────────────────────────────────────────────────────────

  Widget _buildInstruction() {
    final color = _labelColor(widget.label);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(),
        Center(
          child: Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.12),
              border: Border.all(color: color.withValues(alpha: 0.5), width: 2),
            ),
            child: Icon(widget.label.icon, size: 48, color: color),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          widget.label.displayName,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            widget.label.instruction,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, height: 1.5),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Duration: ${widget.durationSeconds} seconds  ·  '
          '~${widget.durationSeconds} samples',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const Spacer(),
        ElevatedButton.icon(
          onPressed: _startRecording,
          icon: const Icon(Icons.fiber_manual_record),
          label: const Text('Start Recording', style: TextStyle(fontSize: 18)),
          style: ElevatedButton.styleFrom(
            backgroundColor: color,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 18),
          ),
        ),
      ],
    );
  }

  // ── Recording ────────────────────────────────────────────────────────────

  Widget _buildRecording() {
    final color = _labelColor(widget.label);
    final progress =
        (_windowsCollected / widget.durationSeconds).clamp(0.0, 1.0);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Action-prompt flash (anomaly classes only) — fires every 2.5 s so
          // the user performs the motion exactly when a new window starts.
          if (widget.label.isAnomaly)
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: 48,
              decoration: BoxDecoration(
                color: _showActionPrompt
                    ? color.withValues(alpha: 0.9)
                    : color.withValues(alpha: 0.0),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: _showActionPrompt
                    ? Text(
                        'NOW',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      )
                    : Text(
                        'Get ready…',
                        style: TextStyle(
                          color: color.withValues(alpha: 0.6),
                          fontSize: 14,
                        ),
                      ),
              ),
            )
          else
            const SizedBox(height: 8),
          const SizedBox(height: 8),

          // Countdown circle
          Center(
          child: AnimatedBuilder(
            animation: _pulseAnim,
            builder: (_, child) => Transform.scale(
              scale: _pulseAnim.value,
              child: child,
            ),
            child: Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.15),
                border: Border.all(color: color, width: 4),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '$_secondsLeft',
                    style: TextStyle(
                      fontSize: 52,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                  const Text('sec left', style: TextStyle(color: Colors.grey)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),

        // Progress bar
        LinearProgressIndicator(
          value: progress,
          backgroundColor: color.withValues(alpha: 0.15),
          color: color,
          minHeight: 8,
        ),
        const SizedBox(height: 8),
        Text(
          '$_windowsCollected samples collected',
          textAlign: TextAlign.center,
          style: TextStyle(color: color, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 24),

        // Live features — show raw magnitude immediately, swap for full
        // feature table once the first window (1.5 s) has been processed.
        if (_latestSample != null)
          _buildLiveFeatures(_latestSample!)
        else
          _buildLiveRawCard(),

        const SizedBox(height: 24),

        OutlinedButton.icon(
          onPressed: _stopRecording,
          icon: const Icon(Icons.stop),
          label: const Text('Stop Early'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.red,
            side: const BorderSide(color: Colors.red),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        const SizedBox(height: 16),
      ],
      ),
    );
  }

  Widget _buildLiveRawCard() {
    final color = _labelColor(widget.label);
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Live sensor readings',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const Divider(),
            _featureRow(
              'Sensor magnitude',
              '${_liveMagnitude.toStringAsFixed(2)} m/s\u00b2',
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Calculating features\u2026',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveFeatures(LabeledMotionSample s) {
    final f = s.features;
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Last sample features',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const Divider(),
            _featureRow('Mean magnitude',
                '${f.meanMagnitude.toStringAsFixed(2)} m/s²'),
            _featureRow('Peak magnitude',
                '${f.peakMagnitude.toStringAsFixed(2)} m/s²'),
            _featureRow('Std deviation',
                f.stdMagnitude.toStringAsFixed(3)),
            _featureRow('Signal magnitude area',
                f.sma.toStringAsFixed(3)),
            _featureRow('Mean jerk',
                '${f.meanJerk.toStringAsFixed(2)} m/s³'),
            _featureRow('Max jerk',
                '${f.maxJerk.toStringAsFixed(2)} m/s³'),
            _featureRow('Energy',
                f.energy.toStringAsFixed(2)),
            _featureRow('Kurtosis',
                f.kurtosis.toStringAsFixed(2)),
            _featureRow('Zero crossings',
                f.zeroCrossings.toString()),
          ],
        ),
      ),
    );
  }

  Widget _featureRow(String name, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(name,
              style:
                  const TextStyle(fontSize: 13, color: Colors.black54)),
          Text(value,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  // ── Done ─────────────────────────────────────────────────────────────────

  Widget _buildDone() {
    final color = _labelColor(widget.label);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(),
        Center(
          child: Icon(Icons.check_circle, size: 100, color: color),
        ),
        const SizedBox(height: 24),
        const Text(
          'Session Complete',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: Color(0xFF2C2530),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '$_windowsCollected samples collected for '
          '${widget.label.displayName}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 15, color: Color(0xFFB07080)),
        ),
        const Spacer(),
        ElevatedButton(
          onPressed: () => Navigator.pop(context),
          style: ElevatedButton.styleFrom(
            backgroundColor: color,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 18),
          ),
          child: const Text('Back to Dataset', style: TextStyle(fontSize: 18)),
        ),
      ],
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Color _labelColor(MotionLabel label) => const Color(0xFFB07080);
}

enum _Phase { instruction, recording, done }
