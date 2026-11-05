import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sympatheia/dsp_profile.dart';
import 'package:sympatheia/models.dart';
import 'package:sympatheia/sound_worlds.dart';
import 'package:sympatheia/synth_core.dart';

MusicalState stateFor(String worldId, {bool silent = false}) => MusicalState(
      keyPc: 0,
      scale: kMajor,
      chord: const Chord(0, ChordQuality.maj),
      droneRootPc: 0,
      padPcs: const [0, 4, 7],
      padMidi: const [60, 64, 67],
      rhythmSchedule: const [
        RhythmHit(0, 0, 0.8),
        RhythmHit(1, 4, 0.5),
        RhythmHit(2, 7, 0.6),
        RhythmHit(3, 4, 0.3),
      ],
      textureIds: const [],
      harmonySchedule: const [],
      intensity: const {
        'rhythm': 0.3,
        'drone': 0.45,
        'chords': 0.55,
        'sounds': 0.3,
        'harmony': 0.55,
      },
      silent: silent,
      languageLabel: 'C Major',
      worldId: worldId,
    );

(double, double) renderSeconds(SynthCore core, double seconds) {
  final buf = Float32List(512);
  double peak = 0, sumSq = 0;
  int count = 0;
  final blocks = (seconds * 44100 / 256).round();
  for (int b = 0; b < blocks; b++) {
    core.render(buf, 256);
    for (int i = 0; i < 512; i++) {
      final v = buf[i];
      expect(v.isFinite, isTrue);
      peak = max(peak, v.abs());
      sumSq += v * v;
      count++;
    }
  }
  return (peak, sqrt(sumSq / count));
}

void main() {
  test('every sound world renders audible, finite, bounded output', () {
    for (final id in kSoundWorlds.keys) {
      final core = SynthCore();
      core.apply(stateFor(id), DspProfile.chamber,
          master: 0.5, reverb: 0.45, spatial: 0.7, bpm: 100);
      final (peak, rms) = renderSeconds(core, 3.0);
      // ignore: avoid_print
      print('$id: peak ${peak.toStringAsFixed(3)} rms ${rms.toStringAsFixed(4)} '
          'voices ${core.activeVoiceCount}');
      expect(peak, lessThanOrEqualTo(1.0));
      expect(rms, greaterThan(0.001), reason: '$id is silent');
    }
  });

  test('render is fast enough for real time', () {
    final core = SynthCore();
    core.apply(stateFor('huge_chords'), DspProfile.whisper,
        master: 0.5, reverb: 0.45, spatial: 0.7, bpm: 100);
    final sw = Stopwatch()..start();
    renderSeconds(core, 5.0);
    sw.stop();
    // ignore: avoid_print
    print('5 s of huge_chords rendered in ${sw.elapsedMilliseconds} ms');
    // Generous bound: the test VM runs unoptimised (JIT, asserts on).
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });

  test('world switch crossfades without silence', () {
    final core = SynthCore();
    core.apply(stateFor('tame_impala_fan'), DspProfile.chamber,
        master: 0.5, reverb: 0.45, spatial: 0.7);
    renderSeconds(core, 2.0);
    core.apply(stateFor('washy_reverb'), DspProfile.chamber,
        master: 0.5, reverb: 0.45, spatial: 0.7);
    final (_, rms) = renderSeconds(core, 0.5);
    expect(rms, greaterThan(0.001));
  });

  test('long silence fades the accompaniment out (§11.4)', () {
    final core = SynthCore();
    core.apply(stateFor('tame_impala_fan', silent: true), DspProfile.chamber,
        master: 0.5, reverb: 0.2, spatial: 0.7);
    renderSeconds(core, 1.0);
    // keep applying silent state while 65 s pass
    for (int s = 0; s < 65; s++) {
      core.apply(stateFor('tame_impala_fan', silent: true), DspProfile.chamber,
          master: 0.5, reverb: 0.2, spatial: 0.7);
      renderSeconds(core, 1.0);
    }
    final (_, rms) = renderSeconds(core, 1.0);
    expect(rms, lessThan(0.002));
  });

  test('reference ring mirrors output', () {
    final core = SynthCore();
    core.apply(stateFor('tame_impala_fan'), DspProfile.chamber,
        master: 0.5, reverb: 0.45, spatial: 0.0);
    renderSeconds(core, 1.0);
    final ref = core.referenceAt(core.renderedFrames - 1024, 1024);
    final energy = ref.fold<double>(0, (a, v) => a + v * v);
    expect(energy, greaterThan(0));
  });

  test('ambient worlds have no stray rhythm plucks; bells ring in ice', () {
    for (final id in ['musical_sea', 'washy_reverb', 'singing_child',
        'eastern_european_choir', 'russian_choir', 'clumsy_kind_giant']) {
      final core = SynthCore();
      core.apply(stateFor(id), DspProfile.chamber,
          master: 0.5, reverb: 0.45, spatial: 0.7, bpm: 100);
      renderSeconds(core, 3);
      final hits = core.drainNoteEvents().where((e) => e.layerId == 'rhythm');
      expect(hits, isEmpty, reason: id);
    }
    final ice = SynthCore();
    ice.apply(stateFor('ice_crystals'), DspProfile.chamber,
        master: 0.5, reverb: 0.45, spatial: 0.7, bpm: 100);
    final (peak, _) = renderSeconds(ice, 3);
    expect(ice.drainNoteEvents().where((e) => e.layerId == 'rhythm'),
        isNotEmpty);
    expect(peak, lessThanOrEqualTo(1.0));
  });
}
