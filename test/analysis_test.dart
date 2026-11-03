import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sympatheia/analysis.dart';
import 'package:sympatheia/dsp_profile.dart';
import 'package:sympatheia/models.dart';

import 'helpers.dart';

void main() {
  group('AnalysisPipeline', () {
    test('detects C major from a sustained C–E–G chord', () {
      final p = AnalysisPipeline();
      AnalysisFrame? f;
      for (int k = 0; k < 64; k++) {
        f = p.process(chordFrame([60, 64, 67, 72], 2048, k * 2048),
            DspProfile.chamber, 1.0);
      }
      final top = f!.keyCandidates.first;
      // eslint-ish: print for CI log
      // ignore: avoid_print
      print('top key: ${pitchName(top.$1)} ${top.$2.name} ${top.$3}');
      expect(top.$1, 0);
      expect(top.$2.name, anyOf('Major', 'Pentatonic Major'));
    });

    test('detects A minor from an i–iv–V–i progression', () {
      const prog = [
        [57, 60, 64], [57, 60, 64], [50, 57, 62, 65], [52, 56, 59, 62], [57, 60, 64],
      ];
      final p = AnalysisPipeline();
      AnalysisFrame? f;
      int off = 0;
      for (int rep = 0; rep < 3; rep++) {
        for (final chord in prog) {
          for (int k = 0; k < 10; k++) {
            f = p.process(chordFrame(chord, 2048, off), DspProfile.chamber, 1.0);
            off += 2048;
          }
        }
      }
      final top = f!.keyCandidates.first;
      // ignore: avoid_print
      print('top key: ${pitchName(top.$1)} ${top.$2.name} ${top.$3}');
      expect(top.$1, 9);
    });

    test('chroma puts low notes in the right pitch class', () {
      for (final m in [40, 45, 52, 55, 57]) {
        final p = AnalysisPipeline();
        final f = p.process(chordFrame([m], 2048, 0), DspProfile.chamber, 1.0);
        var best = 0;
        for (int i = 1; i < 12; i++) {
          if (f.chroma[i] > f.chroma[best]) best = i;
        }
        expect(best, m % 12, reason: 'MIDI $m (${pitchName(m)})');
      }
    });

    test('YIN finds 440 Hz', () {
      final p = AnalysisPipeline();
      final x = Float64List(2048);
      for (int i = 0; i < x.length; i++) {
        x[i] = 0.3 * sin(2 * pi * 440 * i / sr);
      }
      final f = p.process(x, DspProfile.chamber, 1.0);
      expect(f.pitchHz, isNotNull);
      expect(f.pitchHz!, closeTo(440, 4));
    });

    test('silence is reported after 500 ms of nothing', () async {
      final p = AnalysisPipeline();
      p.process(chordFrame([60], 2048, 0), DspProfile.chamber, 1.0);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final f = p.process(Float64List(2048), DspProfile.chamber, 1.0);
      expect(f.silent, isTrue);
    });

    test('works at the Whisper tier (4096 window)', () {
      final p = AnalysisPipeline();
      AnalysisFrame? f;
      for (int k = 0; k < 40; k++) {
        f = p.process(chordFrame([62, 66, 69], 4096, k * 4096),
            DspProfile.whisper, 1.0);
      }
      expect(f!.keyCandidates.first.$1, 2); // D
    });
  });
}
