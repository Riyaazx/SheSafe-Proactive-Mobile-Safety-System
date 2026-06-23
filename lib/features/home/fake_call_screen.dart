import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// =============================================================================
// FakeCallScreen — Feature 1: Fake Phone Call  (with audio)
// =============================================================================
//
// Ringing phase  → custom iPhone ringtone MP3 loops.
// In-call phase  → TTS engine reads each caller line aloud with natural pauses.
// Speaker toggle → quiet (ear) vs. loud (loudspeaker) volume.
//
// Ringtone: assets/audio/iphone_ringtone.mp3 (looped via audioplayers).
// =============================================================================

class FakeCallScreen extends StatefulWidget {
  // Optional customisation (shows these values in the caller card).
  final String callerName;
  final String callerNumber;

  const FakeCallScreen({
    super.key,
    this.callerName = 'Twin sissy 💕',
    this.callerNumber = '+44 7911 123456',
  });

  @override
  State<FakeCallScreen> createState() => _FakeCallScreenState();
}

class _FakeCallScreenState extends State<FakeCallScreen>
    with TickerProviderStateMixin {
  // ── State ──────────────────────────────────────────────────────────────────
  _CallPhase _phase = _CallPhase.ringing;
  int _elapsedSeconds = 0;
  bool _speakerOn = false;

  // ── Audio ──────────────────────────────────────────────────────────────────
  final AudioPlayer _ringtonePlayer = AudioPlayer();

  // ── Timers ─────────────────────────────────────────────────────────────────
  Timer? _elapsedTimer;
  Timer? _autoHangupTimer;

  // ── Animation ──────────────────────────────────────────────────────────────
  late AnimationController _ringController;
  late Animation<double> _ringAnim;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();

    // Force portrait, full-screen (immersive) while in fake call.
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _initAudio();

    // Pulsing ring animation
    _ringController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat(reverse: true);
    _ringAnim = Tween<double>(begin: 0.92, end: 1.08).animate(
      CurvedAnimation(parent: _ringController, curve: Curves.easeInOut),
    );

    // Subtle avatar pulse (slower)
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.97, end: 1.03).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ringController.dispose();
    _pulseController.dispose();
    _elapsedTimer?.cancel();
    _autoHangupTimer?.cancel();
    _ringtonePlayer.stop();
    _ringtonePlayer.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  // ── Audio helpers ──────────────────────────────────────────────────────────

  Future<void> _initAudio() async {
    // uses alarm stream so it plays
    // even when the phone is on silent / vibrate.
    await _ringtonePlayer.setAudioContext(AudioContext(
      android: AudioContextAndroid(
        audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        contentType: AndroidContentType.music,
        usageType: AndroidUsageType.alarm,
        audioMode: AndroidAudioMode.inCommunication,
      ),
    ));
    await _ringtonePlayer.setReleaseMode(ReleaseMode.loop);
    await _ringtonePlayer.setVolume(1.0);
    _ringtonePlayer.play(AssetSource('audio/iphone_ringtone.mp3'));
  }

  Future<void> _setSpeaker(bool on) async {
    setState(() => _speakerOn = on);
    await _ringtonePlayer.setVolume(1.0);
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _acceptCall() async {
    setState(() => _phase = _CallPhase.inCall);
    _ringController.stop();
    _ringtonePlayer.stop();   // stop ringtone the moment call is answered

    // Play the pre-recorded conversation at full volume, looping so the call
    // stays active for the full call duration even if the recording is shorter.
    // Use full audio focus (gain) + alarm stream for maximum loudness.
    await _ringtonePlayer.setAudioContext(AudioContext(
      android: AudioContextAndroid(
        audioFocus: AndroidAudioFocus.gain,
        contentType: AndroidContentType.music,
        usageType: AndroidUsageType.alarm,
        audioMode: AndroidAudioMode.normal,
      ),
    ));
    await _ringtonePlayer.setReleaseMode(ReleaseMode.loop);
    await _ringtonePlayer.setVolume(1.0);
    _ringtonePlayer.play(AssetSource('audio/fake_call_recording.mp4'));

    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsedSeconds++);
    });

    // Auto-hang-up after 46.5 seconds.
    _autoHangupTimer = Timer(const Duration(seconds: 46, milliseconds: 500), _hangUp);
  }

  void _declineCall() => _hangUp();

  void _hangUp() {
    _elapsedTimer?.cancel();
    _autoHangupTimer?.cancel();
    _ringtonePlayer.stop();
    // Do NOT dispose here — widget dispose() handles full cleanup
    // and calling dispose() twice throws a StateError.
    if (mounted) Navigator.of(context).pop();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String get _elapsed {
    final m = (_elapsedSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_elapsedSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // prevent accidental back-swipe revealing the call is fake
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _phase == _CallPhase.ringing
            ? _buildRingingUI()
            : _buildInCallUI(),
      ),
    );
  }

  // ── Ringing UI ─────────────────────────────────────────────────────────────

  Widget _buildRingingUI() {
    return SizedBox.expand(
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1A1A2E), Color(0xFF16213E), Color(0xFF0F3460)],
          ),
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Spacer(),
              RepaintBoundary(
                child: ScaleTransition(
                  scale: _pulseAnim,
                  child: _buildCallerAvatar(size: 110),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                widget.callerName,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.callerNumber,
                style: TextStyle(color: Colors.white.withAlpha(179), fontSize: 16),
              ),
              const SizedBox(height: 12),
              ScaleTransition(
                scale: _ringAnim,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(26),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    '● Incoming call…',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ),
              ),
              const Spacer(),
              // Decline / Accept row
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 48),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildCallButton(
                      icon: Icons.call_end,
                      color: Colors.red.shade600,
                      label: 'Decline',
                      onTap: _declineCall,
                    ),
                    _buildCallButton(
                      icon: Icons.call,
                      color: Colors.green.shade600,
                      label: 'Accept',
                      onTap: _acceptCall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── In-Call UI ─────────────────────────────────────────────────────────────

  Widget _buildInCallUI() {
    return SizedBox.expand(
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1B5E20), Color(0xFF1A237E)],
          ),
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 48),
              _buildCallerAvatar(size: 100),
              const SizedBox(height: 20),
              Text(
                widget.callerName,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _elapsed,
                style: TextStyle(color: Colors.green.shade300, fontSize: 16),
              ),
              const Spacer(),
              // ── Call controls row ────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildControlButton(
                      icon: Icons.mic_off_rounded,
                      label: 'Mute',
                      active: false,
                      onTap: () {},
                    ),
                    Semantics(
                      label: _speakerOn ? 'Speaker is on' : 'Speaker is off',
                      toggled: _speakerOn,
                      button: true,
                      child: _buildControlButton(
                        icon: _speakerOn
                            ? Icons.volume_up_rounded
                            : Icons.volume_off_rounded,
                        label: 'Speaker',
                        active: _speakerOn,
                        onTap: () => _setSpeaker(!_speakerOn),
                      ),
                    ),
                    _buildControlButton(
                      icon: Icons.dialpad_rounded,
                      label: 'Keypad',
                      active: false,
                      onTap: () {},
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),
              // ── End call button ──────────────────────────────────────────
              _buildCallButton(
                icon: Icons.call_end,
                color: Colors.red.shade600,
                label: 'End',
                onTap: _hangUp,
              ),
              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active
                  ? Colors.white.withAlpha(200)
                  : Colors.white.withAlpha(38),
            ),
            child: Icon(
              icon,
              color: active ? Colors.black87 : Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildCallerAvatar({required double size}) {
    return Semantics(
      label: 'Caller: ${widget.callerName}',
      child: CircleAvatar(
        radius: size / 2,
        backgroundColor: Colors.indigo.shade700,
        child: Icon(Icons.person, size: size * 0.55, color: Colors.white),
      ),
    );
  }

  Widget _buildCallButton({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    return Semantics(
      label: '$label call',
      button: true,
      child: _PressScaleButton(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 34,
              backgroundColor: color,
              child: Icon(icon, color: Colors.white, size: 30),
            ),
            const SizedBox(height: 8),
            Text(label,
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    // ensure WCAG contrast on dark gradient (white70 = ~3:1 — acceptable for large UI labels)
                )),
          ],
        ),
      ),
    );
  }

}


enum _CallPhase { ringing, inCall }

// ── Helper: scales down to 0.93 on press, snaps back on release ─────────────────
class _PressScaleButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const _PressScaleButton({required this.child, required this.onTap});

  @override
  State<_PressScaleButton> createState() => _PressScaleButtonState();
}

class _PressScaleButtonState extends State<_PressScaleButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 100),
    reverseDuration: const Duration(milliseconds: 200),
  );
  late final Animation<double> _scale = Tween<double>(begin: 1.0, end: 0.93)
      .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeIn));

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _ctrl.forward(),
      onTapUp: (_) {
        _ctrl.reverse();
        widget.onTap();
      },
      onTapCancel: () => _ctrl.reverse(),
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}
