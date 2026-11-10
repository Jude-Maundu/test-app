import 'dart:async';
import 'dart:io' show Platform, Process, ProcessSignal, File;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:test_app/services/llm_service.dart';

enum AssistantState { idle, listening, thinking, speaking }

class AssistantProvider extends ChangeNotifier {
  final SpeechToText _speech = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final LLMService _llmService = LLMService();

  static final bool _isLinux = !kIsWeb && Platform.isLinux;

  AssistantState _state = AssistantState.idle;
  String _lastCommand = "";
  String _lastResponse = "";
  bool _isListening = false;

  bool _speechAvailable = false;
  double _soundLevel = 0;
  double _speechRate = 0.5;
  String? _selectedVoice;
  List<Map<String, String>> _voices = [];

  Process? _linuxRecordProcess;
  Timer? _soundTimer;
  Timer? _linuxListenTimeout;

  /// True once the current command has been sent on (or cancelled), so a late
  /// duplicate event can never run the same command twice.
  bool _handled = false;

  /// The recognizer reports "notListening" before it starts. Ignore status
  /// events until it has reported "listening" for the current session.
  bool _sessionStarted = false;

  /// Bumped every time listening starts. Slow work from an earlier turn checks
  /// it so it can't overwrite the state of a newer one.
  int _session = 0;

  FutureOr<void> Function(String)? _onCommand;

  AssistantState get state => _state;
  String get lastCommand => _lastCommand;
  String get lastResponse => _lastResponse;
  bool get isListening => _isListening;
  double get soundLevel => _soundLevel;
  double get speechRate => _speechRate;
  String? get selectedVoice => _selectedVoice;
  List<Map<String, String>> get voices => List.unmodifiable(_voices);

  /// Voice features are supported on Android and Linux desktop.
  bool get voiceSupported => true;
  bool get speechAvailable => _speechAvailable;

  /// Runs a TTS call safely and swallows plugin errors.
  Future<void> _ttsCall(Future<dynamic> Function() action) async {
    if (_isLinux) return;
    try {
      await action();
    } catch (e) {
      debugPrint('TTS call failed: $e');
    }
  }

  Future<void> init() async {
    try {
      final savedRate = await _storage.read(key: 'jarvis_speech_rate');
      if (savedRate != null) {
        _speechRate = double.tryParse(savedRate) ?? _speechRate;
      }
      _selectedVoice = await _storage.read(key: 'jarvis_tts_voice');
    } catch (e) {
      debugPrint('Secure storage read failed: $e');
    }

    if (_isLinux) {
      await _initLinux();
      return;
    }

    await _initSpeech();

    try {
      await _tts.setLanguage("en-US");
      // Without this, speak() returns immediately and the "speaking" state
      // ends as soon as speech starts instead of when it finishes.
      await _tts.awaitSpeakCompletion(true);
      await _tts.setSpeechRate(_speechRate);

      final availableVoices = await _tts.getVoices;
      if (availableVoices is List) {
        _voices = availableVoices
            .whereType<Map<dynamic, dynamic>>()
            .map<Map<String, String>>(
              (voice) => voice.map(
                (key, value) => MapEntry(key.toString(), value.toString()),
              ),
            )
            .where(
              (voice) =>
                  voice['name'] != null &&
                  (voice['locale']?.startsWith('en') ?? false),
            )
            .toList();
      }
      if (_selectedVoice != null) {
        final voice = _voices
            .where((voice) => _voiceId(voice) == _selectedVoice)
            .firstOrNull;
        if (voice != null) await _tts.setVoice(voice);
      }
    } catch (e) {
      debugPrint('TTS init failed: $e');
    }
  }

  Future<void> _initLinux() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      _speechAvailable = true;
      return;
    }
    // Check arecord for speech input
    try {
      final arecordCheck = await Process.run('which', ['arecord']);
      _speechAvailable = arecordCheck.exitCode == 0;
    } catch (_) {
      _speechAvailable = false;
    }

    // Load Linux synthesis voices using spd-say -L
    try {
      final res = await Process.run('spd-say', ['-L']);
      if (res.exitCode == 0) {
        final lines = (res.stdout as String).split('\n');
        final linuxVoices = <Map<String, String>>[];
        for (final line in lines.skip(1)) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;
          final parts = trimmed.split(RegExp(r'\s{2,}'));
          if (parts.length >= 2) {
            final name = parts[0].trim();
            final lang = parts[1].trim();
            if (lang.startsWith('en')) {
              linuxVoices.add({'name': name, 'locale': lang});
            }
          }
        }
        if (linuxVoices.isNotEmpty) {
          _voices = linuxVoices;
        }
      }
    } catch (e) {
      debugPrint('Error loading Linux voices: $e');
    }
  }

  Future<bool> _initSpeech() async {
    if (_isLinux) {
      _speechAvailable = true;
      return true;
    }
    try {
      _speechAvailable = await _speech.initialize(
        onStatus: _onStatus,
        onError: _onError,
      );
    } catch (e) {
      debugPrint('Speech init failed: $e');
      _speechAvailable = false;
    }
    return _speechAvailable;
  }

  void setState(AssistantState newState) {
    _state = newState;
    notifyListeners();
  }

  Future<void> startListening(FutureOr<void> Function(String) onResult) async {
    if (_isListening) return;

    if (_isLinux) {
      await _startLinuxListening(onResult);
      return;
    }

    if (!_speechAvailable && !await _initSpeech()) {
      _lastResponse =
          'Speech recognition is not available. Check the microphone permission.';
      notifyListeners();
      return;
    }

    // Let the user interrupt Jarvis mid-sentence.
    await _ttsCall(_tts.stop);

    _session++;
    _onCommand = onResult;
    _handled = false;
    _sessionStarted = false;
    _lastCommand = "";
    _lastResponse = "";
    _isListening = true;
    setState(AssistantState.listening);

    try {
      await _speech.listen(
        onResult: _onSpeechResult,
        onSoundLevelChange: (level) {
          _soundLevel = level;
          notifyListeners();
        },
        listenOptions: SpeechListenOptions(
          listenFor: const Duration(seconds: 30),
          pauseFor: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      debugPrint('Speech listen failed: $e');
      _handled = true;
      _isListening = false;
      _soundLevel = 0;
      _lastResponse = 'Could not start listening.';
      setState(AssistantState.idle);
    }
  }

  Future<void> _startLinuxListening(
    FutureOr<void> Function(String) onResult,
  ) async {
    await stopSpeaking();

    try {
      final whichCheck = await Process.run('which', ['arecord']);
      if (whichCheck.exitCode != 0) {
        _lastResponse =
            'Audio recording tool "arecord" was not found on this system.';
        notifyListeners();
        return;
      }
    } catch (e) {
      _lastResponse = 'Could not access audio recording: $e';
      notifyListeners();
      return;
    }

    _session++;
    _onCommand = onResult;
    _handled = false;
    _lastCommand = "";
    _lastResponse = "";
    _isListening = true;
    setState(AssistantState.listening);

    const recordingPath = '/tmp/jarvis_recording.wav';
    try {
      final file = File(recordingPath);
      if (file.existsSync()) file.deleteSync();

      _linuxRecordProcess = await Process.start('arecord', [
        '-q',
        '-f',
        'S16_LE',
        '-r',
        '16000',
        '-c',
        '1',
        recordingPath,
      ]);

      // Animate the sound level so the voice orb pulses smoothly
      _soundTimer?.cancel();
      var tick = 0;
      _soundTimer = Timer.periodic(const Duration(milliseconds: 100), (t) {
        if (!_isListening) {
          t.cancel();
          return;
        }
        tick++;
        _soundLevel = 0.25 + 0.6 * (math.sin(tick * 0.4).abs());
        notifyListeners();
      });

      // Timeout safety: auto-stop after 20 seconds
      _linuxListenTimeout?.cancel();
      _linuxListenTimeout = Timer(const Duration(seconds: 20), () {
        if (_isListening) {
          stopListening();
        }
      });
    } catch (e) {
      debugPrint('Error starting arecord: $e');
      _isListening = false;
      _soundLevel = 0;
      _lastResponse = 'Could not access microphone: $e';
      setState(AssistantState.idle);
    }
  }

  /// Cancels the current session without sending anything to the LLM, so a
  /// stray tap can't trigger a call or text.
  void stopListening() {
    if (!_isListening) return;
    _handled = true;
    _isListening = false;
    _soundLevel = 0;
    _soundTimer?.cancel();
    _linuxListenTimeout?.cancel();

    if (_isLinux) {
      _stopLinuxListening();
      return;
    }

    _speech.cancel();
    setState(AssistantState.idle);
  }

  Future<void> _stopLinuxListening() async {
    setState(AssistantState.thinking);
    try {
      if (_linuxRecordProcess != null) {
        _linuxRecordProcess!.kill(ProcessSignal.sigint);
        await _linuxRecordProcess!.exitCode.timeout(
          const Duration(milliseconds: 500),
          onTimeout: () {
            _linuxRecordProcess?.kill();
            return 0;
          },
        );
        _linuxRecordProcess = null;
      }

      await Future.delayed(const Duration(milliseconds: 150));

      final file = File('/tmp/jarvis_recording.wav');
      if (!file.existsSync() || file.lengthSync() < 1000) {
        _lastResponse = 'No speech detected.';
        setState(AssistantState.idle);
        return;
      }

      final transcript = await _llmService.transcribeAudioFile(file.path);
      final text = transcript.trim();
      if (text.isEmpty) {
        _lastResponse = 'No speech recognized.';
        setState(AssistantState.idle);
        return;
      }

      _lastCommand = text;
      notifyListeners();
      _dispatch(text);
    } catch (e) {
      debugPrint('Linux speech transcription error: $e');
      _lastResponse = '$e';
      setState(AssistantState.idle);
    }
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    if (!_isListening) return;
    _lastCommand = result.recognizedWords;
    notifyListeners(); // live transcript while the user speaks
    if (result.finalResult) _endSession();
  }

  void _onStatus(String status) {
    if (status == 'listening') {
      _sessionStarted = true;
    } else if (_sessionStarted &&
        (status == 'done' || status == 'notListening')) {
      // The recognizer stopped by itself (silence or time limit).
      _endSession();
    }
  }

  void _onError(SpeechRecognitionError error) {
    if (!_isListening) return;
    _handled = true;
    _isListening = false;
    _soundLevel = 0;
    if (error.permanent) {
      _lastResponse = 'Speech recognition error: ${error.errorMsg}';
    }
    setState(AssistantState.idle);
  }

  /// Ends the session and hands the finished command on, once.
  void _endSession() {
    if (!_isListening) return;
    _isListening = false;
    if (!_isLinux) _speech.stop();

    final text = _lastCommand.trim();
    if (_handled || text.isEmpty) {
      setState(AssistantState.idle);
      return;
    }
    _handled = true;
    _dispatch(text);
  }

  Future<void> _dispatch(String text) async {
    final session = _session;
    // Set before the callback runs so nothing can reset it to idle first.
    setState(AssistantState.thinking);
    try {
      await _onCommand?.call(text);
    } catch (error) {
      _lastResponse = 'Something went wrong: $error';
    } finally {
      if (session == _session && _state != AssistantState.idle) {
        setState(AssistantState.idle);
      }
    }
  }

  Future<void> speak(String text) async {
    if (_isListening) return; // never talk over the user
    final session = _session;
    _lastResponse = text;
    if (text.trim().isEmpty) {
      setState(AssistantState.idle);
      return;
    }

    if (_isLinux) {
      await _speakLinux(text, session);
      return;
    }

    setState(AssistantState.speaking);
    try {
      await _ttsCall(() => _tts.speak(text));
    } finally {
      if (session == _session && _state == AssistantState.speaking) {
        setState(AssistantState.idle);
      }
    }
  }

  Future<void> _speakLinux(String text, int session) async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      setState(AssistantState.idle);
      return;
    }
    setState(AssistantState.speaking);
    try {
      final rate = ((-0.5 + _speechRate) * 200).round().clamp(-100, 100);
      final voice = _selectedVoice;
      final args = [
        '-w', // wait till finished speaking
        '-r',
        rate.toString(),
        if (voice != null && voice.isNotEmpty) ...['-y', voice],
        text,
      ];
      final res = await Process.run('spd-say', args);
      if (res.exitCode != 0) {
        // Fallback to espeak
        await Process.run('espeak', [text]);
      }
    } catch (e) {
      debugPrint('Linux TTS error: $e');
    } finally {
      if (session == _session && _state == AssistantState.speaking) {
        setState(AssistantState.idle);
      }
    }
  }

  Future<void> setSpeechRate(double rate) async {
    _speechRate = rate.clamp(0.25, 1.0);
    await _ttsCall(() => _tts.setSpeechRate(_speechRate));
    try {
      await _storage.write(
        key: 'jarvis_speech_rate',
        value: _speechRate.toString(),
      );
    } catch (e) {
      debugPrint('Secure storage write failed: $e');
    }
    notifyListeners();
  }

  Future<void> setVoice(String? voiceId) async {
    _selectedVoice = voiceId;
    try {
      if (voiceId == null) {
        await _storage.delete(key: 'jarvis_tts_voice');
      } else {
        final voice = _voices
            .where((voice) => _voiceId(voice) == voiceId)
            .firstOrNull;
        if (voice != null) {
          await _ttsCall(() => _tts.setVoice(voice));
          await _storage.write(key: 'jarvis_tts_voice', value: voiceId);
        }
      }
    } catch (e) {
      debugPrint('Secure storage update failed: $e');
    }
    notifyListeners();
  }

  String _voiceId(Map<String, String> voice) =>
      '${voice['name']}|${voice['locale']}';

  Future<void> stopSpeaking() async {
    if (_isLinux) {
      try {
        await Process.run('spd-say', ['-C']);
      } catch (_) {}
      if (_state == AssistantState.speaking) {
        setState(AssistantState.idle);
      }
      return;
    }

    await _ttsCall(_tts.stop);
    if (_state == AssistantState.speaking) {
      setState(AssistantState.idle);
    }
  }

  @override
  void dispose() {
    _soundTimer?.cancel();
    _linuxListenTimeout?.cancel();
    if (_linuxRecordProcess != null) {
      _linuxRecordProcess?.kill();
      _linuxRecordProcess = null;
    }
    if (_isLinux) {
      if (!Platform.environment.containsKey('FLUTTER_TEST')) {
        Process.run('spd-say', ['-C']).ignore();
      }
    } else {
      _speech.cancel();
      _tts.stop();
    }
    super.dispose();
  }
}