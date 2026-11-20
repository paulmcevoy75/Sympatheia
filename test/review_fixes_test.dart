// Tests for the Nov 20 review fixes (harmonizer, key changes, rhythm
// lock, rhythm learning).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sympatheia/brain.dart';
import 'package:sympatheia/dsp_profile.dart';
import 'package:sympatheia/harmonic_language.dart';
import 'package:sympatheia/models.dart';
import 'package:sympatheia/percussion.dart';
import 'package:sympatheia/state.dart';
import 'package:sympatheia/synth_core.dart';
import 'package:sympatheia/tonal_language.dart';

import 'helpers.dart';

List<double> chromaOf(List<int> pcs) {
  final c = List<double>.filled(12, 0.05);
  for (final pc in pcs) {
    c[pc] = 1.0;
  }
  return c;
}

MusicalState rhythmState(List<RhythmHit> hits) => MusicalState(
      keyPc: 0,
      scale: kMajor,
      chord: const Chord(0, ChordQuality.maj),
      droneRootPc: 0,
      padPcs: const [0, 4, 7],
      padMidi: const [60, 64, 67],
      rhythmSchedule: hits,
      textureIds: const [],
      harmonySchedule: const [],
      intensity: const {
        'rhythm': 0.8,
        'drone': 0.0,
        'chords': 0.0,
        'sounds': 0.0,
        'harmony': 0.0,
      },
      silent: false,
      languageLabel: 'C Major',
      worldId: 'tame_impala_fan', // pluck rhythm
    );

void main() {
  group('harmonizer', () {
    AppState harmonizerApp() => AppState()
      ..soundWorldId = 'parallel_chords'
      ..mode = AppMode.listen
      ..harmonyInterval = HarmonyInterval.diatonic3;

    test('plays one harmony note per held note, not one per frame', () {
      final app = harmonizerApp();
      final brain = AccompanimentBrain();
      final perc = PercussionAnalyzer();
      // Settle on C major with no pitched note.
      for (int i = 0; i < 120; i++) {
        brain.update(
            fakeFrame(chroma: chromaOf([0, 4, 7]), keys: [(0, kMajor, 0.9)]),
            app,
            perc);
      }
      int events = 0;
      for (int i = 0; i < 40; i++) {
        final s = brain.update(
            fakeFrame(
              chroma: chromaOf([0, 4, 7]),
              keys: [(0, kMajor, 0.9)],
              pitchHz: 261.63, // C4 held
              pitchConfidence: 0.9,
            ),
            app,
            perc);
        events += s.harmonySchedule.length;
      }
      expect(events, 1);
    });

    test('harmony follows the detected key, not the manual key', () {
      final app = harmonizerApp()
        ..manualKeyPc = 0
        ..manualScale = kMajor;
      final brain = AccompanimentBrain();
      final perc = PercussionAnalyzer();
      // Player is in E major.
      for (int i = 0; i < 120; i++) {
        brain.update(
            fakeFrame(chroma: chromaOf([4, 8, 11]), keys: [(4, kMajor, 0.9)]),
            app,
            perc);
      }
      final events = <HarmonyEvent>[];
      for (int i = 0; i < 5; i++) {
        final s = brain.update(
            fakeFrame(
              chroma: chromaOf([4, 8, 11]),
              keys: [(4, kMajor, 0.9)],
              pitchHz: 329.63, // E4
              pitchConfidence: 0.9,
            ),
            app,
            perc);
        events.addAll(s.harmonySchedule);
      }
      expect(events, isNotEmpty);
      // Diatonic 3rd above E in E major is G#, not G.
      expect(events.first.pitchMidi % 12, 8);
    });
  });

  group('pending key change', () {
    // Settle on C major, then hold F# long enough to queue G major.
    (TonalLanguage, HarmonicContext, AppState) queueG() {
      final app = AppState()..follow = 0.35;
      final lang = TonalLanguage();
      var ctx = lang.init(app);
      for (int i = 0; i < 120; i++) {
        ctx = lang.update(ctx,
            fakeFrame(chroma: chromaOf([0, 4, 7]), keys: [(0, kMajor, 0.9)]), app);
      }
      ctx = lang.handleOutOfContextNote(
          ctx, 6, const Duration(milliseconds: 1200), app);
      return (lang, ctx, app);
    }

    test('commits after 2 s if nothing contradicts it', () async {
      final (lang, c0, app) = queueG();
      var ctx = c0;
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      ctx = lang.update(ctx,
          fakeFrame(chroma: chromaOf([0, 4, 7]), keys: [(0, kMajor, 0.9)]), app);
      expect(ctx.displayLabel, 'G Major');
    });

    test('is cancelled when the player goes back to the old key', () async {
      final (lang, c0, app) = queueG();
      var ctx = c0;
      // Play F natural (in C major, not in G major) for a few frames.
      for (int i = 0; i < 6; i++) {
        ctx = lang.update(
            ctx,
            fakeFrame(
              chroma: chromaOf([0, 4, 7]),
              keys: [(0, kMajor, 0.9)],
              pitchHz: 349.23,
              pitchConfidence: 0.9,
            ),
            app);
      }
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      ctx = lang.update(ctx,
          fakeFrame(chroma: chromaOf([0, 4, 7]), keys: [(0, kMajor, 0.9)]), app);
      expect(ctx.displayLabel, 'C Major');
    });
  });

  test('manual mode reports the manual key to the brain', () {
    final app = AppState()
      ..mode = AppMode.manual
      ..manualKeyPc = 0;
    final brain = AccompanimentBrain();
    final perc = PercussionAnalyzer();
    brain.update(fakeFrame(chroma: chromaOf([0, 4, 7])), app, perc);
    app.manualKeyPc = 7; // user changes the key without a language reset
    final s = brain.update(fakeFrame(chroma: chromaOf([7, 11, 2])), app, perc);
    expect(s.keyPc, 7);
  });

  group('percussion', () {
    const frameMs = 1000 * 2048 / 44100;

    test('learns a hit repeated on the same step every bar', () {
      final p = PercussionAnalyzer();
      final start = DateTime(2026, 1, 1);
      const bpm = 110.0;
      const beatMs = 60000 / bpm;
      final frames = (30000 / frameMs).round();
      double nextBeat = 0;
      int beat = 0;
      for (int k = 0; k < frames; k++) {
        final t = k * frameMs;
        double onset = 0, conf = 0.3; // beats 2–4: tempo only
        if (t >= nextBeat - frameMs / 2) {
          onset = 4.0;
          if (beat % 4 == 0) conf = 1.0; // beat 1: counts for the pattern
          nextBeat += beatMs;
          beat++;
        }
        p.update(fakeFrame(percussiveOnset: onset, percussiveConfidence: conf),
            frameMs,
            now: start.add(Duration(microseconds: (t * 1000).round())));
      }
      expect(p.beatLocked, isTrue);
      final pattern = p.rhythmPattern;
      expect(pattern.length, 16);
      expect(pattern.reduce((a, b) => a > b ? a : b), greaterThan(0.6)); // old code: ~0.14
    });

    test('reports a bar position once locked', () {
      final p = PercussionAnalyzer();
      final start = DateTime(2026, 1, 1);
      const beatMs = 60000 / 120.0;
      double nextBeat = 0;
      for (int k = 0; k < (12000 / frameMs).round(); k++) {
        final t = k * frameMs;
        double onset = 0;
        if (t >= nextBeat - frameMs / 2) {
          onset = 4.0;
          nextBeat += beatMs;
        }
        p.update(fakeFrame(percussiveOnset: onset), frameMs,
            now: start.add(Duration(microseconds: (t * 1000).round())));
      }
      expect(p.beatLocked, isTrue);
      expect(p.barPosition, isNotNull);
      expect(p.barPosition!, inInclusiveRange(0.0, 4.0));
    });
  });

  group('synth rhythm clock', () {
    List<NoteEvent> rhythmEvents(SynthCore core) => core
        .drainNoteEvents()
        .where((e) => e.layerId == 'rhythm')
        .toList();

    test('free-running clock does not fire a beat-2 hit at once', () {
      final core = SynthCore();
      core.apply(rhythmState(const [RhythmHit(2, 7, 0.8)]), DspProfile.chamber,
          master: 0.5, reverb: 0.45, spatial: 0.7, bpm: 120);
      core.render(Float32List(512), 256);
      expect(rhythmEvents(core), isEmpty);
    });

    test('locks to the player\'s bar position', () {
      final core = SynthCore();
      // Player is just before beat 2 (0-based) of the bar.
      core.apply(rhythmState(const [RhythmHit(2, 7, 0.8)]), DspProfile.chamber,
          master: 0.5, reverb: 0.45, spatial: 0.7, bpm: 120,
          barPosition: 1.995, leadFrames: 0);
      core.render(Float32List(512), 256);
      final ev = rhythmEvents(core);
      expect(ev, hasLength(1));
      expect(ev.first.midiNote, 67);
    });
  });
}
