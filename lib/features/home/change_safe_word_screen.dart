import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../../services/secure_storage_service.dart';

/// Lets the user change their safe word at any time after onboarding.
///
/// Two-phase flow:
///  1. Type phase  — user types the new word and taps "Continue".
///  2. Voice phase — app listens for 5 s; user must say the word aloud to
///                   confirm it works with speech recognition before it is saved.
class ChangeSafeWordScreen extends StatefulWidget {
  const ChangeSafeWordScreen({super.key});

  @override
  State<ChangeSafeWordScreen> createState() => _ChangeSafeWordScreenState();
}

enum _Phase { typing, voiceReady, voiceListening, voiceSuccess, voiceFailed }

class _ChangeSafeWordScreenState extends State<ChangeSafeWordScreen> {
  final _formKey  = GlobalKey<FormState>();
  final _controller = TextEditingController();
  final _storage  = SecureStorageService();
  final _speech   = SpeechToText();

  String? _currentWord;
  String  _pendingWord = '';    // word typed but not yet voice-confirmed
  String  _spokenWords = '';    // last heard transcript
  _Phase  _phase = _Phase.typing;
  bool    _speechAvailable = false;
  String? _voiceError;

  @override
  void initState() {
    super.initState();
    _loadCurrent();
    _initSpeech();
  }

  Future<void> _loadCurrent() async {
    final word = await _storage.getSafeWord();
    if (mounted) setState(() => _currentWord = word);
  }

  Future<void> _initSpeech() async {
    final available = await _speech.initialize(
      onError: (e) => debugPrint('STT error: $e'),
    );
    if (mounted) setState(() => _speechAvailable = available);
  }

  @override
  void dispose() {
    _controller.dispose();
    _speech.stop();
    super.dispose();
  }

  // ── Phase 1: user taps "Continue" after typing ──────────────────────────

  void _proceedToVoice() {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _pendingWord = _controller.text.trim().toLowerCase();
      _voiceError  = null;
      _spokenWords = '';
      _phase = _Phase.voiceReady;
    });
  }

  // ── Phase 2: start listening ─────────────────────────────────────────────

  Future<void> _startListening() async {
    // Ensure microphone permission
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Microphone permission is required to confirm your safe word.'),
            backgroundColor: const Color(0xFFB07080),
          ),
        );
      }
      return;
    }

    if (!_speechAvailable) {
      final ok = await _speech.initialize();
      if (!ok) {
        if (mounted) {
          setState(() {
            _voiceError = 'Speech recognition is not available on this device.';
            _phase = _Phase.voiceFailed;
          });
        }
        return;
      }
      _speechAvailable = true;
    }

    setState(() {
      _spokenWords = '';
      _voiceError  = null;
      _phase = _Phase.voiceListening;
    });

    bool recognised = false;
    final done = Completer<void>();

    await _speech.stop();
    final available = await _speech.initialize(
      onStatus: (status) {
        if (!done.isCompleted &&
            (status == 'done' || status == 'notListening')) {
          done.complete();
        }
      },
      onError: (error) {
        if (!done.isCompleted) done.complete();
      },
    );

    if (!available) {
      if (mounted) {
        setState(() {
          _voiceError = 'Speech recognition is not available on this device.';
          _phase = _Phase.voiceFailed;
        });
      }
      return;
    }

    String? localeId;
    try {
      final locales = await _speech.locales();
      if (locales.any((l) => l.localeId == 'en_GB')) {
        localeId = 'en_GB';
      }
    } catch (_) {
      localeId = null;
    }

    await _speech.listen(
      onResult: (result) async {
        if (!mounted) return;
        setState(() => _spokenWords = result.recognizedWords);

        final heard = _normalizeSpeech(result.recognizedWords);
        final target = _normalizeSpeech(_pendingWord);
        if (heard.contains(target)) {
          recognised = true;
          await _speech.stop();
          if (!done.isCompleted) done.complete();
        }
      },
      listenFor: const Duration(seconds: 15),
      pauseFor: const Duration(seconds: 5),
      localeId: localeId,
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.dictation,
        cancelOnError: false,
        partialResults: true,
      ),
    );

    await Future.any([
      done.future,
      Future.delayed(const Duration(seconds: 15)),
    ]);
    await _speech.stop();

    if (!mounted) return;

    if (recognised) {
      // Save the word now that it's been voice-confirmed
      await _storage.saveSafeWord(_pendingWord);
      setState(() {
        _currentWord = _pendingWord;
        _phase = _Phase.voiceSuccess;
      });
    } else {
      setState(() {
        _voiceError = _spokenWords.trim().isEmpty
            ? 'No speech was detected. Please speak clearly and try again.'
            : 'Safe word not detected. Speak clearly and try again.';
        _phase = _Phase.voiceFailed;
      });
    }
  }

  String _normalizeSpeech(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  void _retryVoice() {
    setState(() {
      _spokenWords = '';
      _voiceError  = null;
      _phase = _Phase.voiceReady;
    });
  }

  void _backToTyping() {
    setState(() {
      _phase = _Phase.typing;
      _voiceError = null;
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF0F5),
      appBar: AppBar(
        title: Text((_currentWord != null && _currentWord!.isNotEmpty)
            ? 'Change Safe Word'
            : 'Set Your Safe Word'),
        leading: _phase != _Phase.typing
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _backToTyping,
              )
            : null,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: _phase == _Phase.typing
              ? _buildTypingPhase()
              : _buildVoicePhase(),
        ),
      ),
    );
  }

  // ── Phase 1 UI ────────────────────────────────────────────────────────────

  Widget _buildTypingPhase() {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Current word display
          if (_currentWord != null && _currentWord!.isNotEmpty)
            Card(
              color: const Color(0xFFF8D7E3),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Icon(Icons.lock_outline, color: Color(0xFFB07080)),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Current safe word',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFFB07080),
                          ),
                        ),
                        Text(
                          '"$_currentWord"',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFA0406A),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 24),

          Text(
            (_currentWord != null && _currentWord!.isNotEmpty)
                ? 'New Safe Word'
                : 'Your Safe Word',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Speak this word during Panic Mode to silently cancel the alert if you\'re safe.',
            style: TextStyle(fontSize: 14, color: Color(0xFF5C4A55)),
          ),
          const SizedBox(height: 20),

          // Protection info container
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF8D7E3),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFF0B8CC)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.shield_rounded,
                        size: 18, color: Color(0xFFB07080)),
                    SizedBox(width: 8),
                    Text(
                      'How the safe word works',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFB07080),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 10),
                Text(
                  'When Panic Mode activates, SheSafe listens for your safe word. Say it and the alert cancels silently — no message is sent.',
                  style: TextStyle(fontSize: 13.5, height: 1.6),
                ),
                SizedBox(height: 8),
                Text(
                  'Audio is never recorded or stored.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFFA0406A),
                    fontStyle: FontStyle.italic,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Input
          TextFormField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: (_currentWord != null && _currentWord!.isNotEmpty)
                  ? 'Enter new safe word'
                  : 'Your safe word',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.lock, color: Color(0xFFB07080)),
              hintText: 'e.g. pineapple',
              hintStyle: const TextStyle(fontSize: 13),
              suffixIcon: IconButton(
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.only(right: 10),
                icon: const Icon(Icons.info_outline,
                    color: Color(0xFF9B72CB), size: 16),
                iconSize: 16,
                tooltip: 'Tips for choosing',
                onPressed: () => _showTipsSheet(context),
              ),
            ),
            textCapitalization: TextCapitalization.none,
            autofocus: true,
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Please enter a safe word';
              }
              if (value.trim().split(' ').length > 3) {
                return 'Maximum 3 words';
              }
              const common = ['hello', 'ok', 'yes', 'no', 'the', 'a', 'an'];
              if (common.contains(value.trim().toLowerCase())) {
                return 'Too common — please choose a different word';
              }
              if (_currentWord != null &&
                  value.trim().toLowerCase() == _currentWord) {
                return 'That\'s already your current safe word';
              }
              return null;
            },
          ),
          const SizedBox(height: 28),

          ElevatedButton.icon(
            onPressed: _proceedToVoice,
            icon: const Icon(Icons.mic),
            label: const Text(
              'Continue — Confirm by voice',
              style: TextStyle(fontSize: 16),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFB07080),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );
  }

  // ── Phase 2 UI ────────────────────────────────────────────────────────────

  Widget _buildVoicePhase() {
    switch (_phase) {
      case _Phase.voiceReady:
        return _buildVoiceReady();
      case _Phase.voiceListening:
        return _buildVoiceListening();
      case _Phase.voiceSuccess:
        return _buildVoiceSuccess();
      case _Phase.voiceFailed:
        return _buildVoiceFailed();
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildVoiceReady() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        Center(
          child: const Icon(Icons.mic, size: 90, color: Color(0xFF9B72CB)),
        ),
        const SizedBox(height: 24),
        const Text(
          'Say Your Safe Word',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        const Text(
          'Before we save it, please say the word aloud so we can confirm speech recognition detects it correctly.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: Colors.black54),
        ),
        const SizedBox(height: 28),
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              children: [
                Text(
                  'Your new safe word:',
                  style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 8),
                Text(
                  '"$_pendingWord"',
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFB07080),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Tap the button below, then say the word clearly within 7 seconds.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 28),
        ElevatedButton.icon(
          onPressed: _startListening,
          icon: const Icon(Icons.mic),
          label: const Text('Start Listening', style: TextStyle(fontSize: 16)),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFB07080),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: _backToTyping,
          child: const Text('← Change the word'),
        ),
      ],
    );
  }

  Widget _buildVoiceListening() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        Center(
          child: Stack(
            alignment: Alignment.center,
            children: [
              const SizedBox(
                width: 160,
                height: 160,
                child: CircularProgressIndicator(
                  strokeWidth: 6,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(Color(0xFF9B72CB)),
                ),
              ),
              Icon(Icons.mic, size: 70, color: Colors.red.shade400),
            ],
          ),
        ),
        const SizedBox(height: 28),
        const Text(
          'Listening…',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Text(
              'Say: "$_pendingWord"',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
                color: Color(0xFF9B72CB),
              ),
            ),
          ),
        ),
        if (_spokenWords.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            'Heard: "$_spokenWords"',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
          ),
        ],
      ],
    );
  }

  Widget _buildVoiceSuccess() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 32),
        const Center(
          child: Icon(Icons.check_circle, size: 100, color: Color(0xFFB07080)),
        ),
        const SizedBox(height: 24),
        const Text(
          'Safe Word Saved!',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: Color(0xFFB07080),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Your safe word has been confirmed by voice and saved successfully.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: Colors.grey.shade700),
        ),
        const SizedBox(height: 24),
        Card(
          color: const Color(0xFFF8D7E3),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
            child: Column(
              children: [
                const Text(
                  'Safe word saved:',
                  style: TextStyle(fontSize: 13, color: Color(0xFFB07080)),
                ),
                const SizedBox(height: 6),
                Text(
                  '"$_currentWord"',
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFA0406A),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 36),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFB07080),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('Done', style: TextStyle(fontSize: 16)),
        ),
      ],
    );
  }

  Widget _buildVoiceFailed() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 32),
        Center(
          child: const Icon(Icons.mic_off, size: 90, color: Color(0xFFE8956D)),
        ),
        const SizedBox(height: 24),
        const Text(
          'Word Not Detected',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        if (_voiceError != null)
          Text(
            _voiceError!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Color(0xFFB07080)),
          ),
        const SizedBox(height: 20),
        // Tips
        Card(
          color: const Color(0xFFEDE7F6),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.tips_and_updates,
                        size: 16, color: Color(0xFF9B72CB)),
                    SizedBox(width: 6),
                    Text('Tips to help recognition',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF9B72CB))),
                  ],
                ),
                const SizedBox(height: 8),
                _tip('• Speak clearly and loudly'),
                _tip('• Reduce background noise'),
                _tip('• Hold the phone closer to your mouth'),
                _tip('• Try a different, simpler word'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        ElevatedButton.icon(
          onPressed: _retryVoice,
          icon: const Icon(Icons.refresh),
          label: const Text('Try Again', style: TextStyle(fontSize: 16)),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFB07080),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _backToTyping,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('Choose a Different Word',
              style: TextStyle(fontSize: 15)),
        ),
      ],
    );
  }

  void _showTipsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEDE7F6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.tips_and_updates,
                        color: Color(0xFF9B72CB)),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Tips for Choosing',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _tip('✓  Use 1–3 words maximum'),
              _tip('✓  Choose something memorable'),
              _tip('✓  Easy to pronounce clearly'),
              _tip('✗  Avoid common words (hello, ok)'),
              _tip('✗  Don\'t use names or locations'),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tip(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(text,
            style: const TextStyle(fontSize: 13, color: Colors.black87)),
      );
}
