import 'package:flutter_test/flutter_test.dart';
import 'package:sympatheia/percussion.dart';

import 'helpers.dart';

/// Feed a click track: onset spikes on the frames nearest each beat.
PercussionAnalyzer runClicks(double bpm, double seconds, {double frameMs = 1000 * 2048 / 44100}) {
  final p = PercussionAnalyzer();
  final start = DateTime(2026, 1, 1);
  final beatMs = 60000 / bpm;
  final frames = (seconds * 1000 / frameMs).round();
  double nextBeat = 0;
  for (int k = 0; k < frames; k++) {
    final t = k * frameMs;
    double onset = 0;
    if (t >= nextBeat - frameMs / 2) {
      onset = 4.0;
      nextBeat += beatMs;
    }
    p.update(fakeFrame(percussiveOnset: onset), frameMs,
        now: start.add(Duration(microseconds: (t * 1000).round())));
  }
  return p;
}

void main() {
  for (final bpm in [80.0, 100.0, 120.0, 140.0]) {
    test('estimates $bpm BPM from a click track', () {
      final p = runClicks(bpm, 12);
      // ignore: avoid_print
      print('target $bpm → ${p.tempoBpm}');
      expect(p.tempoBpm, isNotNull);
      expect(p.tempoBpm!, closeTo(bpm, bpm * 0.06));
    });
  }

  test('locks to the beat after a few bars', () {
    final p = runClicks(110, 12);
    expect(p.beatLocked, isTrue);
  });

  test('unlocks after 3 s without hits', () {
    final p = PercussionAnalyzer();
    final start = DateTime(2026, 1, 1);
    const frameMs = 46.4;
    for (int k = 0; k < 300; k++) {
      final onset = (k < 200 && k % 11 == 0) ? 4.0 : 0.0;
      p.update(fakeFrame(percussiveOnset: onset), frameMs,
          now: start.add(Duration(milliseconds: (k * frameMs).round())));
    }
    expect(p.beatLocked, isFalse);
    expect(p.tempoBpm, isNull);
  });
}
