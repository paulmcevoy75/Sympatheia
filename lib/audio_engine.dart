// lib/audio_engine.dart — Phase 1 orchestration.
//
//   mic (InputRouter) → HPF 55 → mains notch → soft limiter
//   → AnalysisPipeline → PercussionAnalyzer → AccompanimentBrain
//   → SynthCore (Dart) → SoLoud stream
//
// Phase 1 scope (spec phase plan): no AEC, feedback suppressor, coupling
// guard, AutoTrim or MIDI — those arrive in Phases 2/4/5. Use headphones
// in Phase 1, or the mic will hear the accompaniment.

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'analysis.dart';
import 'brain.dart';
import 'dsp.dart';
import 'dsp_profile.dart';
import 'input_router.dart';
import 'percussion.dart';
import 'state.dart';
import 'synth.dart';

class AudioEngine {
  final AppState app;

  final InputRouter input = InputRouter();
  final AnalysisPipeline analysis = AnalysisPipeline();
  final PercussionAnalyzer percussion = PercussionAnalyzer();
  final AccompanimentBrain brain = AccompanimentBrain();
  final SoloudSynthEngine synth = SoloudSynthEngine();

  double _lastSynthRms = 0.0; // bug #15: previous frame's level
  double _noiseFloor = 0.002; // adaptive input noise floor (linear RMS)
  double _hpPrevX = 0.0, _hpPrevY = 0.0; // bug #21
  List<Biquad> _mains = const [];

  StreamSubscription<Float64List>? _frameSub;
  StreamSubscription<int>? _humSub;
  StreamSubscription<String>? _inputErrSub;

  bool _listeningChipShown = false;
  bool _started = false;
  bool get started => _started;
  String? startError;

  final _warningsCtrl = StreamController<String>.broadcast();
  Stream<String> get warnings => _warningsCtrl.stream;

  AudioEngine(this.app);

  // ─── Start ────────────────────────────────────────────────────────

  Future<void> start() async {
    if (_started) return;
    try {
      await synth.init();
    } catch (e) {
      startError = 'Audio output failed to start: $e';
      debugPrint('AudioEngine: $startError');
      _showWarningChip('Audio output failed to start.');
      return; // app stays up, silent (§11.4.6)
    }

    _humSub = input.humDetected.listen((hz) {
      debugPrint('AudioEngine: $hz Hz mains hum detected');
      _mains = [
        for (int h = 1; h <= 6; h++) Biquad.notch(hz * h.toDouble(), 30),
      ];
    });
    _inputErrSub = input.errors.listen(_showWarningChip);

    input.setGainDb(app.inputGainDb);
    _frameSub = input.frames.listen(_processFrame);
    bool ok;
    final saved = app.selectedInputDeviceId;
    InputDeviceInfo? savedDevice;
    if (saved != null) {
      for (final d in await input.listDevices()) {
        if (d.id == saved) savedDevice = d;
      }
    }
    if (savedDevice != null) {
      await input.selectDevice(savedDevice.raw);
      ok = input.isRunning;
    } else {
      ok = await input.start();
    }
    if (!ok) {
      // Mic denied: hello pad only, status Idle (§11.4.6).
      debugPrint('AudioEngine: mic unavailable');
    }

    // Phase 1 has no AEC, so there is no calibration sweep; the hello pad
    // plays right away (§11.4.2 / bug #52 ordering still holds).
    try {
      synth.playHelloPad();
    } catch (e) {
      debugPrint('AudioEngine: hello pad failed: $e');
    }
    _started = true;
  }

  // ─── Per-frame pipeline ──────────────────────────────────────────

  void _processFrame(Float64List rawFrame) {
    // Step 1: profile — read once (bug #6), master linear (bug #7).
    app.updateProfile(app.couplingMode, app.master);
    final profile = app.currentProfile ?? DspProfile.chamber;

    // Step 2: frame-size guard (bug #13).
    input.setFrameSize(profile.fftWindow);
    if (rawFrame.length != profile.fftWindow) return;

    input.setGainDb(app.inputGainDb);

    // Step 3: HPF 55 Hz + mains notches + soft limit.
    final x = _applyHpf55(rawFrame);
    if (_mains.isNotEmpty) {
      for (int i = 0; i < x.length; i++) {
        var s = x[i];
        for (final n in _mains) {
          s = n.process(s);
        }
        x[i] = s;
      }
    }
    for (int i = 0; i < x.length; i++) {
      x[i] = softClip(x[i]);
    }

    // Step 4: noise gate. Track the room's noise floor (falls fast, rises
    // slowly) and gate at the higher of "floor + 10 dB" and the
    // Sensitivity threshold (-24 dBFS at 0 … -60 dBFS at 1).
    final level = _rms(x);
    if (level < _noiseFloor) {
      _noiseFloor = _noiseFloor * 0.7 + level * 0.3;
    } else {
      _noiseFloor = min(_noiseFloor * 1.002, 0.05);
    }
    final threshDb = -24.0 - 36.0 * app.sensitivity;
    final gate = max(pow(10, threshDb / 20).toDouble(), _noiseFloor * 3.2);
    app.gateRms = gate;

    // Step 5: confidence from previous frame's output level (§8.4).
    final conf = _computeAnalysisConfidence(level, profile);

    // Step 6: analysis.
    final frame = analysis.process(x, profile, conf, gateRms: gate);

    // Step 6: percussion.
    final frameMs = 1000.0 * profile.fftWindow / InputRouter.sampleRate;
    percussion.update(frame, frameMs);

    // Step 7: UI readout.
    app.updateFromAnalysis(frame);

    // Step 8: brain + synth.
    final state = brain.update(frame, app, percussion);
    app.updateFromBrain(state, brain.status, profile);
    synth.apply(
      state,
      profile,
      master: app.master,
      reverb: app.reverb,
      spatial: app.antiphonalIntensity,
      bpm: app.tempoFollow ? (percussion.tempoBpm ?? frame.tempoBpm) : null,
    );

    // Step 9: reference level for the next frame's confidence.
    if (synth.isInitialized) {
      _lastSynthRms = _rms(synth.takeReferenceBlock(rawFrame.length));
    }

    // Step 10: listening chip (§11.4.3).
    final quiet = synth.core.isQuietedForListening;
    if (quiet && !_listeningChipShown) {
      _listeningChipShown = true;
      _showWarningChip("Play something — I'm listening.");
    } else if (!quiet && _listeningChipShown) {
      _listeningChipShown = false;
    }
  }

  double _computeAnalysisConfidence(double micLevel, DspProfile profile) {
    if (_lastSynthRms < 0.05) return profile.analysisConfidenceMultiplier;
    final ratio = micLevel / _lastSynthRms;
    if (ratio > 2.0) return profile.analysisConfidenceMultiplier;
    if (ratio > 0.5) {
      return ((0.5 + ratio * 0.25) * profile.analysisConfidenceMultiplier)
          .clamp(0.0, 1.0);
    }
    return (0.1 * profile.analysisConfidenceMultiplier).clamp(0.0, 1.0);
  }

  Float64List _applyHpf55(Float64List x) {
    final a = exp(-2 * pi * 55 / InputRouter.sampleRate);
    final out = Float64List(x.length);
    double px = _hpPrevX, py = _hpPrevY;
    for (int i = 0; i < x.length; i++) {
      py = a * (py + x[i] - px);
      px = x[i];
      out[i] = py;
    }
    _hpPrevX = px;
    _hpPrevY = py;
    return out;
  }

  static double _rms(Float64List x) {
    if (x.isEmpty) return 0.0;
    double s = 0;
    for (final v in x) {
      s += v * v;
    }
    return sqrt(s / x.length);
  }

  void _showWarningChip(String msg) {
    if (!_warningsCtrl.isClosed) _warningsCtrl.add(msg);
  }

  /// UI: pick an input device (null = system default).
  Future<void> selectInput(InputDeviceInfo? d) async {
    app.setSelectedInputDevice(d?.id);
    if (d != null) app.suggestCouplingModeForDevice(d);
    await input.selectDevice(d?.raw);
  }

  Future<void> dispose() async {
    await _frameSub?.cancel();
    await _humSub?.cancel();
    await _inputErrSub?.cancel();
    await input.dispose();
    await synth.dispose();
    await app.flush();
    if (!_warningsCtrl.isClosed) await _warningsCtrl.close();
  }
}
