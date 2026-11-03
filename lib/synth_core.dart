// lib/synth_core.dart — the Dart synthesis engine.
//
// DEVIATION (see DEVIATIONS.md): the spec's synth.dart drove one
// flutter_soloud waveform per voice. In flutter_soloud 5.x a waveform's
// frequency is per *source*, filters are per source, and there is no
// master-output tap, so per-voice pitch, formants and an exact AEC
// reference were not achievable that way. Instead, all voices are
// rendered here in Dart into one stereo float stream which synth.dart
// feeds to SoLoud through a buffer stream. Benefits:
//   * every VoiceSpec field (detune, vibrato, formants, FM, noise Q,
//     pluck) is honoured;
//   * world effects (filters, chorus, delay, reverb, saturation) apply;
//   * the AEC reference is the exact signal sent to the speakers.
//
// This file has no Flutter / SoLoud imports, so it is unit-testable.

import 'dart:math';
import 'dart:typed_data';

import 'dsp.dart';
import 'dsp_profile.dart';
import 'models.dart';
import 'sound_worlds.dart';

// ─── Voice ─────────────────────────────────────────────────────────

class SynthVoice {
  final String layer;
  final VoiceSpec spec;
  final String worldId;
  final bool oneShot;
  final int serial;

  double midi;
  double targetMidi;
  double glidePerSample = 0; // semitones per sample
  double detuneRatio = 1.0;
  double phase = 0;
  double modPhase = 0;
  double vibPhase = 0;

  double env = 0;
  bool releasing = false;
  double attackInc;
  double releaseDec;
  double gain; // current
  double targetGain;
  double pan; // -1..1

  // pluck (Karplus–Strong)
  Float64List? _ks;
  int _ksIdx = 0;
  double _ksPrev = 0;
  double _ksDecay = 0.996;

  // filters
  List<Biquad> formants = const [];
  List<double> formantGains = const [];
  Biquad? toneFilter;
  PinkNoise? pink;
  BrownNoise? brown;
  Random? rng;

  // granular
  double _grainPos = 1.0;
  double _grainInc = 0;
  double _grainWait = 0;

  // lifetime for one-shots (samples)
  int age = 0;
  int maxAge;

  bool dead = false;

  SynthVoice({
    required this.layer,
    required this.spec,
    required this.worldId,
    required this.midi,
    required this.gain,
    required this.pan,
    required this.serial,
    this.oneShot = false,
    double? attackMs,
    double? releaseMs,
    this.maxAge = 1 << 30,
    double detuneCents = 0,
  })  : targetMidi = midi,
        targetGain = gain,
        attackInc = 1.0 / max(1.0, (attackMs ?? spec.attackMs) * kSampleRate / 1000),
        releaseDec = 1.0 / max(1.0, (releaseMs ?? spec.releaseMs) * kSampleRate / 1000) {
    detuneRatio = pow(2, detuneCents / 1200).toDouble();
    rng = Random(serial * 7919 + 13);
    phase = rng!.nextDouble();
    vibPhase = rng!.nextDouble();
    _setupFilters();
    if (spec.source == SourceType.pluck) _strike();
  }

  double get hz => hzFromMidi(midi) * detuneRatio;

  void _setupFilters() {
    switch (spec.source) {
      case SourceType.formant:
        final f = (spec.formants != null && spec.formants!.isNotEmpty)
            ? spec.formants!.first
            : const Formant(700, 1200, 2600);
        double q(double fc) => (fc / max(40.0, f.bwHz)).clamp(2.0, 30.0);
        formants = [
          Biquad.bandpass(f.f1, q(f.f1)),
          Biquad.bandpass(f.f2, q(f.f2)),
          Biquad.bandpass(f.f3, q(f.f3)),
        ];
        formantGains = const [1.0, 0.6, 0.35];
        break;
      case SourceType.brass:
        toneFilter = Biquad.lowpass(hzFromMidi(midi) * 5, 0.9);
        break;
      case SourceType.noise:
        if (spec.noiseColor == NoiseColor.pink || spec.noiseColor == null) {
          pink = PinkNoise(serial + 3);
        } else if (spec.noiseColor == NoiseColor.brown) {
          brown = BrownNoise(serial + 5);
        }
        final q = spec.noiseQ ?? 1.0;
        if (q >= 3.0) {
          toneFilter = Biquad.bandpass(hzFromMidi(midi), q);
        } else {
          toneFilter = Biquad.lowpass(1200, 0.7);
        }
        break;
      default:
        break;
    }
  }

  /// Re-excite a pluck string (also used when a pluck pad changes pitch).
  void _strike() {
    final period = max(2, (kSampleRate / max(20.0, hz)).round());
    final buf = Float64List(period);
    final r = rng ?? Random();
    for (int i = 0; i < period; i++) {
      buf[i] = r.nextDouble() * 2 - 1;
    }
    _ks = buf;
    _ksIdx = 0;
    _ksPrev = 0;
    final relSec = max(0.15, spec.releaseMs / 1000.0);
    _ksDecay = pow(0.001, 1.0 / (relSec * hz)).toDouble().clamp(0.9, 0.99995);
  }

  void retarget(double newMidi, {double glideMs = 120}) {
    if ((newMidi - targetMidi).abs() < 1e-6) return;
    targetMidi = newMidi;
    if (spec.source == SourceType.pluck || oneShot) {
      midi = newMidi;
      _strike();
      return;
    }
    final samples = max(1.0, glideMs * kSampleRate / 1000);
    glidePerSample = (targetMidi - midi).abs() / samples;
    if (spec.source == SourceType.noise && toneFilter != null &&
        (spec.noiseQ ?? 0.0) >= 3.0) {
      toneFilter!.setBandpass(hzFromMidi(newMidi), spec.noiseQ!);
    }
  }

  void release({double? ms}) {
    if (releasing) return;
    releasing = true;
    if (ms != null) {
      releaseDec = 1.0 / max(1.0, ms * kSampleRate / 1000);
    }
  }

  /// Render [n] samples additively into [l]/[r].
  void render(Float64List l, Float64List r, int n) {
    if (dead) return;
    final cl = cos((pan.clamp(-1.0, 1.0) + 1) * pi / 4);
    final cr = sin((pan.clamp(-1.0, 1.0) + 1) * pi / 4);
    final vibRate = spec.vibratoRateHz / kSampleRate;
    final vibDepth = spec.vibratoCents / 1200.0;
    final gainStep = 1.0 / (0.02 * kSampleRate); // 20 ms gain smoothing

    for (int i = 0; i < n; i++) {
      // glide
      if (midi != targetMidi) {
        if ((targetMidi - midi).abs() <= glidePerSample || glidePerSample == 0) {
          midi = targetMidi;
        } else {
          midi += midi < targetMidi ? glidePerSample : -glidePerSample;
        }
      }
      // envelope
      if (releasing) {
        env -= releaseDec;
        if (env <= 0) {
          env = 0;
          dead = true;
          return;
        }
      } else if (env < 1) {
        env = min(1.0, env + attackInc);
      }
      // gain smoothing
      if (gain != targetGain) {
        final d = targetGain - gain;
        gain += d.abs() < gainStep ? d : (d > 0 ? gainStep : -gainStep);
      }

      double f = hzFromMidiFast(midi) * detuneRatio;
      if (vibDepth > 0) {
        vibPhase += vibRate;
        if (vibPhase >= 1) vibPhase -= 1;
        f *= 1 + vibDepth * 0.6931 * sin(2 * pi * vibPhase);
      }
      final dt = f / kSampleRate;

      final s = _osc(dt) * env * gain;
      l[i] += s * cl;
      r[i] += s * cr;
    }
    age += n;
    if (age >= maxAge) release();
  }

  double _osc(double dt) {
    double out;
    switch (spec.source) {
      case SourceType.sine:
        out = sin(2 * pi * phase);
        break;
      case SourceType.tri:
        out = 4 * (phase < 0.5 ? phase : 1 - phase) - 1;
        break;
      case SourceType.saw:
        out = (2 * phase - 1) - polyBlep(phase, dt);
        break;
      case SourceType.square:
        out = (phase < 0.5 ? 1.0 : -1.0) +
            polyBlep(phase, dt) -
            polyBlep((phase + 0.5) % 1.0, dt);
        break;
      case SourceType.formant:
        final saw = (2 * phase - 1) - polyBlep(phase, dt);
        out = 0;
        for (int k = 0; k < formants.length; k++) {
          out += formants[k].process(saw) * formantGains[k];
        }
        out *= 2.2;
        break;
      case SourceType.brass:
        final saw = (2 * phase - 1) - polyBlep(phase, dt);
        out = toneFilter!.process(saw) * 0.9;
        break;
      case SourceType.fm:
        final ratio = spec.fmRatio ?? 2.0;
        final index = spec.fmIndex ?? 2.0;
        modPhase += dt * ratio;
        if (modPhase >= 1) modPhase -= modPhase.floorToDouble();
        // index decays with the envelope: bell-like brightness fall-off
        out = sin(2 * pi * phase + index * env * sin(2 * pi * modPhase));
        break;
      case SourceType.granular:
        // short FM grains with random spacing
        if (_grainPos >= 1.0) {
          if (_grainWait > 0) {
            _grainWait -= 1;
            out = 0;
            break;
          }
          _grainPos = 0;
          final grainSamples = max(64.0, (spec.grainMs ?? 30.0) * kSampleRate / 1000);
          _grainInc = 1.0 / grainSamples;
          final density = max(1.0, spec.grainDensity ?? 20.0);
          final meanGap = max(0.0, kSampleRate / density - grainSamples);
          _grainWait = meanGap * (0.5 + rng!.nextDouble());
          // ±50 cent drift per grain
          detuneRatio = pow(2, (rng!.nextDouble() - 0.5) / 12).toDouble();
        }
        final w = sin(pi * _grainPos);
        _grainPos += _grainInc;
        modPhase += dt * (spec.fmRatio ?? 3.7);
        if (modPhase >= 1) modPhase -= modPhase.floorToDouble();
        out = w * w *
            sin(2 * pi * phase + (spec.fmIndex ?? 2.0) * sin(2 * pi * modPhase));
        break;
      case SourceType.noise:
        final double raw;
        if (pink != null) {
          raw = pink!.next();
        } else if (brown != null) {
          raw = brown!.next();
        } else {
          raw = rng!.nextDouble() * 2 - 1;
        }
        final q = spec.noiseQ ?? 1.0;
        out = toneFilter!.process(raw) * (q >= 3.0 ? sqrt(q) * 1.4 : 1.0);
        break;
      case SourceType.pluck:
        final ks = _ks!;
        final cur = ks[_ksIdx];
        final next = (cur + _ksPrev) * 0.5 * _ksDecay;
        _ksPrev = cur;
        ks[_ksIdx] = next;
        _ksIdx++;
        if (_ksIdx >= ks.length) _ksIdx = 0;
        out = cur;
        break;
    }
    phase += dt;
    if (phase >= 1) phase -= phase.floorToDouble();
    return out;
  }
}

/// Faster MIDI→Hz (exp instead of pow).
@pragma('vm:prefer-inline')
double hzFromMidiFast(double midi) => 440.0 * exp((midi - 69) * 0.05776226504666211);

// ─── Effects chain per world ──────────────────────────────────────

class _FxChain {
  final List<Biquad> _filtersL = [], _filtersR = [];
  double drive = 0;
  Chorus? chorus;
  Delay? delay;
  Reverb? reverb;
  double baseWet = 0.3;

  _FxChain(SoundWorld w) {
    for (final e in w.effects) {
      final p = e.params;
      switch (e.type) {
        case EffectType.lowpass:
          // Global chain (spec effects have no target layer). Very low
          // cutoffs intended for the drone alone would gut the pad, so
          // global lowpasses are floored at 1.2 kHz. See DEVIATIONS.md.
          final fc = max(1200.0, p['cutoffHz'] ?? 4000.0);
          final q = (p['resonance'] ?? 0.7).clamp(0.5, 2.0);
          _filtersL.add(Biquad.lowpass(fc, q));
          _filtersR.add(Biquad.lowpass(fc, q));
          break;
        case EffectType.highpass:
          final fc = p['cutoffHz'] ?? 40.0;
          final q = (p['resonance'] ?? 0.7).clamp(0.5, 2.0);
          _filtersL.add(Biquad.highpass(fc, q));
          _filtersR.add(Biquad.highpass(fc, q));
          break;
        case EffectType.highShelf:
          final fc = p['freqHz'] ?? p['frequency'] ?? 6000.0;
          final g = p['gainDb'] ?? p['gain'] ?? 0.0;
          _filtersL.add(Biquad.highShelf(fc, g));
          _filtersR.add(Biquad.highShelf(fc, g));
          break;
        case EffectType.saturation:
          drive = p['drive'] ?? 1.5;
          break;
        case EffectType.chorus:
          chorus = Chorus()
            ..rateHz = p['rateHz'] ?? 0.4
            ..depthMs = p['depthMs'] ?? 6.0;
          break;
        case EffectType.phaser:
          // Approximated by a slow, deep chorus.
          chorus ??= Chorus()
            ..rateHz = p['rateHz'] ?? 0.1
            ..depthMs = 3
            ..mix = 0.25;
          break;
        case EffectType.delay:
          delay = Delay()
            ..timeMs = p['timeMs'] ?? 400.0
            ..feedback = (p['feedback'] ?? 0.3).clamp(0.0, 0.85)
            ..wet = p['wet'] ?? 0.2;
          break;
        case EffectType.reverb:
          reverb = Reverb()
            ..room = p['room'] ?? 0.7
            ..damp = p['damp'] ?? 0.3
            ..wet = p['wet'] ?? 0.3;
          baseWet = p['wet'] ?? 0.3;
          break;
      }
    }
  }

  void process(Float64List l, Float64List r, int n, double reverbScale) {
    for (int f = 0; f < _filtersL.length; f++) {
      final fl = _filtersL[f], fr = _filtersR[f];
      for (int i = 0; i < n; i++) {
        l[i] = fl.process(l[i]);
        r[i] = fr.process(r[i]);
      }
    }
    if (drive > 0) {
      final norm = 1.0 / softClip(drive);
      for (int i = 0; i < n; i++) {
        l[i] = softClip(l[i] * drive) * norm;
        r[i] = softClip(r[i] * drive) * norm;
      }
    }
    chorus?.process(l, r, n);
    delay?.process(l, r, n);
    final rv = reverb;
    if (rv != null) {
      rv.wet = (baseWet * reverbScale).clamp(0.0, 0.95);
      rv.process(l, r, n);
    }
  }
}

// ─── SynthCore ────────────────────────────────────────────────────

class SynthCore {
  final List<SynthVoice> _voices = [];
  int _serial = 0;
  final Random _rng = Random(99);

  String? _worldId;
  SoundWorld? _world;
  _FxChain? _fx;
  _FxChain? _fxOld; // during world crossfade
  int _fxOldSamplesLeft = 0;

  // Latest musical state + controls.
  MusicalState? _state;
  DspProfile _profile = DspProfile.chamber;
  double _master = 0.35;
  double _reverbScale = 1.0;
  double _spatial = 0.7;
  double _masterTrim = 1.0;

  // Rhythm clock
  double _bpm = 90;
  double _beatPos = 0; // beats since clock start, continuous
  List<RhythmHit> _rhythm = const [];
  int _pingPong = 0;

  // Harmony queue: (fireAtSample, event)
  final List<(int, HarmonyEvent)> _harmonyQueue = [];

  // Listening quiet-down (§11.4)
  int _silentSamples = 0;
  double _idleGain = 1.0;

  // Output clock + reference ring (mono, 2 s)
  int _rendered = 0;
  final Float64List _refRing = Float64List(1 << 17);
  static const int _refMask = (1 << 17) - 1;

  // Scratch
  Float64List _l = Float64List(512), _r = Float64List(512);
  Float64List _ol = Float64List(512), _or = Float64List(512);

  final List<NoteEvent> _pendingEvents = [];

  int get renderedFrames => _rendered;
  int get activeVoiceCount => _voices.where((v) => !v.dead).length;
  String? get worldId => _worldId;

  /// Note events produced since the last call (for MIDI / UI).
  List<NoteEvent> drainNoteEvents() {
    final out = List<NoteEvent>.from(_pendingEvents);
    _pendingEvents.clear();
    return out;
  }

  void setMasterTrim(double linear) => _masterTrim = linear.clamp(0.0, 1.0);

  // ─── Control from the engine ────────────────────────────────────

  void apply(
    MusicalState state,
    DspProfile profile, {
    required double master,
    required double reverb,
    required double spatial,
    double? bpm,
  }) {
    _state = state;
    _profile = profile;
    _master = master;
    _reverbScale = (reverb / 0.45).clamp(0.0, 2.0);
    _spatial = spatial;
    if (bpm != null && bpm >= 40 && bpm <= 200) _bpm = bpm;

    if (_worldId != state.worldId) _switchWorld(state.worldId);
    _updateSustainedVoices(state);
    _rhythm = state.rhythmSchedule;
    _queueHarmony(state);
    _enforceCeiling();
  }

  void playHelloPad() {
    const notes = [48, 55, 60, 64];
    const spec = VoiceSpec(
      layer: 'hello',
      count: 1,
      source: SourceType.tri,
      rangeMidi: [36, 84],
      attackMs: 800,
      releaseMs: 1500,
    );
    for (int i = 0; i < notes.length; i++) {
      _voices.add(SynthVoice(
        layer: 'hello',
        spec: spec,
        worldId: '_hello',
        midi: notes[i].toDouble(),
        gain: 0.12,
        pan: (i - 1.5) * 0.25,
        serial: _serial++,
        oneShot: false,
        maxAge: (3.0 * kSampleRate).round(),
      ));
      _event(NoteEventType.on, 'hello', notes[i], 0.12);
    }
  }

  // ─── World management ───────────────────────────────────────────

  void _switchWorld(String id) {
    final w = worldById(id);
    // Release everything from the previous world over 1.5 s while the new
    // world's voices fade in (§11.5 crossfade; bug #26 handled by the
    // doubled ceiling while _fxOld is alive).
    for (final v in _voices) {
      if (v.worldId != '_hello') v.release(ms: 1500);
    }
    if (_fx != null) {
      _fxOld = _fx;
      // Old voices keep rendering through _fxOld until faded (see render).
      _fxOldSamplesLeft = (2.0 * kSampleRate).round();
    }
    _world = w;
    _worldId = id;
    _fx = _FxChain(w);
  }

  Iterable<SynthVoice> _live(String layer) => _voices.where(
      (v) => !v.dead && !v.releasing && v.layer == layer && v.worldId == _worldId);

  void _updateSustainedVoices(MusicalState s) {
    final w = _world!;
    final silenceFactor = _idleGain;

    // ─── Drone ─────────────────────────────────────────
    final droneGain = (s.intensity['drone'] ?? 0.0) * 0.30 * silenceFactor;
    final droneSpecs = w.voices.where((v) => v.layer == 'drone').toList();
    final drones = _live('drone').toList();
    int di = 0;
    for (final spec in droneSpecs) {
      for (int i = 0; i < spec.count; i++) {
        final target = _droneMidi(spec, s.droneRootPc, i);
        final g = droneGain / sqrt(_droneCount(w).toDouble());
        if (di < drones.length) {
          drones[di].retarget(target, glideMs: 400);
          drones[di].targetGain = g;
        } else {
          _spawn(spec, 'drone', target, g, _detuneFor(spec, i, spec.count),
              pan: 0);
        }
        di++;
      }
    }

    // ─── Pad ───────────────────────────────────────────
    final padSpecs = w.voices.where((v) => v.layer == 'pad').toList();
    final nPad = padSpecs.fold<int>(0, (a, v) => a + v.count);
    final padGain =
        (s.intensity['chords'] ?? 0.0) * 0.32 * silenceFactor / sqrt(max(1, nPad));
    final pads = _live('pad').toList();
    final source = s.padMidi.isNotEmpty
        ? s.padMidi
        : s.padPcs.map((pc) => 60 + pc).toList();
    if (source.isNotEmpty) {
      int pi_ = 0;
      for (final spec in padSpecs) {
        for (int i = 0; i < spec.count; i++) {
          final want = source[pi_ % source.length] +
              (pi_ >= source.length ? 12 : 0);
          final target = _fitRange(want.toDouble(), spec.rangeMidi,
              prev: pi_ < pads.length ? pads[pi_].targetMidi : null);
          final pan = nPad <= 1
              ? 0.0
              : ((pi_ / (nPad - 1)) * 2 - 1) * 0.5 * _spatial;
          if (pi_ < pads.length) {
            final v = pads[pi_];
            if ((v.targetMidi - target).abs() > 1e-6) {
              _event(NoteEventType.off, 'chords', v.targetMidi.round(), 0);
              _event(NoteEventType.on, 'chords', target.round(), padGain);
            }
            v.retarget(target, glideMs: 140);
            v.targetGain = padGain;
            v.pan = pan;
          } else {
            _spawn(spec, 'pad', target, padGain, _detuneFor(spec, i, spec.count),
                pan: pan);
            _event(NoteEventType.on, 'chords', target.round(), padGain);
          }
          pi_++;
        }
      }
    }

    // ─── Texture ───────────────────────────────────────
    final texSpecs = w.voices.where((v) => v.layer == 'texture').toList();
    final texGain = (s.intensity['sounds'] ?? 0.0) * 0.35 * silenceFactor;
    final texs = _live('texture').toList();
    int ti = 0;
    for (final spec in texSpecs) {
      for (int i = 0; i < spec.count; i++) {
        final pitched = (spec.noiseQ ?? 0.0) >= 3.0 && source.isNotEmpty;
        final target = pitched
            ? _fitRange(source[ti % source.length].toDouble(), spec.rangeMidi)
            : ((spec.rangeMidi[0] + spec.rangeMidi[1]) / 2).toDouble();
        final g = texGain / sqrt(max(1, spec.count).toDouble());
        final pan = spec.count <= 1 ? 0.0 : ((i / (spec.count - 1)) * 2 - 1) * 0.7 * _spatial;
        if (ti < texs.length) {
          texs[ti].retarget(target, glideMs: 600);
          texs[ti].targetGain = g;
        } else {
          _spawn(spec, 'texture', target, g, _detuneFor(spec, i, spec.count),
              pan: pan);
        }
        ti++;
      }
    }
  }

  int _droneCount(SoundWorld w) => max(
      1,
      w.voices
          .where((v) => v.layer == 'drone')
          .fold<int>(0, (a, v) => a + v.count));

  double _droneMidi(VoiceSpec spec, int rootPc, int index) {
    final lo = spec.rangeMidi[0], hi = spec.rangeMidi[1];
    final pcs = <int>[for (int m = lo; m <= hi; m++) if (m % 12 == rootPc) m];
    if (pcs.isEmpty) {
      // range too narrow for this pc: nearest note with that pc below hi
      int m = hi;
      while (m % 12 != rootPc) {
        m--;
      }
      return m.toDouble();
    }
    return pcs[index % pcs.length].toDouble();
  }

  double _detuneFor(VoiceSpec spec, int i, int count) {
    if (spec.detuneCents == 0 || count <= 1) return 0;
    final t = (i / (count - 1)) * 2 - 1; // -1..1
    return t * spec.detuneCents;
  }

  /// Move [midi] by octaves into [range]; if [prev] is given choose the
  /// octave closest to it (voice-leading).
  double _fitRange(double midi, List<int> range, {double? prev}) {
    final lo = range[0].toDouble(), hi = range[1].toDouble();
    final candidates = <double>[];
    for (double m = midi - 48; m <= midi + 48; m += 12) {
      if (m >= lo && m <= hi) candidates.add(m);
    }
    if (candidates.isEmpty) {
      var m = midi;
      while (m < lo) {
        m += 12;
      }
      while (m > hi) {
        m -= 12;
      }
      return m;
    }
    final ref = prev ?? midi;
    candidates.sort((a, b) => (a - ref).abs().compareTo((b - ref).abs()));
    return candidates.first;
  }

  SynthVoice _spawn(VoiceSpec spec, String layer, double midi, double gain,
      double detuneCents,
      {double pan = 0, bool oneShot = false, int? maxAgeSamples}) {
    final v = SynthVoice(
      layer: layer,
      spec: spec,
      worldId: _worldId ?? '',
      midi: midi,
      gain: gain,
      pan: pan,
      serial: _serial++,
      oneShot: oneShot,
      detuneCents: detuneCents,
      maxAge: maxAgeSamples ?? (1 << 30),
    );
    _voices.add(v);
    return v;
  }

  // ─── Rhythm ──────────────────────────────────────────────────────

  static const _pluckSpec = VoiceSpec(
      layer: 'rhythm', count: 1, source: SourceType.pluck,
      rangeMidi: [48, 84], attackMs: 2, releaseMs: 500);
  static const _clickSpec = VoiceSpec(
      layer: 'rhythm', count: 1, source: SourceType.noise,
      rangeMidi: [79, 79], attackMs: 1, releaseMs: 40,
      noiseColor: NoiseColor.white, noiseQ: 6);
  static const _kickSpec = VoiceSpec(
      layer: 'rhythm', count: 1, source: SourceType.sine,
      rangeMidi: [28, 28], attackMs: 2, releaseMs: 180);
  static const _slapSpec = VoiceSpec(
      layer: 'rhythm', count: 1, source: SourceType.noise,
      rangeMidi: [90, 90], attackMs: 1, releaseMs: 110,
      noiseColor: NoiseColor.white, noiseQ: 3);
  static const _brassStabSpec = VoiceSpec(
      layer: 'rhythm', count: 1, source: SourceType.brass,
      rangeMidi: [48, 72], attackMs: 30, releaseMs: 220);

  void _fireRhythm(RhythmHit hit) {
    final w = _world;
    if (w == null || w.rhythm.type == RhythmType.none) return;
    final vel = (hit.velocity * _idleGain).clamp(0.0, 1.0);
    if (vel < 0.01) return;
    final side = _pingPong.isEven ? -1 : 1;
    _pingPong++;
    final pan = side * 0.6 * _spatial;
    final note = 60 + hit.pitchPc;
    switch (w.rhythm.type) {
      case RhythmType.pluck:
        _spawn(_pluckSpec, 'rhythm', note.toDouble(), vel * 0.5, 0,
            pan: pan, oneShot: true, maxAgeSamples: (0.5 * kSampleRate).round());
        break;
      case RhythmType.woodblock:
        _spawn(_clickSpec, 'rhythm', 79, vel * 0.6, 0,
            pan: pan, oneShot: true, maxAgeSamples: (0.04 * kSampleRate).round());
        break;
      case RhythmType.cajon:
        // Velocity → kit piece (§11.3 notes): >0.7 kick+slap, >0.35 slap,
        // otherwise a palmas triple-burst.
        final strength = hit.velocity.clamp(0.0, 1.0);
        if (strength > 0.35) {
          if (strength > 0.7) {
            _spawn(_kickSpec, 'rhythm', 28, vel * 0.9, 0,
                oneShot: true, maxAgeSamples: (0.18 * kSampleRate).round());
          }
          _spawn(_slapSpec, 'rhythm', 90, vel * 0.5, 0,
              pan: pan, oneShot: true,
              maxAgeSamples: (0.11 * kSampleRate).round());
        } else {
          for (final ms in const [0, 12, 25]) {
            _harmonyQueue.add((
              _rendered + (ms * kSampleRate / 1000).round(),
              HarmonyEvent(pitchMidi: -1, velocity: vel * 0.6),
            ));
          }
        }
        break;
      case RhythmType.palmas:
        for (final ms in const [0, 12, 25]) {
          _harmonyQueue.add((
            _rendered + (ms * kSampleRate / 1000).round(),
            HarmonyEvent(pitchMidi: -1, velocity: vel * 0.4),
          ));
        }
        break;
      case RhythmType.brass:
        _spawn(_brassStabSpec, 'rhythm', (48 + hit.pitchPc).toDouble(),
            vel * 0.35, 0,
            pan: pan, oneShot: true, maxAgeSamples: (0.3 * kSampleRate).round());
        break;
      case RhythmType.none:
        break;
    }
    _event(NoteEventType.on, 'rhythm', note, vel);
  }

  void _advanceRhythm(int n) {
    final beatsPerSample = _bpm / 60.0 / kSampleRate;
    final start = _beatPos;
    final end = start + beatsPerSample * n;
    if (_rhythm.isNotEmpty) {
      // Bar of 4 beats; fire hits whose position falls in (start, end].
      final barStart = (start / 4).floor() * 4.0;
      for (double bar = barStart; bar < end; bar += 4) {
        for (final h in _rhythm) {
          final t = bar + h.timeInBeats;
          if (t > start && t <= end) _fireRhythm(h);
        }
      }
    }
    _beatPos = end;
  }

  // ─── Harmony (harmonizer world) ─────────────────────────────────

  void _queueHarmony(MusicalState s) {
    for (final ev in s.harmonySchedule) {
      _harmonyQueue.add((
        _rendered + (ev.delay.inMicroseconds * kSampleRate / 1e6).round(),
        ev,
      ));
    }
  }

  void _fireQueued(int blockEnd) {
    if (_harmonyQueue.isEmpty) return;
    final due = _harmonyQueue.where((e) => e.$1 <= blockEnd).toList();
    _harmonyQueue.removeWhere((e) => e.$1 <= blockEnd);
    final w = _world;
    for (final (_, ev) in due) {
      if (ev.pitchMidi < 0) {
        // palmas clap
        _spawn(_slapSpec, 'rhythm', 92, ev.velocity, 0,
            pan: (_rng.nextDouble() - 0.5) * _spatial,
            oneShot: true, maxAgeSamples: (0.05 * kSampleRate).round());
        continue;
      }
      VoiceSpec spec = _pluckSpec;
      if (w != null) {
        for (final v in w.voices) {
          if (v.layer == 'harmony') {
            spec = v;
            break;
          }
        }
      }
      _spawn(spec, 'harmony', ev.pitchMidi.toDouble(),
          ev.velocity * 0.45 * _idleGain, 0,
          pan: -0.5 * _spatial,
          oneShot: true,
          maxAgeSamples: (0.4 * kSampleRate).round());
      _event(NoteEventType.on, 'harmony', ev.pitchMidi, ev.velocity);
    }
  }

  void _enforceCeiling() {
    final ceiling = _fxOld != null ? _profile.voiceCeiling * 2 : _profile.voiceCeiling;
    final live = _voices.where((v) => !v.dead && !v.releasing).toList();
    final sustained = live.where((v) => !v.oneShot).length;
    var over = live.length - max(ceiling, sustained);
    if (over <= 0) return;
    for (final v in live) {
      if (over <= 0) break;
      if (v.oneShot) {
        v.release(ms: 30);
        over--;
      }
    }
  }

  void _event(NoteEventType t, String layer, int midi, double vel) {
    _pendingEvents.add(NoteEvent(
      type: t,
      layerId: layer,
      midiNote: midi.clamp(0, 127),
      velocity: vel,
      timestamp: DateTime.now(),
      channel: 1,
    ));
    if (_pendingEvents.length > 512) _pendingEvents.removeAt(0);
  }

  // ─── Rendering ───────────────────────────────────────────────────

  /// Render [n] stereo frames into interleaved float32 [out]
  /// (length >= 2n). Also records the mono reference.
  void render(Float32List out, int n) {
    if (_l.length < n) {
      _l = Float64List(n);
      _r = Float64List(n);
      _ol = Float64List(n);
      _or = Float64List(n);
    }
    final l = _l, r = _r, ol = _ol, or = _or;
    for (int i = 0; i < n; i++) {
      l[i] = 0;
      r[i] = 0;
      ol[i] = 0;
      or[i] = 0;
    }

    _updateIdle(n);
    _advanceRhythm(n);
    _fireQueued(_rendered + n);

    final oldWorld = _fxOld != null;
    for (final v in _voices) {
      if (oldWorld && v.worldId != _worldId && v.worldId != '_hello') {
        v.render(ol, or, n);
      } else {
        v.render(l, r, n);
      }
    }
    _voices.removeWhere((v) => v.dead);

    _fx?.process(l, r, n, _reverbScale);
    if (oldWorld) {
      _fxOld!.process(ol, or, n, _reverbScale);
      for (int i = 0; i < n; i++) {
        l[i] += ol[i];
        r[i] += or[i];
      }
      _fxOldSamplesLeft -= n;
      if (_fxOldSamplesLeft <= 0) _fxOld = null;
    }

    // Master: perceptual-ish curve, then soft limiter.
    final g = (_master * _master * 2.2 + _master * 0.4) * _masterTrim;
    for (int i = 0; i < n; i++) {
      final yl = softClip(l[i] * g);
      final yr = softClip(r[i] * g);
      out[2 * i] = yl;
      out[2 * i + 1] = yr;
      _refRing[(_rendered + i) & _refMask] = (yl + yr) * 0.5;
    }
    _rendered += n;
  }

  void _updateIdle(int n) {
    final s = _state;
    if (s == null) return;
    if (s.silent) {
      _silentSamples += n;
    } else {
      _silentSamples = 0;
    }
    final secs = _silentSamples / kSampleRate;
    // §11.4: after 8 s of silence quieten (~-10 dB); after 60 s fade out.
    final target = secs > 60 ? 0.0 : (secs > 8 ? 0.3 : 1.0);
    final step = n / (1.5 * kSampleRate);
    if (_idleGain < target) {
      _idleGain = min(target, _idleGain + step);
    } else if (_idleGain > target) {
      _idleGain = max(target, _idleGain - step / 2);
    }
  }

  bool get isQuietedForListening => _silentSamples / kSampleRate > 8;

  /// Mono reference samples [from, from+n) in output-sample index space.
  Float64List referenceAt(int from, int n) {
    final out = Float64List(n);
    for (int i = 0; i < n; i++) {
      final idx = from + i;
      if (idx < 0 || idx >= _rendered || _rendered - idx > _refRing.length) {
        continue;
      }
      out[i] = _refRing[idx & _refMask];
    }
    return out;
  }
}
