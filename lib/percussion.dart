// lib/percussion.dart — §10 PercussionAnalyzer
//
// Beat tracking + 16-step pattern learning.
//
// FIXES vs. the delivered spec (see DEVIATIONS.md):
//   * The onset envelope holds one entry per analysis frame (frames
//     arrive every ~46/93 ms). The spec assumed a 10 ms envelope, which
//     made every BPM estimate ~4.6x wrong.
//   * PLL phase error is measured against the NEAREST beat, not the next
//     one (an on-beat hit used to read as one full period early).

import 'dart:math';
import 'models.dart';

class PercussionAnalyzer {
  // ─── Envelope (one entry per frame, ~6 s) ──────────────────────
  final List<double> _env = <double>[];
  double _frameMs = 46.4;

  DateTime _lastAutocorrRun = DateTime(2000);
  static const int _autocorrIntervalMs = 500;

  // ─── Beat tracking ─────────────────────────────────────────────
  double? _bpm;
  double _beatPeriodMs = 0;
  DateTime _nextBeatTime = DateTime.now();
  double _beatPhase = 0.0;
  int _beatCount = 0; // running beat counter (for call/response etc.)

  // ─── Bar / lock tracking ───────────────────────────────────────
  DateTime? _lastBarStart;
  int _beatInBar = 0; // 0..3, counted from the first beat boundary
  int _barsLocked = 0;
  static const int _barsRequiredForLock = 2;

  // ─── PLL ───────────────────────────────────────────────────────
  double _phaseErrorMsSum = 0;
  int _phaseErrorCount = 0;
  static const int _phaseErrorResetCount = 4;

  // ─── Pattern learning ──────────────────────────────────────────
  static const int _patternSteps = 16;
  final List<double> _pattern = List<double>.filled(_patternSteps, 0.0);
  DateTime _lastPatternDecay = DateTime.now();
  static const int _patternDecayMs = 2000;
  static const double _patternDecayFactor = 0.85;
  static const double _patternOnsetConfidenceThreshold = 0.55;
  DateTime? _lastPatternOnset;

  // ─── Lock timeout ──────────────────────────────────────────────
  DateTime _lastStrongOnset = DateTime.now();
  static const int _lockTimeoutMs = 3000;

  /// Onset threshold (z-score units from the analysis pipeline).
  static const double strongOnsetThreshold = 1.0;

  // ─── Getters ───────────────────────────────────────────────────
  double? get tempoBpm => _bpm;
  bool get beatLocked => _barsLocked >= _barsRequiredForLock;
  int get beatCount => _beatCount;

  double? get beatPhase01 =>
      (_bpm != null && _beatPeriodMs > 0) ? _beatPhase : null;

  /// Position in the 4-beat bar (0 ≤ x < 4) at the last update, in the
  /// same bar the 16-step pattern is learned against. Null until beat
  /// locked. The synth uses it to line its rhythm clock up with the
  /// player (16-step index = barPosition × 4).
  double? get barPosition =>
      (beatLocked && _beatPeriodMs > 0) ? _beatInBar + _beatPhase : null;

  List<double> get rhythmPattern {
    if (!beatLocked) return const <double>[];
    return List<double>.unmodifiable(_pattern);
  }

  // ─── Main entry ────────────────────────────────────────────────

  /// [now] is injectable for tests.
  void update(AnalysisFrame frame, double frameMs, {DateTime? now}) {
    final t = now ?? DateTime.now();
    if ((frameMs - _frameMs).abs() > 1.0) {
      _env.clear(); // tier change: lag units changed
    }
    _frameMs = frameMs;

    _env.add(frame.percussiveOnset);
    final cap = (6000.0 / _frameMs).round();
    while (_env.length > cap) {
      _env.removeAt(0);
    }

    _updateBeatTracking(frame, t);
    _updatePattern(frame, t);
    _decayPattern(t);
    _checkLockTimeout(t);
  }

  // ─── Beat tracking ─────────────────────────────────────────────

  void _updateBeatTracking(AnalysisFrame frame, DateTime now) {
    if (_bpm != null && _beatPeriodMs > 0) {
      while (!now.isBefore(_nextBeatTime)) {
        _nextBeatTime = _nextBeatTime.add(
          Duration(microseconds: (_beatPeriodMs * 1000).round()),
        );
        _onBeatBoundary(now);
      }
      final remaining =
          _nextBeatTime.difference(now).inMicroseconds / 1000.0;
      _beatPhase = (1.0 - (remaining / _beatPeriodMs)).clamp(0.0, 1.0);
    }

    if (now.difference(_lastAutocorrRun).inMilliseconds >= _autocorrIntervalMs) {
      _lastAutocorrRun = now;
      _estimateBpm(now);
    }

    if (frame.percussiveOnset > strongOnsetThreshold) {
      _lastStrongOnset = now;
      if (_bpm != null && _beatPeriodMs > 0) {
        // FIX: error against the nearest beat.
        final toNext = _nextBeatTime.difference(now).inMicroseconds / 1000.0;
        final sincePrev = _beatPeriodMs - toNext;
        final errMs = sincePrev <= toNext ? sincePrev : -toNext;
        final window = min(80.0, _beatPeriodMs * 0.25);
        if (errMs.abs() < window) {
          _phaseErrorMsSum += errMs;
          _phaseErrorCount++;
          if (_phaseErrorCount >= _phaseErrorResetCount) {
            final avg = _phaseErrorMsSum / _phaseErrorCount;
            // Positive err = hits land AFTER the predicted beat → move later.
            _nextBeatTime = _nextBeatTime.add(
              Duration(microseconds: (avg * 0.5 * 1000).round()),
            );
            _phaseErrorMsSum = 0;
            _phaseErrorCount = 0;
          }
        }
      }
    }
  }

  void _onBeatBoundary(DateTime now) {
    _beatCount++;
    if (_lastBarStart == null) {
      _lastBarStart = now; // bug #28
      _beatInBar = 0;
      return;
    }
    // Count bars in beats, not wall time: boundaries are only seen once
    // per analysis frame, so timestamps jitter by up to a frame.
    _beatInBar = (_beatInBar + 1) % 4;
    if (_beatInBar == 0) {
      _lastBarStart = now;
      _barsLocked++;
    }
  }

  void _estimateBpm(DateTime now) {
    final frameSec = _frameMs / 1000.0;
    final minLag = max(1, (60.0 / 180.0 / frameSec).floor());
    final maxLag = (60.0 / 50.0 / frameSec).ceil();
    if (_env.length < maxLag * 2) return;

    double bestVal = 0.0;
    int bestLag = 0;
    for (int lag = minLag; lag <= maxLag; lag++) {
      double sum = 0.0;
      final count = _env.length - lag;
      for (int i = 0; i < count; i++) {
        sum += _env[i] * _env[i + lag];
      }
      sum /= count;
      sum *= (1.0 + 0.1 * (maxLag - lag) / max(1, maxLag - minLag));
      if (sum > bestVal) {
        bestVal = sum;
        bestLag = lag;
      }
    }
    if (bestLag == 0 || bestVal < 1e-6) return;

    // Parabolic refinement of the lag for sub-frame tempo resolution.
    double lagF = bestLag.toDouble();
    if (bestLag > minLag && bestLag < maxLag) {
      double ac(int l) {
        double s = 0;
        final c = _env.length - l;
        for (int i = 0; i < c; i++) {
          s += _env[i] * _env[i + l];
        }
        return s / c;
      }

      final a = ac(bestLag - 1), b = ac(bestLag), c = ac(bestLag + 1);
      final denom = a - 2 * b + c;
      if (denom.abs() > 1e-12) {
        lagF = bestLag + (0.5 * (a - c) / denom).clamp(-0.5, 0.5);
      }
    }

    final newBpm = (60.0 / (lagF * frameSec)).clamp(50.0, 180.0);
    if (_bpm == null) {
      _bpm = newBpm;
      _beatPeriodMs = 60000.0 / newBpm;
      _nextBeatTime = now;
    } else {
      _bpm = _bpm! * 0.8 + newBpm * 0.2;
      _beatPeriodMs = 60000.0 / _bpm!;
    }
  }

  // ─── Pattern learning ──────────────────────────────────────────

  void _updatePattern(AnalysisFrame frame, DateTime now) {
    if (!beatLocked) return;
    if (frame.percussiveOnset <= strongOnsetThreshold) return;
    if (frame.percussiveConfidence < _patternOnsetConfidenceThreshold) return;
    if (_lastBarStart == null || _bpm == null) return;

    final sixteenthMs = _beatPeriodMs / 4.0;
    // One count per onset. FIX: this used to skip any onset on the same
    // step as the previous one, so a hit repeated on the same step every
    // bar (e.g. beat 1 only) was counted once and then decayed away. An
    // onset spans one or two frames, so use a short refractory time.
    final last = _lastPatternOnset;
    final refractoryMs = max(_frameMs * 1.5, sixteenthMs * 0.6);
    if (last != null &&
        now.difference(last).inMicroseconds / 1000.0 < refractoryMs) {
      return;
    }
    _lastPatternOnset = now;
    // Same bar position the synth locks to (see barPosition).
    final pos = _beatInBar + _beatPhase;
    final step = (pos * 4).round() % _patternSteps;

    _pattern[step] = (_pattern[step] + 1.0).clamp(0.0, 8.0);
    double mx = 0.0;
    for (final v in _pattern) {
      if (v > mx) mx = v;
    }
    if (mx > 0) {
      for (int i = 0; i < _patternSteps; i++) {
        _pattern[i] /= mx;
      }
    }
  }

  void _decayPattern(DateTime now) {
    if (now.difference(_lastPatternDecay).inMilliseconds < _patternDecayMs) {
      return;
    }
    _lastPatternDecay = now;
    for (int i = 0; i < _patternSteps; i++) {
      _pattern[i] *= _patternDecayFactor;
    }
  }

  void _checkLockTimeout(DateTime now) {
    if (_bpm == null && _barsLocked == 0) return;
    if (now.difference(_lastStrongOnset).inMilliseconds > _lockTimeoutMs) {
      _unlock();
    }
  }

  void _unlock() {
    _barsLocked = 0;
    _lastBarStart = null;
    _bpm = null;
    _beatPeriodMs = 0;
    _beatPhase = 0;
    _env.clear();
    for (int i = 0; i < _patternSteps; i++) {
      _pattern[i] = 0.0;
    }
    _phaseErrorMsSum = 0;
    _phaseErrorCount = 0;
    _lastPatternOnset = null;
    _beatInBar = 0;
  }

  void reset() {
    _unlock();
    _lastAutocorrRun = DateTime(2000);
    _nextBeatTime = DateTime.now();
    _lastPatternDecay = DateTime.now();
    _lastStrongOnset = DateTime.now();
    _beatCount = 0;
  }

  Map<String, Object?> debugState() => {
        'bpm': _bpm,
        'beatPeriodMs': _beatPeriodMs,
        'beatPhase': _beatPhase,
        'locked': beatLocked,
        'barsLocked': _barsLocked,
        'envLength': _env.length,
        'pattern': List<double>.from(_pattern),
      };
}
