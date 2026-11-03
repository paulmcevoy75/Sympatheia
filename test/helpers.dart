import 'dart:math';
import 'dart:typed_data';

import 'package:sympatheia/models.dart';

const double sr = 44100.0;

/// Sum of sines at the given MIDI notes, [n] samples, starting at sample
/// offset [offset] (keeps phase continuous across frames).
Float64List chordFrame(List<int> midis, int n, int offset, {double amp = 0.2}) {
  final out = Float64List(n);
  for (final m in midis) {
    final f = hzFromMidi(m);
    for (int i = 0; i < n; i++) {
      final t = (offset + i) / sr;
      // a little harmonic content, like a real instrument
      out[i] += amp *
          (sin(2 * pi * f * t) +
              0.5 * sin(4 * pi * f * t) +
              0.25 * sin(6 * pi * f * t));
    }
  }
  return out;
}

AnalysisFrame fakeFrame({
  double percussiveOnset = 0,
  double percussiveConfidence = 1,
  List<double>? chroma,
  double? pitchHz,
  double pitchConfidence = 0,
  bool silent = false,
  List<(int, Scale, double)> keys = const [],
}) =>
    AnalysisFrame(
      chroma: chroma ?? List<double>.filled(12, 0),
      pitchHz: pitchHz,
      pitchConfidence: pitchConfidence,
      onsetStrength: percussiveOnset,
      percussiveOnset: percussiveOnset,
      percussiveConfidence: percussiveConfidence,
      lowBandFlux: 0,
      tempoBpm: null,
      keyCandidates: keys,
      rmsLevel: 0.1,
      silent: silent,
      detectedNotes: const [],
      rhythmPattern: const [],
      beatLocked: false,
      beatPhase01: null,
      analysisConfidence: 1,
      timestamp: DateTime.now(),
    );
