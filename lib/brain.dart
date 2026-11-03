// lib/brain.dart — §11.1 (fixed: persistent language, out-of-context handling)
import 'dart:math';
import 'models.dart';
import 'state.dart';
import 'harmonic_language.dart';
import 'sound_worlds.dart';
import 'percussion.dart';

class AccompanimentBrain {
  BrainStatus _status = BrainStatus.idle;
  BrainStatus get status => _status;

  // ─── Modulation state machine ────────────────────────────────────
  DateTime? _outOfKeyStart;
  DateTime? _silentSince;

  // ─── Harmonizer state ────────────────────────────────────────────
  HarmonizerMode _lastHarmonizerMode = HarmonizerMode.trailing;
  HarmonizerMode get harmonizerMode => _lastHarmonizerMode;
  double _harmonizability = 0.6;
  final List<_RecentNote> _recentNotes = <_RecentNote>[];
  final List<_Prediction> _predictions = <_Prediction>[];
  static const int _recentNoteCap = 8;
  static const int _predictionCap = 8;

  // ─── Texture rotation ────────────────────────────────────────────
  int _textureIdx = 0;
  DateTime _lastTextureChange = DateTime(2000);

  // ─── Spatial role map (read by antiphonal engine via getter) ────
  Map<String, VoiceSpatialRole> _spatialRoles = const {};

  Map<String, VoiceSpatialRole> get activeVoiceRoles => _spatialRoles;

  // ─── Language instance (FIX: stateful languages persist) ─────────
  HarmonicLanguage? _language;
  String? _languageId;
  HarmonicContext? _context;

  // Out-of-context note tracking
  int? _oocPc;
  DateTime? _oocSince;

  HarmonicContext? get context => _context;

  /// Force the language to re-seed (e.g. manual key/scale changed).
  void resetLanguage() {
    _languageId = null;
  }

  // ─── MAIN ENTRY POINT ────────────────────────────────────────────

  MusicalState update(
    AnalysisFrame frame,
    AppState app,
    PercussionAnalyzer percussion,
  ) {
    // 0. Keep one language instance per id; init once (FIX).
    if (_language == null || _languageId != app.harmonicLanguageId) {
      _language = languageById(app.harmonicLanguageId);
      _languageId = app.harmonicLanguageId;
      _context = _language!.init(app);
      _oocPc = null;
      _oocSince = null;
    }
    final language = _language!;

    _updateStatus(frame);

    // 1. Language decides pitch content (state carried across frames).
    var context = language.update(_context!, frame, app);

    // 1b. Out-of-context note handling (sustained pitch outside the key).
    context = _handleOutOfContext(frame, app, language, context);
    _context = context;

    final world = worldById(app.soundWorldId);

    // 2. Rhythm schedule
    final rhythmHits = world.rhythm.type == RhythmType.none
        ? const <RhythmHit>[]
        : _buildRhythmSchedule(frame, app, context, percussion,
            world.rhythm.density);

    // 3. Harmony schedule (only for harmonizer world)
    final harmonyEvents = app.soundWorldId == 'parallel_chords'
        ? _buildHarmonySchedule(frame, app, context, percussion)
        : const <HarmonyEvent>[];

    // 4. Textures
    final textureIds = _buildTextures(app);

    // 5. Spatial roles
    _spatialRoles = _assignSpatialRoles(app);

    // 6. Track recent notes for harmonizer prediction
    _recordNoteIfPresent(frame);

    final keyPc = (context.data['committedKeyPc'] as int?) ??
        (context.padPitchesMidi.isNotEmpty
            ? context.padPitchesMidi.first % 12
            : app.manualKeyPc);
    final scaleName = context.data['committedScaleName'] as String?;
    final scale = scaleName == null
        ? app.manualScale
        : kAllScales.firstWhere((s) => s.name == scaleName,
            orElse: () => app.manualScale);

    // 7. Compose
    return MusicalState(
      keyPc: keyPc,
      scale: scale,
      chord: context.currentChord,
      droneRootPc: context.bassPitchesMidi.isNotEmpty
          ? context.bassPitchesMidi.first % 12
          : keyPc,
      padPcs: context.padPitchesMidi.map((m) => m % 12).toList(),
      padMidi: context.padPitchesMidi,
      rhythmSchedule: rhythmHits,
      textureIds: textureIds,
      harmonySchedule: harmonyEvents,
      intensity: {
        'rhythm': app.rhythm,
        'drone': app.drone,
        'chords': app.chords,
        'sounds': app.sounds,
        'harmony': app.harmony,
      },
      silent: frame.silent && app.mode != AppMode.manual,
      languageLabel: context.displayLabel.isEmpty
          ? language.name
          : context.displayLabel, // bug #34
      worldId: app.soundWorldId,
    );
  }

  HarmonicContext _handleOutOfContext(
    AnalysisFrame frame,
    AppState app,
    HarmonicLanguage language,
    HarmonicContext ctx,
  ) {
    if (app.mode == AppMode.manual || app.mode == AppMode.progression) {
      return ctx;
    }
    final hz = frame.pitchHz;
    if (hz == null || frame.pitchConfidence < 0.6) {
      _oocPc = null;
      _oocSince = null;
      notifyInContext();
      return ctx;
    }
    final pc = pitchClassFromHz(hz);
    final keyPc = ctx.data['committedKeyPc'] as int?;
    final scaleName = ctx.data['committedScaleName'] as String?;
    if (pc == null || keyPc == null || scaleName == null) return ctx;
    final scale = kAllScales.firstWhere((s) => s.name == scaleName,
        orElse: () => kMajor);
    if (scale.contains(keyPc, pc)) {
      _oocPc = null;
      _oocSince = null;
      notifyInContext();
      return ctx;
    }
    final now = DateTime.now();
    if (_oocPc != pc) {
      _oocPc = pc;
      _oocSince = now;
    }
    notifyOutOfContext(_oocSince!);
    return language.handleOutOfContextNote(
        ctx, pc, now.difference(_oocSince!), app);
  }

  // ─── STATUS STATE MACHINE ────────────────────────────────────────

  void _updateStatus(AnalysisFrame frame) {
    final now = DateTime.now();

    if (frame.silent) {
      _silentSince ??= now;
      if (now.difference(_silentSince!).inMilliseconds > 3000) {
        _status = BrainStatus.idle;
        _outOfKeyStart = null;
      }
      return;
    }
    _silentSince = null;

    // Confidence gating: low analysis confidence means we require
    // stronger evidence before declaring out-of-key.
    final conf = frame.analysisConfidence;
    if (conf < 0.3) {
      _status = BrainStatus.listening;
      _outOfKeyStart = null;
      return;
    }

    if (_outOfKeyStart != null) {
      final dur = now.difference(_outOfKeyStart!);
      if (dur.inMilliseconds < 350) {
        _status = BrainStatus.stable;
      } else if (dur.inMilliseconds < 1500) {
        _status = BrainStatus.modulating;
      } else {
        _status = BrainStatus.pedal;
      }
      return;
    }

    final hasKey = frame.keyCandidates.isNotEmpty &&
        frame.keyCandidates.first.$3 > 0.5;
    _status = hasKey ? BrainStatus.stable : BrainStatus.listening;
  }

  /// Called by the language when it detects an out-of-context note
  /// (the language owns the actual modulation decision; the brain
  /// only tracks timing for the status pill).
  void notifyOutOfContext(DateTime since) {
    _outOfKeyStart = since;
  }

  void notifyInContext() {
    _outOfKeyStart = null;
  }

  // ─── RHYTHM SCHEDULE ─────────────────────────────────────────────

  List<RhythmHit> _buildRhythmSchedule(
    AnalysisFrame frame,
    AppState app,
    HarmonicContext ctx,
    PercussionAnalyzer percussion,
    double density,
  ) {
    if (app.rhythm < 0.05) return const [];

    final chordPcs = ctx.currentChord?.pitchClasses() ??
        (ctx.padPitchesMidi.isEmpty
            ? <int>[app.manualKeyPc]
            : ctx.padPitchesMidi.map((m) => m % 12).toList());

    if (chordPcs.isEmpty) return const [];

    // Beat-locked: follow the learned 16-step pattern
    if (percussion.beatLocked) {
      final pattern = percussion.rhythmPattern;
      if (pattern.length != 16) return const [];

      // Cap hits per bar by the world's rhythm density.
      final maxHits = max(1, (16 * density).round());
      final ranked = [
        for (int s = 0; s < 16; s++)
          if (pattern[s] >= 0.35) s
      ]..sort((a, b) => pattern[b].compareTo(pattern[a]));
      final keep = ranked.take(maxHits).toSet();
      final hits = <RhythmHit>[];
      for (int step = 0; step < 16; step++) {
        if (!keep.contains(step)) continue;
        final pc = chordPcs[step % chordPcs.length];
        hits.add(RhythmHit(step / 4.0, pc, pattern[step] * app.rhythm));
      }
      return hits;
    }

    // Free-running fallback: up to 4 hits per bar on chord tones
    final hits = <RhythmHit>[];
    final nHits = max(1, min(4, (8 * density).round()));
    for (int b = 0; b < nHits; b++) {
      final pc = chordPcs[b % chordPcs.length];
      hits.add(RhythmHit(b.toDouble(), pc, 0.5 * app.rhythm));
    }
    return hits;
  }

  // ─── HARMONIZER SCHEDULE ─────────────────────────────────────────

  List<HarmonyEvent> _buildHarmonySchedule(
    AnalysisFrame frame,
    AppState app,
    HarmonicContext ctx,
    PercussionAnalyzer percussion,
  ) {
    _updateHarmonizability(frame, app);
    final mode = _selectHarmonizerMode(frame, app, percussion.beatLocked);

    // Mode transitions crossfade over 600 ms — the synth engine handles
    // the actual crossfade by observing the mode change on the state.
    _lastHarmonizerMode = mode;

    switch (mode) {
      case HarmonizerMode.predictive:
        return _schedulePredictive(frame, app);
      case HarmonizerMode.canon:
        return _scheduleCanon(frame, app);
      case HarmonizerMode.trailing:
        return _scheduleTrailing(frame, app);
      case HarmonizerMode.phrase:
        return _schedulePhrase(frame, app);
      case HarmonizerMode.aestheticSilence:
        return const [];
    }
  }

  void _updateHarmonizability(AnalysisFrame frame, AppState app) {
    final keyConf =
        frame.keyCandidates.isEmpty ? 0.0 : frame.keyCandidates.first.$3;
    final density = frame.detectedNotes.length / 6.0;
    final speed = (frame.onsetStrength * 6.0).clamp(0.0, 1.0);
    final stability =
        frame.pitchConfidence > 0.6 ? 1.0 : frame.pitchConfidence;

    _harmonizability = (keyConf * (1 - density) * (1 - speed) * stability)
        .clamp(0.0, 1.0);
  }

  HarmonizerMode _selectHarmonizerMode(
      AnalysisFrame frame, AppState app, bool beatLocked) {
    if (app.forcedHarmonizerMode != null) return app.forcedHarmonizerMode!;
    if (_harmonizability < 0.35) return HarmonizerMode.aestheticSilence;

    final nps = _notesPerSecond();
    final predScore = _predictionSuccessRate();

    if (beatLocked && nps < 2.5 && predScore > 0.70) {
      return HarmonizerMode.predictive;
    }
    if (beatLocked) return HarmonizerMode.canon;
    if (nps < 1.5) return HarmonizerMode.trailing;
    return HarmonizerMode.phrase;
  }

  double _notesPerSecond() {
    if (_recentNotes.length < 2) return 0.0;
    final span = _recentNotes.last.t.difference(_recentNotes.first.t);
    if (span.inMilliseconds == 0) return 0.0;
    return _recentNotes.length / (span.inMilliseconds / 1000.0);
  }

  double _predictionSuccessRate() {
    if (_predictions.isEmpty) return 0.0;
    final hits = _predictions.where((p) => p.wasHit).length;
    return hits / _predictions.length;
  }

  void _recordNoteIfPresent(AnalysisFrame frame) {
    if (frame.pitchHz == null || frame.pitchConfidence < 0.6) return;

    final pc = pitchClassFromHz(frame.pitchHz!);
    if (pc == null) return;

    final now = DateTime.now();
    _recentNotes.add(_RecentNote(pc, now));
    if (_recentNotes.length > _recentNoteCap) _recentNotes.removeAt(0);

    // Resolve pending predictions: did the actual PC match any pending
    // prediction within its ±40 ms window?
    for (final p in _predictions) {
      if (p.wasHit) continue;
      if (now.difference(p.predictedAt).inMilliseconds > 200) continue;
      if (p.predictedPc == pc) {
        p.wasHit = true;
        break;
      }
    }
    _predictions.removeWhere(
        (p) => now.difference(p.predictedAt).inMilliseconds > 1000);
  }

  List<HarmonyEvent> _schedulePredictive(AnalysisFrame frame, AppState app) {
    // Bug #8: predictive requires a confident pitch from the prior
    // note. If unavailable, fall through to canon.
    if (frame.pitchHz == null || frame.pitchConfidence <= 0.6) {
      return _scheduleCanon(frame, app);
    }
    final pc = pitchClassFromHz(frame.pitchHz!);
    if (pc == null) return _scheduleCanon(frame, app);

    final harmonyPc = _harmonyIntervalPc(pc, app.harmonyInterval, app);
    final harmonyMidi = _octaveForHarmony(pc, harmonyPc);

    // Queue prediction for success tracking
    _predictions.add(_Prediction(harmonyPc, DateTime.now()));
    if (_predictions.length > _predictionCap) _predictions.removeAt(0);

    return [
      HarmonyEvent(
        pitchMidi: harmonyMidi,
        velocity: 0.55 * app.harmony,
        delay: const Duration(milliseconds: 50),
      ),
    ];
  }

  List<HarmonyEvent> _scheduleCanon(AnalysisFrame frame, AppState app) {
    if (frame.pitchHz == null) return const [];
    final pc = pitchClassFromHz(frame.pitchHz!);
    if (pc == null) return const [];

    final harmonyPc = _harmonyIntervalPc(pc, app.harmonyInterval, app);
    final bpm = frame.tempoBpm ?? 90;
    final beatMs = 60000.0 / bpm;
    final delayMs = beatMs.round().clamp(100, 1200);

    return [
      HarmonyEvent(
        pitchMidi: _octaveForHarmony(pc, harmonyPc),
        velocity: 0.6 * app.harmony,
        delay: Duration(milliseconds: delayMs),
      ),
    ];
  }

  List<HarmonyEvent> _scheduleTrailing(AnalysisFrame frame, AppState app) {
    if (frame.pitchHz == null) return const [];
    final pc = pitchClassFromHz(frame.pitchHz!);
    if (pc == null) return const [];

    final harmonyPc = _harmonyIntervalPc(pc, app.harmonyInterval, app);
    return [
      HarmonyEvent(
        pitchMidi: _octaveForHarmony(pc, harmonyPc),
        velocity: 0.5 * app.harmony,
        delay: const Duration(milliseconds: 200),
      ),
    ];
  }

  List<HarmonyEvent> _schedulePhrase(AnalysisFrame frame, AppState app) {
    if (_recentNotes.isEmpty) return const [];

    // Dominant pitch class over the phrase buffer
    final counts = <int, int>{};
    for (final n in _recentNotes) {
      counts[n.pc] = (counts[n.pc] ?? 0) + 1;
    }
    final dominant =
        counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    final harmonyPc =
        _harmonyIntervalPc(dominant, app.harmonyInterval, app);

    return [
      HarmonyEvent(
        pitchMidi: _octaveForHarmony(dominant, harmonyPc),
        velocity: 0.5 * app.harmony,
        delay: Duration.zero,
        glideDuration: const Duration(milliseconds: 800),
      ),
    ];
  }

  /// Harmony interval → pitch class, respecting the manual scale for
  /// diatonic intervals, and using fixed semitones for parallel ones.
  int _harmonyIntervalPc(int pc, HarmonyInterval interval, AppState app) {
    switch (interval) {
      case HarmonyInterval.diatonic3:
        return _diatonicStep(pc, 2, app, fallbackSemis: 4);
      case HarmonyInterval.diatonic6:
        return _diatonicStep(pc, 5, app, fallbackSemis: 9);
      case HarmonyInterval.diatonic5:
        return _diatonicStep(pc, 4, app, fallbackSemis: 7);
      case HarmonyInterval.parallel5:
        return (pc + 7) % 12;
      case HarmonyInterval.parallel4:
        return (pc + 5) % 12;
      case HarmonyInterval.octave:
        return pc;
      case HarmonyInterval.triad:
        return _diatonicStep(pc, 2, app, fallbackSemis: 4);
    }
  }

  int _diatonicStep(int pc, int steps, AppState app, {required int fallbackSemis}) {
    final intervals = app.manualScale.intervals;
    final rootPc = app.manualKeyPc;
    // Convert to scale-degree index
    final relPc = (pc - rootPc + 12) % 12;
    final idx = intervals.indexOf(relPc);
    if (idx < 0) return (pc + fallbackSemis) % 12;
    final newIdx = (idx + steps) % intervals.length;
    // Add an octave when wrapping
    final octave = ((idx + steps) ~/ intervals.length) * 12;
    return (rootPc + intervals[newIdx] + octave) % 12;
  }

  /// Keep the harmony above the player's note (up to 1 octave higher)
  /// so it doesn't muddy the player's register.
  int _octaveForHarmony(int playerPc, int harmonyPc) {
    final playerMidi = 60 + playerPc;
    var midi = 60 + harmonyPc;
    while (midi <= playerMidi) midi += 12;
    return midi.clamp(48, 96);
  }

  // ─── TEXTURES ────────────────────────────────────────────────────

  List<String> _buildTextures(AppState app) {
    if (app.sounds < 0.05) return const [];
    final now = DateTime.now();
    if (now.difference(_lastTextureChange).inSeconds < 5) {
      return [_textureId()];
    }
    _lastTextureChange = now;
    _textureIdx = (_textureIdx + 1) % 4;
    return [_textureId()];
  }

  String _textureId() => const [
        'pink_noise_cloud',
        'air_noise_high',
        'wood_click_sparse',
        'grain_slow',
      ][_textureIdx];

  // ─── SPATIAL ROLES ───────────────────────────────────────────────

  Map<String, VoiceSpatialRole> _assignSpatialRoles(AppState app) {
    return {
      'drone': VoiceSpatialRole.centered,
      'pad_root': VoiceSpatialRole.front,
      'rhythm': VoiceSpatialRole.centered,
      'texture': VoiceSpatialRole.centered,
      'harmony': const VoiceSpatialRole(
        anchorAngle: 180, callAngle: 180, responseAngle: 0),
      'bass': VoiceSpatialRole.centered,
    };
  }
}

// ─── Internal support types ─────────────────────────────────────────

class _RecentNote {
  final int pc;
  final DateTime t;
  _RecentNote(this.pc, this.t);
}

class _Prediction {
  final int predictedPc;
  final DateTime predictedAt;
  bool wasHit;
  _Prediction(this.predictedPc, this.predictedAt, {this.wasHit = false});
}