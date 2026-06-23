import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

// =============================================================================
// SafetyAudioAlertService
// =============================================================================
//
// Plays a loud ringtone + TTS voice warning when Safety Mode detects abnormal
// movement, before any escalation dialog is shown.
//
// Uses Android's alarm audio stream so the sound plays even when the phone is
// set to silent or vibrate mode — ensuring the user hears the alert.
//
// Lifecycle:
//   - call playWarning()  → starts looping ringtone + speaks TTS message
//   - call stop()         → silences everything immediately
//   - call dispose()      → releases AudioPlayer resources (call from widget dispose)
//
// Thread safety: internally guards against re-entrancy with _disposed flag.
// =============================================================================

class SafetyAudioAlertService {
  // ignore: close_sinks — disposed manually via dispose()
  final AudioPlayer _player = AudioPlayer();
  final FlutterTts _tts = FlutterTts();
  bool _disposed = false;

  /// Play a looping alarm ringtone followed by a TTS spoken warning.
  ///
  /// [message] – the text the TTS engine will speak after the ringtone starts.
  /// If omitted a sensible default is used.
  ///
  /// Calling this while a previous alert is already playing will stop the
  /// current audio first, then restart with the new message.
  Future<void> playWarning({String? message}) async {
    if (_disposed) return;
    debugPrint('🔔 [SafetyAudio] Playing warning alert');

    try {
      // Stop any previous audio so double-calls behave cleanly.
      await _player.stop();
      await _tts.stop();

      // Route through the Android alarm stream so the sound bypasses the
      // ringer/vibrate setting — the same approach used in FakeCallScreen.
      await _player.setAudioContext(
        AudioContext(
          android: AudioContextAndroid(
            audioFocus: AndroidAudioFocus.gainTransientMayDuck,
            contentType: AndroidContentType.music,
            usageType: AndroidUsageType.alarm,
            audioMode: AndroidAudioMode.normal,
          ),
        ),
      );
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.setVolume(1.0);
      await _player.play(AssetSource('audio/alert_sound.mp3'));

      // Wait briefly so the ringtone is audible before TTS starts.
      await Future.delayed(const Duration(milliseconds: 900));
      if (_disposed) return;

      // Configure TTS for maximum clarity.
      await _tts.setLanguage('en-GB');
      await _tts.setSpeechRate(0.40);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.05);

      final text = message ??
          'Warning! SheSafe has detected unusual movement. '
          'If you are safe, please dismiss this alert. '
          'Otherwise, your emergency contacts will be alerted automatically.';

      await _tts.speak(text);
    } catch (e) {
      debugPrint('⚠️ [SafetyAudio] Error playing warning: $e');
    }
  }

  /// Immediately silence the alarm ringtone and any TTS speech.
  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {}
    try {
      await _tts.stop();
    } catch (_) {}
    debugPrint('🔕 [SafetyAudio] Alert audio stopped');
  }

  /// Release audio resources.  Call from the containing widget's dispose().
  /// Does NOT need to be awaited — fires stop + dispose in the background.
  void dispose() {
    _disposed = true;
    // Fire-and-forget cleanup — mirrors the pattern in FakeCallScreen.dispose().
    _player.stop();
    _tts.stop();
    _player.dispose();
  }
}
