// lib/aec.dart — Phase 2 acoustic echo cancelling.
//
// The synth's exact output (SynthCore's reference ring) is the echo
// reference. Two stages:
//
//   1. Bulk delay estimate. Speaker → room → mic plus the audio
//      drivers add an unknown delay (tens to hundreds of ms). About once
//      a second, cross-correlate ~0.75 s of mic against the reference
//      (decimated ×8) over lags 0–500 ms and take the clear peak.
//   2. NLMS adaptive FIR on the delay-aligned reference removes what's
//      left (room reflections, speaker colouration). Adaptation slows
//      right down while the player is louder than the echo (double
//      talk), so the filter doesn't learn to cancel the instrument.
//
// ERLE (echo return loss enhancement, dB) is reported for the UI.

import 'dart:math';
import 'dart:typed_data';

class EchoCanceller {
  EchoCanceller({int taps = 512, this.stepSize = 0.15})
      : taps = taps.clamp(32, 4096) {
    _w = Float64List(this.taps);
  }

  final int taps;
  final double stepSize;
  late Float64List _w;

  /// Current bulk delay estimate, samples (null until found).
  int? delaySamples;
  double delayConfidence = 0;

  /// Smoothed ERLE, dB.
  double erleDb = 0;

  /// RMS of the last block's echo estimate.
  double lastEchoRms = 0;

  /// Taps placed before the bulk-delay point (allows a slightly early
  /// estimate).
  int get preTaps => taps ~/ 4;

  void reset() {
    _w.fillRange(0, _w.length, 0);
    erleDb = 0;
    lastEchoRms = 0;
  }

  /// Cancel echo from [mic] (length L). [ref] holds L + taps − 1
  /// reference samples, oldest first, aligned so that ref[i + taps − 1]
  /// corresponds to mic[i] at lag (delay − preTaps).
  Float64List process(Float64List mic, Float64List ref) {
    final n = mic.length;
    final out = Float64List(n);
    final w = _w;
    final t = taps;

    // Block energies for double-talk detection (uses last block's filter).
    double refPow = 0;
    for (int i = 0; i < ref.length; i++) {
      refPow += ref[i] * ref[i];
    }
    if (refPow < 1e-9) {
      // Nothing playing → nothing to cancel.
      for (int i = 0; i < n; i++) {
        out[i] = mic[i];
      }
      lastEchoRms = 0;
      return out;
    }

    // Running power of the current tap window.
    double winPow = 0;
    for (int k = 0; k < t; k++) {
      final v = ref[k];
      winPow += v * v;
    }

    double micE = 0, resE = 0, echoE = 0;
    // First pass: estimate echo with current weights to judge double talk.
    // (Cheap proxy: use the first quarter of the block.)
    final probe = max(1, n ~/ 4);
    for (int i = 0; i < probe; i++) {
      double y = 0;
      final base = i + t - 1;
      for (int k = 0; k < t; k++) {
        y += w[k] * ref[base - k];
      }
      echoE += y * y;
      final e = mic[i] - y;
      resE += e * e;
    }
    // Only trust the double-talk test once the filter has learned
    // something; a fresh filter would otherwise never start adapting.
    final doubleTalk = erleDb > 6.0 && resE > 4.0 * echoE + 1e-7;
    final mu = doubleTalk ? stepSize * 0.03 : stepSize;
    echoE = 0;
    resE = 0;

    for (int i = 0; i < n; i++) {
      final base = i + t - 1;
      if (i > 0) {
        final inV = ref[base];
        final outV = ref[base - t];
        winPow += inV * inV - outV * outV;
        if (winPow < 0) winPow = 0;
      }
      double y = 0;
      for (int k = 0; k < t; k++) {
        y += w[k] * ref[base - k];
      }
      final e = mic[i] - y;
      out[i] = e;
      micE += mic[i] * mic[i];
      resE += e * e;
      echoE += y * y;
      final g = mu * e / (winPow + 1e-4);
      if (g != 0) {
        for (int k = 0; k < t; k++) {
          w[k] += g * ref[base - k];
        }
      }
    }

    lastEchoRms = sqrt(echoE / n);
    if (resE <= 4.0 * echoE + 1e-7 && micE > 1e-7) {
      final erle = 10 * log(micE / max(resE, 1e-12)) / ln10;
      erleDb = erleDb * 0.9 + erle.clamp(0.0, 40.0) * 0.1;
    }
    return out;
  }

  // ─── Bulk delay estimation ───────────────────────────────────────

  static const int decim = 8;

  /// [mic]: recent mic samples (oldest first). [ref]: reference covering
  /// the same span extended [maxLag] samples further into the past,
  /// i.e. ref.length == mic.length + maxLag, where ref[j + maxLag]
  /// lines up with mic[j] at zero extra delay. Returns true when a
  /// confident estimate was found.
  bool estimateDelay(Float64List mic, Float64List ref, int maxLag) {
    final m = _decimate(mic);
    final r = _decimate(ref);
    final lags = maxLag ~/ decim;
    if (m.isEmpty || r.length < m.length + lags) return false;

    double mPow = 0;
    for (final v in m) {
      mPow += v * v;
    }
    double rPow = 0;
    for (final v in r) {
      rPow += v * v;
    }
    if (mPow < 1e-7 || rPow < 1e-7) return false;

    // GCC-PHAT: whitened cross-correlation, so tonal music (whose
    // plain correlation repeats every period) still gives one sharp
    // peak at the true delay.
    int nfft = 1;
    while (nfft < r.length + 1) {
      nfft <<= 1;
    }
    final xr = Float64List(nfft), xi = Float64List(nfft);
    final yr = Float64List(nfft), yi = Float64List(nfft);
    for (int j = 0; j < m.length; j++) {
      xr[j] = m[j];
    }
    for (int j = 0; j < r.length; j++) {
      yr[j] = r[j];
    }
    _fft(xr, xi, false);
    _fft(yr, yi, false);
    for (int k = 0; k < nfft; k++) {
      // conj(X) * Y
      final re = xr[k] * yr[k] + xi[k] * yi[k];
      final im = xr[k] * yi[k] - xi[k] * yr[k];
      final mag = sqrt(re * re + im * im) + 1e-12;
      xr[k] = re / mag;
      xi[k] = im / mag;
    }
    _fft(xr, xi, true);
    final corr = Float64List(lags + 1);
    for (int d = 0; d <= lags; d++) {
      // c[k] = Σ mic[j]·ref[j+k]; k = lags − d
      corr[d] = xr[lags - d].abs();
    }
    int best = 0;
    double peak = 0, sum = 0;
    for (int d = 0; d <= lags; d++) {
      sum += corr[d];
      if (corr[d] > peak) {
        peak = corr[d];
        best = d;
      }
    }
    final mean = sum / (lags + 1);
    final conf = mean > 0 ? peak / mean : 0.0;
    delayConfidence = conf;
    if (conf < 6.0) return false;

    final d = best * decim;
    final prev = delaySamples;
    if (prev == null || (d - prev).abs() > taps ~/ 2) {
      // Big jump (first lock, device change): take it and re-learn.
      delaySamples = d;
      reset();
    } else {
      // Small drift: follow gently and slide the learned response so
      // it stays lined up with the room.
      final next = (prev + (d - prev) * 0.25).round();
      _shiftWeights(next - prev);
      delaySamples = next;
    }
    return true;
  }

  /// In-place radix-2 complex FFT (n must be a power of two).
  static void _fft(Float64List re, Float64List im, bool inverse) {
    final n = re.length;
    for (int i = 1, j = 0; i < n; i++) {
      int bit = n >> 1;
      for (; (j & bit) != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        var t = re[i];
        re[i] = re[j];
        re[j] = t;
        t = im[i];
        im[i] = im[j];
        im[j] = t;
      }
    }
    for (int len = 2; len <= n; len <<= 1) {
      final ang = 2 * pi / len * (inverse ? 1 : -1);
      final wr = cos(ang), wi = sin(ang);
      for (int i = 0; i < n; i += len) {
        double cr = 1, ci = 0;
        final half = len >> 1;
        for (int k = 0; k < half; k++) {
          final a = i + k, b = a + half;
          final tr = re[b] * cr - im[b] * ci;
          final ti = re[b] * ci + im[b] * cr;
          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] += tr;
          im[a] += ti;
          final ncr = cr * wr - ci * wi;
          ci = cr * wi + ci * wr;
          cr = ncr;
        }
      }
    }
    if (inverse) {
      for (int i = 0; i < n; i++) {
        re[i] /= n;
        im[i] /= n;
      }
    }
  }

  void _shiftWeights(int s) {
    if (s == 0) return;
    final old = Float64List.fromList(_w);
    for (int k = 0; k < taps; k++) {
      final src = k + s;
      _w[k] = (src >= 0 && src < taps) ? old[src] : 0.0;
    }
  }

  static Float64List _decimate(Float64List x) {
    final n = x.length ~/ decim;
    final out = Float64List(n);
    for (int i = 0; i < n; i++) {
      double s = 0;
      final b = i * decim;
      for (int k = 0; k < decim; k++) {
        s += x[b + k];
      }
      out[i] = s / decim;
    }
    return out;
  }
}
