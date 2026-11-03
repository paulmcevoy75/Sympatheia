// lib/dsp.dart — small DSP building blocks used by the synth core.
//
// Pure Dart, no Flutter imports, so they are unit-testable.

import 'dart:math';
import 'dart:typed_data';

const double kSampleRate = 44100.0;

/// RBJ-cookbook biquad (transposed direct form II).
class Biquad {
  double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
  double _z1 = 0, _z2 = 0;

  Biquad();

  Biquad.lowpass(double f, double q, [double sr = kSampleRate]) {
    setLowpass(f, q, sr);
  }

  Biquad.highpass(double f, double q, [double sr = kSampleRate]) {
    setHighpass(f, q, sr);
  }

  Biquad.bandpass(double f, double q, [double sr = kSampleRate]) {
    setBandpass(f, q, sr);
  }

  Biquad.notch(double f, double q, [double sr = kSampleRate]) {
    final w0 = 2 * pi * _clampF(f, sr) / sr;
    final alpha = sin(w0) / (2 * q);
    final c = cos(w0);
    final a0 = 1 + alpha;
    b0 = 1 / a0;
    b1 = -2 * c / a0;
    b2 = 1 / a0;
    a1 = -2 * c / a0;
    a2 = (1 - alpha) / a0;
  }

  Biquad.highShelf(double f, double gainDb, [double sr = kSampleRate]) {
    final a = pow(10, gainDb / 40).toDouble();
    final w0 = 2 * pi * _clampF(f, sr) / sr;
    final c = cos(w0);
    final alpha = sin(w0) / 2 * sqrt(2.0);
    final sa = 2 * sqrt(a) * alpha;
    final a0 = (a + 1) - (a - 1) * c + sa;
    b0 = a * ((a + 1) + (a - 1) * c + sa) / a0;
    b1 = -2 * a * ((a - 1) + (a + 1) * c) / a0;
    b2 = a * ((a + 1) + (a - 1) * c - sa) / a0;
    a1 = 2 * ((a - 1) - (a + 1) * c) / a0;
    a2 = ((a + 1) - (a - 1) * c - sa) / a0;
  }

  static double _clampF(double f, double sr) => f.clamp(10.0, sr * 0.45);

  void setLowpass(double f, double q, [double sr = kSampleRate]) {
    final w0 = 2 * pi * _clampF(f, sr) / sr;
    final alpha = sin(w0) / (2 * max(q, 0.05));
    final c = cos(w0);
    final a0 = 1 + alpha;
    b0 = (1 - c) / 2 / a0;
    b1 = (1 - c) / a0;
    b2 = (1 - c) / 2 / a0;
    a1 = -2 * c / a0;
    a2 = (1 - alpha) / a0;
  }

  void setHighpass(double f, double q, [double sr = kSampleRate]) {
    final w0 = 2 * pi * _clampF(f, sr) / sr;
    final alpha = sin(w0) / (2 * max(q, 0.05));
    final c = cos(w0);
    final a0 = 1 + alpha;
    b0 = (1 + c) / 2 / a0;
    b1 = -(1 + c) / a0;
    b2 = (1 + c) / 2 / a0;
    a1 = -2 * c / a0;
    a2 = (1 - alpha) / a0;
  }

  /// Constant 0 dB peak gain bandpass.
  void setBandpass(double f, double q, [double sr = kSampleRate]) {
    final w0 = 2 * pi * _clampF(f, sr) / sr;
    final alpha = sin(w0) / (2 * max(q, 0.05));
    final c = cos(w0);
    final a0 = 1 + alpha;
    b0 = alpha / a0;
    b1 = 0;
    b2 = -alpha / a0;
    a1 = -2 * c / a0;
    a2 = (1 - alpha) / a0;
  }

  @pragma('vm:prefer-inline')
  double process(double x) {
    final y = b0 * x + _z1;
    _z1 = b1 * x - a1 * y + _z2;
    _z2 = b2 * x - a2 * y;
    return y;
  }

  void reset() {
    _z1 = 0;
    _z2 = 0;
  }
}

/// PolyBLEP residual for band-limited saw/square.
@pragma('vm:prefer-inline')
double polyBlep(double t, double dt) {
  if (t < dt) {
    final x = t / dt;
    return x + x - x * x - 1.0;
  } else if (t > 1.0 - dt) {
    final x = (t - 1.0) / dt;
    return x * x + x + x + 1.0;
  }
  return 0.0;
}

/// Paul Kellet pink noise filter (bug #24: filter-based, not averaging).
class PinkNoise {
  final Random _rng;
  double _b0 = 0, _b1 = 0, _b2 = 0, _b3 = 0, _b4 = 0, _b5 = 0, _b6 = 0;
  PinkNoise([int seed = 1]) : _rng = Random(seed);

  double next() {
    final white = _rng.nextDouble() * 2 - 1;
    _b0 = 0.99886 * _b0 + white * 0.0555179;
    _b1 = 0.99332 * _b1 + white * 0.0750759;
    _b2 = 0.96900 * _b2 + white * 0.1538520;
    _b3 = 0.86650 * _b3 + white * 0.3104856;
    _b4 = 0.55000 * _b4 + white * 0.5329522;
    _b5 = -0.7616 * _b5 - white * 0.0168980;
    final pink = _b0 + _b1 + _b2 + _b3 + _b4 + _b5 + _b6 + white * 0.5362;
    _b6 = white * 0.115926;
    return pink * 0.11;
  }
}

/// Integrated (brown) noise with leak.
class BrownNoise {
  final Random _rng;
  double _y = 0;
  BrownNoise([int seed = 2]) : _rng = Random(seed);
  double next() {
    _y = (_y + (_rng.nextDouble() * 2 - 1) * 0.02) * 0.998;
    return _y * 3.5;
  }
}

/// Freeverb-style stereo reverb (4 combs + 2 allpasses per channel).
class Reverb {
  static const _combTuning = [1116, 1277, 1422, 1557];
  static const _allpassTuning = [556, 441];
  static const _stereoSpread = 23;

  final List<_Comb> _combL = [], _combR = [];
  final List<_Allpass> _apL = [], _apR = [];
  double room = 0.75; // 0..1
  double damp = 0.3; // 0..1
  double wet = 0.3; // 0..1

  Reverb() {
    for (final t in _combTuning) {
      _combL.add(_Comb(t));
      _combR.add(_Comb(t + _stereoSpread));
    }
    for (final t in _allpassTuning) {
      _apL.add(_Allpass(t));
      _apR.add(_Allpass(t + _stereoSpread));
    }
  }

  /// Process one stereo block in place.
  void process(Float64List l, Float64List r, int n) {
    final fb = 0.7 + room.clamp(0.0, 1.0) * 0.28;
    final d = damp.clamp(0.0, 1.0) * 0.4;
    final w = wet.clamp(0.0, 1.0);
    final dry = 1.0 - w * 0.5;
    for (int i = 0; i < n; i++) {
      final input = (l[i] + r[i]) * 0.015;
      double outL = 0, outR = 0;
      for (int c = 0; c < _combL.length; c++) {
        outL += _combL[c].process(input, fb, d);
        outR += _combR[c].process(input, fb, d);
      }
      for (int a = 0; a < _apL.length; a++) {
        outL = _apL[a].process(outL);
        outR = _apR[a].process(outR);
      }
      l[i] = l[i] * dry + outL * w;
      r[i] = r[i] * dry + outR * w;
    }
  }
}

class _Comb {
  final Float64List _buf;
  int _idx = 0;
  double _store = 0;
  _Comb(int size) : _buf = Float64List(size);
  @pragma('vm:prefer-inline')
  double process(double x, double feedback, double damp) {
    final out = _buf[_idx];
    _store = out * (1 - damp) + _store * damp;
    _buf[_idx] = x + _store * feedback;
    if (++_idx >= _buf.length) _idx = 0;
    return out;
  }
}

class _Allpass {
  final Float64List _buf;
  int _idx = 0;
  _Allpass(int size) : _buf = Float64List(size);
  @pragma('vm:prefer-inline')
  double process(double x) {
    final b = _buf[_idx];
    final out = -x + b;
    _buf[_idx] = x + b * 0.5;
    if (++_idx >= _buf.length) _idx = 0;
    return out;
  }
}

/// Stereo modulated-delay chorus.
class Chorus {
  final Float64List _bl = Float64List(4096), _br = Float64List(4096);
  int _w = 0;
  double _phase = 0;
  double rateHz = 0.4;
  double depthMs = 6;
  double mix = 0.35;

  void process(Float64List l, Float64List r, int n) {
    const baseMs = 12.0;
    final inc = rateHz / kSampleRate;
    for (int i = 0; i < n; i++) {
      _bl[_w] = l[i];
      _br[_w] = r[i];
      final m = sin(2 * pi * _phase);
      final dl = (baseMs + depthMs * 0.5 * (1 + m)) * kSampleRate / 1000;
      final dr = (baseMs + depthMs * 0.5 * (1 - m)) * kSampleRate / 1000;
      final yl = _read(_bl, _w - dl);
      final yr = _read(_br, _w - dr);
      l[i] = l[i] * (1 - mix * 0.5) + yl * mix;
      r[i] = r[i] * (1 - mix * 0.5) + yr * mix;
      _w = (_w + 1) & 4095;
      _phase += inc;
      if (_phase >= 1) _phase -= 1;
    }
  }

  static double _read(Float64List b, double pos) {
    var p = pos;
    while (p < 0) {
      p += 4096;
    }
    final i0 = p.floor() & 4095;
    final frac = p - p.floor();
    return b[i0] * (1 - frac) + b[(i0 + 1) & 4095] * frac;
  }
}

/// Stereo feedback delay (max 1.5 s).
class Delay {
  static const int _size = 65536; // > 1.48 s at 44.1k
  final Float64List _bl = Float64List(_size), _br = Float64List(_size);
  int _w = 0;
  double timeMs = 400;
  double feedback = 0.3;
  double wet = 0.2;

  void process(Float64List l, Float64List r, int n) {
    final d = (timeMs.clamp(1, 1400) * kSampleRate / 1000).round();
    for (int i = 0; i < n; i++) {
      final ri = (_w - d) & (_size - 1);
      final yl = _bl[ri], yr = _br[ri];
      _bl[_w] = l[i] + yr * feedback; // cross-feed: gentle ping-pong
      _br[_w] = r[i] + yl * feedback;
      l[i] += yl * wet;
      r[i] += yr * wet;
      _w = (_w + 1) & (_size - 1);
    }
  }
}

/// Fast tanh for soft limiting.
@pragma('vm:prefer-inline')
double softClip(double x) {
  if (x > 3) return 1.0;
  if (x < -3) return -1.0;
  final x2 = x * x;
  return x * (27 + x2) / (27 + 9 * x2);
}
