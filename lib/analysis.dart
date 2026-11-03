// lib/analysis.dart — §7 (fixed: fftea complex output, key-mask bias)
import 'dart:math';
import 'dart:typed_data';
import 'package:fftea/fftea.dart';
import 'models.dart';
import 'dsp_profile.dart';

class _Peak {
  final double freq;
  final double mag;
  const _Peak(this.freq, this.mag);
}

class AnalysisPipeline {
  // ─── FFT state (rebuilt on tier change) ─────────────────────────────
  int _fftSize = 0;
  FFT? _fft;
  Float64List _hann = Float64List(0);
  Float64List _scratchWindowed = Float64List(0);
  Float64List _scratchMagnitudes = Float64List(0);
  List<double> _prevMagnitudes = <double>[];
  Float64List _binVariance = Float64List(0);
  Float64List _prevBinMag = Float64List(0);

  // DC block state
  double _dcPrevX = 0, _dcPrevY = 0;

  // Histories (reset on tier change)
  final List<double> _onsetHistory = <double>[];
  final List<double> _hfcHistory = <double>[];
  final List<double> _lowFluxHistory = <double>[];

  // Tempo
  final List<double> _onsetEnv = <double>[];
  DateTime? _lastTempoRun;
  double? _bpmSmoothed;

  // Polyphonic scratch
  final List<_Peak> _peakBuffer = <_Peak>[];
  final Float64List _pcEnergy = Float64List(12);

  // Silence
  DateTime? _lastSignalTime;

  // YIN scratch
  final Float64List _yinDiff = Float64List(2048);
  final Float64List _yinCmnd = Float64List(2048);
  double _pitchConfidence = 0;
  double? _lastPitchHz;

  /// Last confident pitch (Hz) or null.
  double? get lastPitchHz => _lastPitchHz;

  // Frame counter
  int _frameCount = 0;

  // Key candidates cache
  List<(int, Scale, double)> _lastKeyCandidates = const [];

  // Reusable chroma buffer (returned copy to caller each frame)
  final Float64List _chromaBuf = Float64List(12);

  static const double _sr = 44100.0;

  /// Magnitude spectrum of the most recent frame (length fftWindow/2).
  /// Read by the feedback suppressor. Do not mutate.
  Float64List get lastMagnitudes => _scratchMagnitudes;

  // ─── PUBLIC API ─────────────────────────────────────────────────────

  AnalysisFrame process(
    Float64List samples,
    DspProfile profile,
    double analysisConfidence,
  ) {
    // STAGE 0 — Resize if tier changed
    if (profile.fftWindow != _fftSize) {
      _resize(profile.fftWindow);
    }
    _frameCount++;

    final n = _fftSize;
    final half = n ~/ 2;
    final frameMs = 1000.0 * n / _sr;

    // STAGE 1 — DC block + periodic Hann
    _applyDcBlockAndHann(samples, n);

    // STAGE 2 — FFT + magnitude
    _computeMagnitudes(n, half);

    // STAGE 3 — Chroma (writes to _chromaBuf)
    final chroma = _computeChroma(n, half);

    // STAGE 4 — Onsets (three signals)
    final onsetResult = _computeOnsets(half, frameMs);
    final double percussiveOnset = onsetResult.percussiveOnset;
    final double percussiveConfidence = onsetResult.percussiveConfidence;
    final double lowBandFlux = onsetResult.lowBandFlux;

    // STAGE 5 — YIN pitch
    final pitchHz = _yin(samples);

    // STAGE 6 — Tempo
    _updateTempo(percussiveOnset, frameMs);

    // STAGE 7 — Key detection (every 8th frame)
    if (_frameCount % 8 == 0 || _lastKeyCandidates.isEmpty) {
      _lastKeyCandidates = _detectKeys(chroma);
    }

    // STAGE 8 — Polyphonic (tier-gated)
    final detectedNotes = profile.polyphonicPitch
        ? _detectPolyphonic(half)
        : const <DetectedNote>[];

    // STAGE 9 — Silence + RMS
    final rms = _computeRms(samples);
    final silent = _updateSilence(rms);

    // STAGE 10 — Assemble
    return AnalysisFrame(
      chroma: chroma,
      pitchHz: _pitchConfidence > 0.6 ? pitchHz : null,
      pitchConfidence: _pitchConfidence,
      onsetStrength: percussiveOnset,
      percussiveOnset: percussiveOnset,
      percussiveConfidence: percussiveConfidence,
      lowBandFlux: lowBandFlux,
      tempoBpm: _bpmSmoothed,
      keyCandidates: _lastKeyCandidates,
      rmsLevel: rms,
      silent: silent,
      detectedNotes: detectedNotes,
      rhythmPattern: const <double>[],
      beatLocked: false,
      beatPhase01: null,
      analysisConfidence: analysisConfidence,
      timestamp: DateTime.now(),
    );
  }

  // ─── STAGE 1 — DC block + Hann ──────────────────────────────────────

  void _applyDcBlockAndHann(Float64List samples, int n) {
    final w = _scratchWindowed;
    double prevX = _dcPrevX;
    double prevY = _dcPrevY;
    for (int i = 0; i < n; i++) {
      final x = samples[i];
      final y = x - prevX + 0.995 * prevY;
      w[i] = y * _hann[i];
      prevX = x;
      prevY = y;
    }
    _dcPrevX = prevX;
    _dcPrevY = prevY;
  }

  // ─── STAGE 2 — FFT + magnitude ──────────────────────────────────────

  void _computeMagnitudes(int n, int half) {
    // fftea returns Float64x2List of complex bins (x = re, y = im).
    final spectrum = _fft!.realFft(_scratchWindowed);
    final mags = _scratchMagnitudes;
    for (int k = 0; k < half; k++) {
      final c = spectrum[k];
      mags[k] = sqrt(c.x * c.x + c.y * c.y);
    }
  }

  // ─── STAGE 3 — Chroma ───────────────────────────────────────────────

  List<double> _computeChroma(int n, int half) {
    final mags = _scratchMagnitudes;
    final c = _chromaBuf;
    c.fillRange(0, 12, 0.0);
    for (int k = 1; k < half; k++) {
      final f = k * _sr / n;
      if (f < 60.0 || f > 5000.0) continue;
      final midi = 69.0 + 12.0 * (log(f / 440.0) / ln2);
      final pc = ((midi.round() % 12) + 12) % 12;
      c[pc] += mags[k] / sqrt(k.toDouble());
    }
    // L2 normalize
    double sumSq = 0;
    for (int i = 0; i < 12; i++) sumSq += c[i] * c[i];
    final norm = sqrt(sumSq);
    if (norm > 1e-6) {
      for (int i = 0; i < 12; i++) c[i] /= norm;
    }
    // Return a fresh List<double> (12 elements — cheap)
    return List<double>.generate(12, (i) => c[i], growable: false);
  }

  // ─── STAGE 4 — Onsets ───────────────────────────────────────────────

  _OnsetResult _computeOnsets(int half, double frameMs) {
    final mags = _scratchMagnitudes;
    final prevMags = _prevMagnitudes;
    final binVar = _binVariance;
    final prevBinMag = _prevBinMag;
    final n = _fftSize;

    double harmonicFlux = 0, hfc = 0, lowFlux = 0;
    for (int k = 1; k < half; k++) {
      final mag = mags[k];
      final prev = prevMags[k];
      final d = mag - prev;
      if (d > 0) {
        final f = k * _sr / n;
        final delta = mag - prevBinMag[k];
        binVar[k] = binVar[k] * 0.9 + delta * delta * 0.1;
        if (binVar[k] < 0.01) harmonicFlux += d;
        if (f > 200.0) hfc += k * mag;
        if (f >= 20.0 && f <= 200.0) lowFlux += d;
      }
      prevBinMag[k] = mag;
      prevMags[k] = mag;
    }

    // Z-score against rolling 4s baselines
    final histSize = max(8, (4000.0 / frameMs).round());
    _appendAndTrim(_hfcHistory, hfc, histSize);
    _appendAndTrim(_lowFluxHistory, lowFlux, histSize);

    final hfcZ = _zScore(_hfcHistory, hfc);
    final lowZ = _zScore(_lowFluxHistory, lowFlux);

    final percussiveOnset = max(0.0, hfcZ - 1.0) + 0.7 * max(0.0, lowZ - 1.0);
    final percussiveConfidence =
        percussiveOnset / (percussiveOnset + harmonicFlux.abs() + 1e-6);

    return _OnsetResult(
      percussiveOnset: percussiveOnset,
      percussiveConfidence: percussiveConfidence,
      lowBandFlux: lowZ,
    );
  }

  // ─── STAGE 5 — YIN pitch ────────────────────────────────────────────

  double? _yin(Float64List x,
      {double threshold = 0.15, int minLag = 20, int maxLag = 900}) {
    final n = min(x.length, 2048);
    final maxTau = min(maxLag, n ~/ 2);
    final d = _yinDiff;
    for (int tau = 1; tau <= maxTau; tau++) {
      double sum = 0;
      for (int j = 0; j < n - tau; j++) {
        final diff = x[j] - x[j + tau];
        sum += diff * diff;
      }
      d[tau] = sum;
    }
    final cmnd = _yinCmnd;
    double running = 0;
    _pitchConfidence = 0;
    for (int tau = 1; tau <= maxTau; tau++) {
      running += d[tau];
      cmnd[tau] = running == 0 ? 1.0 : d[tau] * tau / running;
    }
    for (int tau = minLag; tau <= maxTau; tau++) {
      if (cmnd[tau] < threshold) {
        int bestTau = tau;
        while (bestTau + 1 <= maxTau && cmnd[bestTau + 1] < cmnd[bestTau]) {
          bestTau++;
        }
        final f0 = _sr / bestTau;
        if (f0 >= 49.0 && f0 <= 2000.0) {
          _pitchConfidence = 1.0 - cmnd[bestTau];
          _lastPitchHz = f0;
          return f0;
        }
        _lastPitchHz = null;
        return null;
      }
    }
    _lastPitchHz = null;
    return null;
  }

  // ─── STAGE 6 — Tempo ────────────────────────────────────────────────

  void _updateTempo(double onsetNow, double frameMs) {
    _onsetEnv.add(onsetNow);
    final cap = (6000.0 / frameMs).round();
    if (_onsetEnv.length > cap) _onsetEnv.removeAt(0);

    final now = DateTime.now();
    if (_lastTempoRun != null &&
        now.difference(_lastTempoRun!).inMilliseconds < 500) {
      return;
    }
    _lastTempoRun = now;

    if (_onsetEnv.length < 60) return;

    final frameSec = frameMs / 1000.0;
    final minLag = max(1, (60.0 / 180.0 / frameSec).round());
    final maxLag = min(_onsetEnv.length - 1, (60.0 / 50.0 / frameSec).round());

    double bestVal = 0;
    int bestLag = 0;
    for (int lag = minLag; lag <= maxLag; lag++) {
      double sum = 0;
      final count = _onsetEnv.length - lag;
      for (int i = 0; i < count; i++) {
        sum += _onsetEnv[i] * _onsetEnv[i + lag];
      }
      if (sum > bestVal) {
        bestVal = sum;
        bestLag = lag;
      }
    }
    if (bestLag > 0) {
      final bpm = 60.0 / (bestLag * frameSec);
      final snapped = (bpm / 5).round() * 5.0;
      _bpmSmoothed = _bpmSmoothed == null
          ? snapped
          : _bpmSmoothed! * 0.8 + snapped * 0.2;
    }
  }

  // ─── STAGE 7 — Key detection ────────────────────────────────────────

  static const List<double> _majorProfile = [
    6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88
  ];
  static const List<double> _minorProfile = [
    6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17
  ];

  List<(int, Scale, double)> _detectKeys(List<double> chroma) {
    final results = <(int, Scale, double)>[];
    final rotated = List<double>.filled(12, 0.0);

    for (int r = 0; r < 12; r++) {
      // Major profile rotated
      for (int i = 0; i < 12; i++) {
        rotated[i] = _majorProfile[(i - r + 12) % 12];
      }
      results.add((r, kMajor, _pearson(chroma, rotated)));

      // Minor profile rotated
      for (int i = 0; i < 12; i++) {
        rotated[i] = _minorProfile[(i - r + 12) % 12];
      }
      results.add((r, kNatMinor, _pearson(chroma, rotated)));

      // Other scales as binary masks
      for (final s in kAllScales) {
        if (s == kMajor || s == kNatMinor) continue;
        final pcs = s.pitchClassesFor(r);
        for (int i = 0; i < 12; i++) rotated[i] = 0.0;
        for (final pc in pcs) rotated[pc] = 1.0;
        // Binary masks correlate more strongly than the graded K-S
        // profiles on the same pitch set; scale them down so C major
        // isn't reported as D Dorian.
        results.add((r, s, _pearson(chroma, rotated) * 0.85));
      }
    }

    results.sort((a, b) => b.$3.compareTo(a.$3));
    return results.take(3).toList(growable: false);
  }

  double _pearson(List<double> a, List<double> b) {
    double ma = 0, mb = 0;
    for (int i = 0; i < 12; i++) {
      ma += a[i];
      mb += b[i];
    }
    ma /= 12.0;
    mb /= 12.0;
    double num = 0, da = 0, db = 0;
    for (int i = 0; i < 12; i++) {
      final ai = a[i] - ma;
      final bi = b[i] - mb;
      num += ai * bi;
      da += ai * ai;
      db += bi * bi;
    }
    if (da < 1e-9 || db < 1e-9) return 0.0;
    return num / sqrt(da * db);
  }

  // ─── STAGE 8 — Polyphonic detection ─────────────────────────────────

  List<DetectedNote> _detectPolyphonic(int half) {
    final mags = _scratchMagnitudes;
    final n = _fftSize;
    _peakBuffer.clear();

    for (int k = 2; k < half - 1; k++) {
      final a = mags[k - 1];
      final b = mags[k];
      final c = mags[k + 1];
      if (b > a && b > c && b > 1e-3) {
        final denom = a - 2 * b + c;
        final delta = denom.abs() < 1e-9 ? 0.0 : 0.5 * (a - c) / denom;
        final f = (k + delta) * _sr / n;
        _peakBuffer.add(_Peak(f, b));
      }
    }

    _pcEnergy.fillRange(0, 12, 0.0);
    for (final p in _peakBuffer) {
      final midi = 69.0 + 12.0 * (log(p.freq / 440.0) / ln2);
      final pc = ((midi.round() % 12) + 12) % 12;
      _pcEnergy[pc] += p.mag;
    }

    double mx = 0;
    for (int i = 0; i < 12; i++) {
      if (_pcEnergy[i] > mx) mx = _pcEnergy[i];
    }
    if (mx < 1e-6) return const <DetectedNote>[];

    final out = <DetectedNote>[];
    for (int pc = 0; pc < 12; pc++) {
      final w = _pcEnergy[pc] / mx;
      if (w <= 0.15) continue;

      // Find the octave of the strongest peak for this pitch class
      int bestMidi = 60;
      double bestPeak = 0;
      for (final p in _peakBuffer) {
        final midi = 69.0 + 12.0 * (log(p.freq / 440.0) / ln2);
        final pcOfPeak = ((midi.round() % 12) + 12) % 12;
        if (pcOfPeak == pc && p.mag > bestPeak) {
          bestPeak = p.mag;
          bestMidi = midi.round().clamp(0, 127);
        }
      }
      out.add(DetectedNote(pc, bestMidi, w));
    }
    return out;
  }

  // ─── STAGE 9 — Silence / RMS ────────────────────────────────────────

  double _computeRms(Float64List x) {
    double sum = 0;
    for (int i = 0; i < x.length; i++) sum += x[i] * x[i];
    return sqrt(sum / x.length).clamp(0.0, 1.0);
  }

  bool _updateSilence(double rms) {
    if (rms > 0.01) {
      _lastSignalTime = DateTime.now();
      return false;
    }
    final since = _lastSignalTime;
    if (since == null) return true;
    return DateTime.now().difference(since).inMilliseconds > 500;
  }

  // ─── RESIZE / HELPERS ───────────────────────────────────────────────

  void _resize(int newSize) {
    _fftSize = newSize;
    _fft = FFT(newSize);
    _hann = _makeHann(newSize);
    _scratchWindowed = Float64List(newSize);
    _scratchMagnitudes = Float64List(newSize ~/ 2);
    _prevMagnitudes = List<double>.filled(newSize ~/ 2, 0.0);
    _binVariance = Float64List(newSize ~/ 2);
    _prevBinMag = Float64List(newSize ~/ 2);
    _dcPrevX = 0;
    _dcPrevY = 0;

    _onsetHistory.clear();
    _hfcHistory.clear();
    _lowFluxHistory.clear();
    _onsetEnv.clear();
    _lastKeyCandidates = const [];
    _bpmSmoothed = null;
    _lastTempoRun = null;
    _lastSignalTime = null;
    _frameCount = 0;
    _pitchConfidence = 0;
    _lastPitchHz = null;
    _peakBuffer.clear();
  }

  static Float64List _makeHann(int n) {
    final w = Float64List(n);
    for (int i = 0; i < n; i++) {
      w[i] = 0.5 * (1 - cos(2 * pi * i / n)); // periodic
    }
    return w;
  }

  static void _appendAndTrim(List<double> list, double v, int cap) {
    list.add(v);
    if (list.length > cap) list.removeAt(0);
  }

  static double _zScore(List<double> history, double v) {
    if (history.length < 8) return 0.0;
    double mean = 0;
    for (final x in history) mean += x;
    mean /= history.length;
    double variance = 0;
    for (final x in history) {
      final d = x - mean;
      variance += d * d;
    }
    variance /= history.length;
    final sd = sqrt(variance);
    if (sd < 1e-9) return 0.0;
    return (v - mean) / sd;
  }
}

class _OnsetResult {
  final double percussiveOnset;
  final double percussiveConfidence;
  final double lowBandFlux;
  const _OnsetResult({
    required this.percussiveOnset,
    required this.percussiveConfidence,
    required this.lowBandFlux,
  });
}