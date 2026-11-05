// lib/audio_engine.dart — Phase 1 orchestration.
//
//   mic (InputRouter) → HPF 55 → mains notch → soft limiter
//   → AnalysisPipeline → PercussionAnalyzer → AccompanimentBrain
//   → SynthCore (Dart) → SoLoud stream
//
// Phase 2: echo cancelling (aec.dart) runs in open-air mode, so the mic
// can be used with speakers. AutoTrim and MIDI arrive in Phases 4/5.

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'aec.dart';
import 'analysis.dart';
import 'brain.dart';
import 'dsp.dart';
import 'dsp_profile.dart';
import 'input_router.dart';
import 'models.dart';
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

  // ─── Echo cancelling (Phase 2) ───────────────────────────────────
  EchoCanceller? _aec;
  int _micCount = 0; // mic samples received
  double? _clockOffset; // playedFrames − micCount, smoothed
  static const int _estWindow = 32768; // ~0.74 s
  static const int _maxLag = 22050; // 500 ms
  final Float64List _micHist = Float64List(_estWindow);
  int _micHistPos = 0;
  int _framesSinceEstimate = 0;
  bool get aecActive => _aec?.delaySamples != null;
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

    // Step 3b: echo cancelling (open-air only; Direct = headphones/line).
    final micLevel = _rms(x);
    final cleaned = _cancelEcho(x, profile);

    // Step 4: noise gate. Track the room's noise floor (falls fast, rises
    // slowly) and gate at the higher of "floor + 10 dB" and the
    // Sensitivity threshold (-24 dBFS at 0 … -60 dBFS at 1).
    final level = _rms(cleaned);
    if (level < _noiseFloor) {
      _noiseFloor = _noiseFloor * 0.7 + level * 0.3;
    } else {
      _noiseFloor = min(_noiseFloor * 1.002, 0.05);
    }
    final threshDb = -24.0 - 36.0 * app.sensitivity;
    final gate = max(pow(10, threshDb / 20).toDouble(), _noiseFloor * 3.2);
    app.gateRms = gate;

    // Step 5: confidence from previous frame's output level (§8.4).
    final conf = _computeAnalysisConfidence(level, micLevel, profile);

    // Step 6: analysis.
    final frame = analysis.process(cleaned, profile, conf, gateRms: gate);

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

  Float64List _cancelEcho(Float64List x, DspProfile profile) {
    if (app.couplingMode == CouplingMode.direct ||
        profile.aecTaps <= 0 ||
        !synth.isInitialized) {
      _aec = null;
      return x;
    }
    final mobile = defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final taps = min(profile.aecTaps, mobile ? 512 : 1024);
    if (_aec == null || _aec!.taps != taps) {
      final prevDelay = _aec?.delaySamples;
      _aec = EchoCanceller(taps: taps, stepSize: profile.aecStepSize)
        ..delaySamples = prevDelay;
    }
    final aec = _aec!;
    final n = x.length;

    // Map mic samples onto the output clock.
    _micCount += n;
    final sample = (synth.playedFrames - _micCount).toDouble();
    final prev = _clockOffset;
    _clockOffset = (prev == null || (sample - prev).abs() > 8820)
        ? sample
        : prev + (sample - prev) * 0.02;
    final off = _clockOffset!.round();

    // Keep recent mic audio for delay estimation.
    for (int i = 0; i < n; i++) {
      _micHist[_micHistPos] = x[i];
      _micHistPos = (_micHistPos + 1) % _estWindow;
    }
    if (++_framesSinceEstimate >= 20 && _micCount >= _estWindow) {
      _framesSinceEstimate = 0;
      final mic = Float64List(_estWindow);
      for (int i = 0; i < _estWindow; i++) {
        mic[i] = _micHist[(_micHistPos + i) % _estWindow];
      }
      final ref = synth.core.referenceAt(
          _micCount - _estWindow + off - _maxLag, _estWindow + _maxLag);
      aec.estimateDelay(mic, ref, _maxLag);
    }

    final d = aec.delaySamples;
    if (d == null) return x;
    final from = (_micCount - n) + off - d + aec.preTaps - (aec.taps - 1);
    final ref = synth.core.referenceAt(from, n + aec.taps - 1);
    final out = aec.process(x, ref);
    app.updateAec(aec.erleDb);
    return out;
  }

  double _computeAnalysisConfidence(
      double level, double micLevel, DspProfile profile) {
    // Headphones / line input: the mic can't hear the synth.
    if (app.couplingMode == CouplingMode.direct) {
      return profile.analysisConfidenceMultiplier;
    }
    final aec = _aec;
    if (aec != null && aec.delaySamples != null) {
      // Compare what's left with the echo that's left after cancelling.
      final residualEcho =
          aec.lastEchoRms * pow(10, -aec.erleDb / 20).toDouble();
      if (residualEcho < 1e-4) return profile.analysisConfidenceMultiplier;
      final r = level / residualEcho;
      if (r > 3.0) return profile.analysisConfidenceMultiplier;
      if (r > 1.0) {
        return ((0.4 + (r - 1) * 0.3) * profile.analysisConfidenceMultiplier)
            .clamp(0.0, 1.0);
      }
      return (0.15 * profile.analysisConfidenceMultiplier).clamp(0.0, 1.0);
    }
    // No AEC lock yet: fall back to output-level heuristic (§8.4).
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

  // ─── App lifecycle (Phase 2 fix: unstable when switching apps) ────

  bool _suspended = false;
  Future<void> _lifecycle = Future.value();

  /// App hidden (mobile): release the mic and pause output.
  void suspend() {
    _lifecycle = _lifecycle.then((_) async {
      if (!_started || _suspended) return;
      _suspended = true;
      synth.pause();
      try {
        await input.stop();
      } catch (e) {
        debugPrint('AudioEngine: mic stop failed: $e');
      }
    });
  }

  /// App visible again: resume output and reopen the mic.
  void resume() {
    _lifecycle = _lifecycle.then((_) async {
      if (!_started || !_suspended) return;
      _suspended = false;
      synth.resume();
      try {
        final saved = app.selectedInputDeviceId;
        InputDeviceInfo? dev;
        if (saved != null) {
          for (final d in await input.listDevices()) {
            if (d.id == saved) dev = d;
          }
        }
        if (dev != null) {
          await input.selectDevice(dev.raw);
        } else {
          await input.start();
        }
      } catch (e) {
        debugPrint('AudioEngine: mic restart failed: $e');
        _showWarningChip('Microphone did not restart — reopen the app.');
      }
    });
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
