// lib/input_router.dart — §8.2 (adapted to record 7.x; see DEVIATIONS.md)
//
// Owns the AudioRecorder, enumerates devices, downmixes PCM16 to mono
// Float64 frames, emits per-channel RMS (~10 Hz) and a one-shot mains
// hum detection (50/60 Hz). Does NOT do HPF/AEC/notches/limiter.

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

enum InputClass { builtin, headset, bluetooth, usb, audioInterface, unknown }

class InputDeviceInfo {
  final String id;
  final String label;
  final bool isDefault;
  final int channels; // display hint only (bug #39/#40: true count via retry ladder)
  final InputClass klass;
  final InputDevice raw;
  const InputDeviceInfo({
    required this.id,
    required this.label,
    required this.isDefault,
    required this.channels,
    required this.klass,
    required this.raw,
  });
}

double _tanh(double x) {
  if (x > 20) return 1.0;
  if (x < -20) return -1.0;
  final e2 = exp(2 * x);
  return (e2 - 1) / (e2 + 1);
}

class InputRouter {
  static const int sampleRate = 44100;

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;

  int _numChannels = 1;
  int _frameSize = 2048;
  List<int>? _selectedChannels;
  InputDevice? _device;

  double _dcPrevX = 0, _dcPrevY = 0; // bug #21
  double _gain = 1.0;

  // Mono assembly buffer (ring of doubles, avoids List<double> growth churn)
  Float64List _mono = Float64List(16384);
  int _monoLen = 0;

  final _framesCtrl = StreamController<Float64List>.broadcast();
  final _channelRmsCtrl = StreamController<List<double>>.broadcast();
  final _humCtrl = StreamController<int>.broadcast();
  final _errorCtrl = StreamController<String>.broadcast();

  Stream<Float64List> get frames => _framesCtrl.stream;
  Stream<List<double>> get channelRms => _channelRmsCtrl.stream;
  Stream<int> get humDetected => _humCtrl.stream;
  Stream<String> get errors => _errorCtrl.stream;

  DateTime _lastRmsEmit = DateTime(2000);

  final Float64List _humBuf = Float64List(sampleRate * 2);
  int _humLen = 0;
  bool _humCheckDone = false;

  bool get isRunning => _sub != null;
  int get currentChannels => _numChannels;
  int get currentFrameSize => _frameSize;

  /// Linear input gain from the UI's dB slider.
  void setGainDb(double db) => _gain = pow(10, db / 20).toDouble();

  // ─── Device enumeration ─────────────────────────────────────────

  Future<List<InputDeviceInfo>> listDevices() async {
    try {
      final raw = await _recorder.listInputDevices();
      return [
        for (int i = 0; i < raw.length; i++)
          InputDeviceInfo(
            id: raw[i].id,
            label: raw[i].label,
            isDefault: i == 0,
            channels: _channelsFromLabel(raw[i].label),
            klass: _classify(raw[i].label),
            raw: raw[i],
          ),
      ];
    } catch (e) {
      debugPrint('InputRouter: listInputDevices failed: $e');
      return const [];
    }
  }

  static InputClass _classify(String label) {
    final l = label.toLowerCase();
    if (RegExp(r'bluetooth|airpods|buds|wireless|hands-free|\bbt\b').hasMatch(l)) {
      return InputClass.bluetooth;
    }
    if (RegExp(r'headset|headphone|earphone').hasMatch(l)) {
      return InputClass.headset;
    }
    if (RegExp(r'focusrite|scarlett|audient|motu|behringer|presonus|'
            r'universal\s*audio|apollo|interface|\bline\b|\bdi\b|instrument|'
            r'steinberg|roland|zoom|line 6|helix|pod')
        .hasMatch(l)) {
      return InputClass.audioInterface;
    }
    if (RegExp(r'\busb\b').hasMatch(l)) return InputClass.usb;
    if (RegExp(r'built-?in|internal|array|realtek|default').hasMatch(l)) {
      return InputClass.builtin;
    }
    return InputClass.unknown;
  }

  static int _channelsFromLabel(String label) {
    final m = RegExp(r'(\d+)\s*(?:in|i\b|ch)').firstMatch(label.toLowerCase());
    final n = int.tryParse(m?.group(1) ?? '');
    return (n != null && n >= 1 && n <= 16) ? n : 1;
  }

  // ─── Selection ──────────────────────────────────────────────────

  Future<void> selectDevice(InputDevice? device, {List<int>? channels}) async {
    await stop();
    _device = device;
    _selectedChannels = channels;
    await start();
  }

  void setChannels(List<int>? channels) => _selectedChannels = channels;

  void setFrameSize(int size) {
    if (size == _frameSize) return;
    _frameSize = size;
    _monoLen = 0;
  }

  // ─── Start / stop ───────────────────────────────────────────────

  Future<bool> start() async {
    if (_sub != null) return true;
    try {
      if (!await _recorder.hasPermission()) {
        _errorCtrl.add('Microphone permission denied.');
        return false;
      }
    } catch (e) {
      _errorCtrl.add('Microphone unavailable: $e');
      return false;
    }

    // Retry ladder (bug #14): the error comes from startStream(). On
    // Android also fall back from the UNPROCESSED source (API 24+, not
    // supported by every phone) to the default source.
    Stream<Uint8List>? stream;
    outer:
    for (final source in const [
      AndroidAudioSource.unprocessed,
      AndroidAudioSource.voiceRecognition,
      AndroidAudioSource.defaultSource,
    ]) {
      for (final ch in const [2, 1]) {
        try {
          stream = await _recorder.startStream(_makeConfig(ch, source));
          _numChannels = ch;
          debugPrint('InputRouter: started with $ch channel(s), $source');
          break outer;
        } catch (e) {
          debugPrint('InputRouter: ${ch}ch/$source failed: $e');
          try {
            await _recorder.stop();
          } catch (_) {}
        }
      }
      if (!Platform.isAndroid) break; // source only matters on Android
    }
    if (stream == null) {
      _errorCtrl.add('Could not open the microphone.');
      return false;
    }

    _monoLen = 0;
    _humLen = 0;
    _humCheckDone = false;
    _dcPrevX = 0;
    _dcPrevY = 0;

    _sub = stream.listen(_onBytes, onError: (Object e) {
      debugPrint('InputRouter: stream error: $e');
      _errorCtrl.add('Input stream error: $e');
    });
    return true;
  }

  RecordConfig _makeConfig(int channels, AndroidAudioSource source) =>
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: channels,
        device: _device,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
        androidConfig: AndroidRecordConfig(audioSource: source),
      );

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    _monoLen = 0;
  }

  Future<void> dispose() async {
    await stop();
    try {
      await _recorder.dispose();
    } catch (_) {}
    await _framesCtrl.close();
    await _channelRmsCtrl.close();
    await _humCtrl.close();
    await _errorCtrl.close();
  }

  // ─── Byte handling ──────────────────────────────────────────────

  void _onBytes(Uint8List bytes) {
    if (bytes.length < 2) return;
    final bd = ByteData.sublistView(bytes);
    final totalSamples = bytes.length ~/ 2;
    final nCh = _numChannels;
    final numFrames = totalSamples ~/ nCh;
    if (numFrames == 0) return;

    _maybeEmitRms(bd, numFrames, nCh);

    final selected = (_selectedChannels ?? List<int>.generate(nCh, (i) => i))
        .where((c) => c < nCh)
        .toList();
    if (selected.isEmpty) return;
    final g = _gain / sqrt(selected.length.toDouble());

    // Ensure capacity.
    if (_monoLen + numFrames > _mono.length) {
      final bigger = Float64List(max(_mono.length * 2, _monoLen + numFrames));
      bigger.setRange(0, _monoLen, _mono);
      _mono = bigger;
    }

    double prevX = _dcPrevX, prevY = _dcPrevY;
    for (int f = 0; f < numFrames; f++) {
      double sum = 0;
      for (final ch in selected) {
        sum += bd.getInt16((f * nCh + ch) * 2, Endian.little) / 32768.0;
      }
      final x = sum * g;
      final y = x - prevX + 0.995 * prevY; // bug #21
      prevX = x;
      prevY = y;
      final s = _tanh(y * 1.2) / 1.2; // soft limit, unity small-signal gain
      _mono[_monoLen + f] = s;
      if (!_humCheckDone && _humLen < _humBuf.length) {
        _humBuf[_humLen++] = s;
      }
    }
    _dcPrevX = prevX;
    _dcPrevY = prevY;
    _monoLen += numFrames;

    if (!_humCheckDone && _humLen >= _humBuf.length) _detectHum();

    // Emit full frames.
    int offset = 0;
    while (_monoLen - offset >= _frameSize) {
      final frame = Float64List.fromList(
          Float64List.sublistView(_mono, offset, offset + _frameSize));
      offset += _frameSize;
      if (!_framesCtrl.isClosed) _framesCtrl.add(frame);
    }
    if (offset > 0) {
      _mono.setRange(0, _monoLen - offset, _mono, offset);
      _monoLen -= offset;
    }
  }

  void _maybeEmitRms(ByteData bd, int numFrames, int nCh) {
    final now = DateTime.now();
    if (now.difference(_lastRmsEmit).inMilliseconds < 100) return;
    _lastRmsEmit = now;
    final rms = List<double>.filled(nCh, 0.0);
    for (int f = 0; f < numFrames; f++) {
      for (int ch = 0; ch < nCh; ch++) {
        final v = bd.getInt16((f * nCh + ch) * 2, Endian.little) / 32768.0;
        rms[ch] += v * v;
      }
    }
    for (int ch = 0; ch < nCh; ch++) {
      rms[ch] = sqrt(rms[ch] / numFrames).clamp(0.0, 1.0);
    }
    if (!_channelRmsCtrl.isClosed) _channelRmsCtrl.add(rms);
  }

  // ─── Hum detection (one-shot Goertzel) ──────────────────────────

  void _detectHum() {
    _humCheckDone = true;
    final p50 = goertzelPower(_humBuf, 50.0, sampleRate);
    final p60 = goertzelPower(_humBuf, 60.0, sampleRate);
    final pRef = (goertzelPower(_humBuf, 55.0, sampleRate) +
            goertzelPower(_humBuf, 45.0, sampleRate)) /
        2;
    if (pRef < 1e-12) return;
    if (p50 > 10 * pRef && p50 > p60) {
      if (!_humCtrl.isClosed) _humCtrl.add(50);
    } else if (p60 > 10 * pRef && p60 > p50) {
      if (!_humCtrl.isClosed) _humCtrl.add(60);
    }
  }

  static double goertzelPower(Float64List samples, double freq, int sr) {
    final n = samples.length;
    final k = (n * freq / sr).round();
    final coeff = 2.0 * cos(2.0 * pi * k / n);
    double s1 = 0, s2 = 0;
    for (int i = 0; i < n; i++) {
      final s0 = samples[i] + coeff * s1 - s2;
      s2 = s1;
      s1 = s0;
    }
    return s1 * s1 + s2 * s2 - coeff * s1 * s2;
  }
}
