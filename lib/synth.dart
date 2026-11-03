// lib/synth.dart — SoLoud output for the Dart SynthCore.
//
// Streams SynthCore's stereo float32 output to flutter_soloud through a
// released buffer stream, keeping ~90 ms rendered ahead of playback.
// See synth_core.dart and DEVIATIONS.md for why synthesis moved to Dart.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import 'dsp.dart';
import 'dsp_profile.dart';
import 'models.dart';
import 'synth_core.dart';

class SoloudSynthEngine {
  final SynthCore core = SynthCore();
  final SoLoud _sl = SoLoud.instance;

  AudioSource? _stream;
  SoundHandle? _handle;
  Timer? _pump;
  bool _initialized = false;
  bool get isInitialized => _initialized;

  static const int _block = 256;
  static const int _leadFrames = 4096; // ~93 ms ahead of playback
  final Float32List _blockBuf = Float32List(_block * 2);

  final Stopwatch _wall = Stopwatch();
  bool _useWallClock = false;

  final _noteEventsCtrl = StreamController<NoteEvent>.broadcast();
  Stream<NoteEvent> get noteEvents => _noteEventsCtrl.stream;

  /// Output-sample index currently being heard (approximately).
  int get playedFrames {
    final s = _stream;
    if (s == null) return 0;
    if (!_useWallClock) {
      try {
        final d = _sl.getStreamTimeConsumed(s);
        return (d.inMicroseconds * kSampleRate / 1e6).round();
      } catch (e) {
        debugPrint('Synth: getStreamTimeConsumed unavailable ($e); '
            'falling back to wall clock');
        _useWallClock = true;
      }
    }
    return (_wall.elapsedMicroseconds * kSampleRate / 1e6).round();
  }

  Future<void> init() async {
    if (_initialized) return;
    await _sl.init(sampleRate: 44100, bufferSize: 1024, channels: Channels.stereo);
    _stream = _sl.setBufferStream(
      maxBufferSizeDuration: const Duration(seconds: 10),
      bufferingType: BufferingType.released,
      bufferingTimeNeeds: 0.02,
      sampleRate: 44100,
      channels: Channels.stereo,
      format: BufferType.f32le,
    );
    // Pre-fill, then start playback.
    _renderAhead(_leadFrames);
    _handle = _sl.play(_stream!, volume: 1.0);
    _wall.start();
    _pump = Timer.periodic(const Duration(milliseconds: 8), (_) => _tick());
    _initialized = true;
  }

  void _tick() {
    if (_stream == null) return;
    final ahead = core.renderedFrames - playedFrames;
    if (ahead < _leadFrames) {
      // If we fell behind badly (UI stall), catch up but cap the burst.
      final need = (_leadFrames - ahead).clamp(0, _leadFrames * 2);
      _renderAhead(need);
    }
    final events = core.drainNoteEvents();
    for (final e in events) {
      if (!_noteEventsCtrl.isClosed) _noteEventsCtrl.add(e);
    }
  }

  void _renderAhead(int frames) {
    final s = _stream;
    if (s == null) return;
    int left = frames;
    while (left > 0) {
      final n = left < _block ? left : _block;
      core.render(_blockBuf, n);
      final bytes = Uint8List.view(_blockBuf.buffer, 0, n * 2 * 4);
      try {
        _sl.addAudioDataStream(s, Uint8List.fromList(bytes));
      } catch (e) {
        debugPrint('Synth: addAudioDataStream failed: $e');
        return;
      }
      left -= n;
    }
  }

  void playHelloPad() => core.playHelloPad();

  void apply(
    MusicalState state,
    DspProfile profile, {
    required double master,
    required double reverb,
    required double spatial,
    double? bpm,
  }) {
    core.apply(state, profile,
        master: master, reverb: reverb, spatial: spatial, bpm: bpm);
  }

  void applyMasterTrim(double linear) => core.setMasterTrim(linear);

  /// Mono reference of what is being heard now (last [n] samples).
  Float64List takeReferenceBlock(int n) =>
      core.referenceAt(playedFrames - n, n);

  Future<void> dispose() async {
    _pump?.cancel();
    _pump = null;
    final h = _handle;
    if (h != null) {
      try {
        _sl.fadeVolume(h, 0, const Duration(milliseconds: 300));
        await Future<void>.delayed(const Duration(milliseconds: 320));
        await _sl.stop(h);
      } catch (_) {}
    }
    try {
      _sl.deinit();
    } catch (_) {}
    await _noteEventsCtrl.close();
    _initialized = false;
  }
}
