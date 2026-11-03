import 'package:flutter_test/flutter_test.dart';
import 'package:sympatheia/brain.dart';
import 'package:sympatheia/models.dart';
import 'package:sympatheia/percussion.dart';
import 'package:sympatheia/state.dart';
import 'package:sympatheia/tonal_language.dart';

import 'helpers.dart';

List<double> chromaOf(List<int> pcs) {
  final c = List<double>.filled(12, 0.05);
  for (final pc in pcs) {
    c[pc] = 1.0;
  }
  return c;
}

void main() {
  test('Tonal follows a detected G major after it holds steady', () {
    final app = AppState();
    final lang = TonalLanguage();
    var ctx = lang.init(app);
    for (int i = 0; i < 20; i++) {
      ctx = lang.update(
        ctx,
        fakeFrame(
          chroma: chromaOf([7, 11, 2]),
          keys: [(7, kMajor, 0.9)],
        ),
        app,
      );
    }
    expect(ctx.displayLabel, 'G Major');
    expect(ctx.currentChord!.rootPc, 7);
    expect(ctx.padPitchesMidi, isNotEmpty);
  });

  test('Tonal does not flicker on a single stray frame', () {
    final app = AppState();
    final lang = TonalLanguage();
    var ctx = lang.init(app);
    for (int i = 0; i < 20; i++) {
      ctx = lang.update(ctx, fakeFrame(chroma: chromaOf([0, 4, 7]), keys: [(0, kMajor, 0.9)]), app);
    }
    ctx = lang.update(ctx, fakeFrame(chroma: chromaOf([1, 5, 8]), keys: [(1, kMajor, 0.9)]), app);
    expect(ctx.displayLabel, 'C Major');
  });

  test('Brain keeps language state across frames and builds a MusicalState', () {
    final app = AppState();
    final brain = AccompanimentBrain();
    final perc = PercussionAnalyzer();
    MusicalState? s;
    for (int i = 0; i < 20; i++) {
      s = brain.update(
        fakeFrame(chroma: chromaOf([2, 6, 9]), keys: [(2, kMajor, 0.9)]),
        app,
        perc,
      );
    }
    expect(s!.languageLabel, 'D Major');
    expect(s.keyPc, 2);
    expect(s.padMidi, isNotEmpty);
    expect(s.rhythmSchedule, isNotEmpty); // free-running fallback
  });

  test('Manual mode uses the fixed key', () {
    final app = AppState()
      ..mode = AppMode.manual
      ..manualKeyPc = 5
      ..manualScale = kDorian;
    final brain = AccompanimentBrain();
    final s = brain.update(
      fakeFrame(chroma: chromaOf([0, 4, 7]), keys: [(0, kMajor, 0.9)]),
      app,
      PercussionAnalyzer(),
    );
    expect(s.languageLabel, 'F Dorian');
  });
}
