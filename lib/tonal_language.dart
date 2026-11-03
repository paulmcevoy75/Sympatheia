// lib/tonal_language.dart
import 'dart:math';

import 'models.dart';
import 'state.dart';
import 'harmonic_language.dart';

/// Tonal — the baseline harmonic language.
///
/// Behavior:
///   - In Manual mode: uses app.manualKeyPc / app.manualScale directly.
///   - In Progression mode: uses the current chord's root and quality
///     to derive a working key.
///   - In Listen / Harmonize: follows the detected key, but only
///     commits to a change after N consecutive consistent observations
///     (smoothing) to prevent flicker.
///
/// Every frame it:
///   1. Resolves the working key/scale per the current mode.
///   2. Smooths key changes (skip in Manual/Progression).
///   3. Applies any pending modulation from handleOutOfContextNote.
///   4. Picks a chord from the chroma, biased by key degree.
///   5. Voice-leads the pad against the previous voicing.
///   6. Emits bass pitch from the chord root.
///
/// The language is STATEFUL. The brain must hold one instance per
/// session (see note above) — init()/update() called every frame from
/// a fresh instance loses all state.

class TonalLanguage implements HarmonicLanguage {
  // ─── Identity ──────────────────────────────────────────────────
  @override
  String get id => 'tonal';
  @override
  String get name => 'Tonal';
  @override
  String get description =>
      'Key + scale. Detects or uses the manual key.';

  // ─── Persisted state ───────────────────────────────────────────

  // Key detection smoothing. Requires N consecutive same-key
  // observations before committing to a change.
  final List<_KeyObservation> _keyHistory = [];
  static const int _keyHistoryCap = 20;
  static const int _stableObservations = 8; // ~370 ms at 46 ms frames
  static const double _minKeyScore = 0.55;

  // Current committed key — drives the pad/bass chord. May differ
  // from the detected key during modulation windows (intentional: we
  // only commit when stable).
  int _committedKeyPc = 0;
  Scale _committedScale = kMajor;
  DateTime? _committedAt;

  // Last pad voicing for voice-leading. Absolute MIDI notes, one per
  // pad voice.
  List<int> _lastVoicing = const [];

  // Pending modulation set by handleOutOfContextNote. Commits in
  // update() once it's been pending for > 1000 ms.
  (int, Scale)? _pendingModulation;
  DateTime? _pendingModulationAt;

  // ─── UI ────────────────────────────────────────────────────────
  //
  // currentValue is null — the getter has no AppState. The UI reads
  // the current selection from AppState via stateFieldKey.

  @override
  List<LanguageUIElement> get uiElements {
    return [
      LanguageUIElement(
        key: 'tonal_key',
        label: 'Key',
        type: UIElementType.dropdownInt,
        options: [
          for (int i = 0; i < 12; i++) (pitchName(i), i),
        ],
        currentValue: null,
        stateFieldKey: 'manualKeyPc',
      ),
      LanguageUIElement(
        key: 'tonal_scale',
        label: 'Scale',
        type: UIElementType.dropdown,
        options: [
          for (final s in kAllScales) (s.name, s.name),
        ],
        currentValue: null,
        stateFieldKey: 'manualScale',
      ),
    ];
  }

  // ─── init ──────────────────────────────────────────────────────

  @override
  HarmonicContext init(AppState app) {
    _keyHistory.clear();
    _lastVoicing = const [];
    _pendingModulation = null;
    _pendingModulationAt = null;
    _committedKeyPc = app.manualKeyPc;
    _committedScale = app.manualScale;
    _committedAt = DateTime.now();

    final seedVoicing = _seedVoicing(_committedKeyPc, _committedScale);
    _lastVoicing = seedVoicing;

    return HarmonicContext(
      currentChord: Chord(_committedKeyPc, ChordQuality.maj),
      padPitchesMidi: seedVoicing,
      bassPitchesMidi: [_bassMidiFor(_committedKeyPc)],
      displayLabel:
          '${pitchName(_committedKeyPc)} ${_committedScale.name}',
      tonalStability: 0.5,
    );
  }

  // ─── update ────────────────────────────────────────────────────

  @override
  HarmonicContext update(
    HarmonicContext current,
    AnalysisFrame frame,
    AppState app,
  ) {
    // 1. Which key should we be in based on mode?
    var working = _resolveWorkingKey(frame, app);

    // 2. Smooth key changes — only in reactive modes.
    if (app.mode == AppMode.listen || app.mode == AppMode.harmonize) {
      working = _smoothKeyChange(working);
    }

    // 3. Commit pending modulation if it's been pending > 1 s.
    if (_pendingModulation != null && _pendingModulationAt != null) {
      final elapsed = DateTime.now().difference(_pendingModulationAt!);
      if (elapsed.inMilliseconds > 1000) {
        _committedKeyPc = _pendingModulation!.$1;
        _committedScale = _pendingModulation!.$2;
        _committedAt = DateTime.now();
        working = _pendingModulation!;
        _pendingModulation = null;
        _pendingModulationAt = null;
        // Clear smoothing history so we don't immediately bounce back.
        _keyHistory.clear();
      }
    }

    // 4. Pick chord from chroma.
    final chord = _pickChord(frame.chroma, working.$1, working.$2);

    // 5. Voice-lead the pad from the previous voicing.
    final padPitches = _voiceLeadPad(chord, _lastVoicing);
    _lastVoicing = padPitches;

    // 6. Bass note one octave below the chord root.
    final bassPitches = [_bassMidiFor(chord.rootPc)];

    // 7. Tonal stability from frame key detection confidence.
    final stability = _computeTonalStability(frame, working);

    return HarmonicContext(
      data: {
        'committedKeyPc': _committedKeyPc,
        'committedScaleName': _committedScale.name,
      },
      currentChord: chord,
      padPitchesMidi: padPitches,
      bassPitchesMidi: bassPitches,
      displayLabel: '${pitchName(working.$1)} ${working.$2.name}',
      tonalStability: stability,
    );
  }

  // ─── handleOutOfContextNote ────────────────────────────────────

  @override
  HarmonicContext handleOutOfContextNote(
    HarmonicContext current,
    int pitchClass,
    Duration sustainedFor,
    AppState app,
  ) {
    // < 350 ms: passing tone. Do nothing.
    if (sustainedFor.inMilliseconds < 350) {
      return current;
    }

    // 350–1500 ms: try to find a nearby key that contains the pitch
    // class. If found, set pending modulation.
    if (sustainedFor.inMilliseconds < 1500) {
      final alternate = _findAlternateKeyContaining(pitchClass);
      if (alternate != null) {
        // Only replace an existing pending modulation if the new
        // target differs (avoid resetting the pending timer every
        // frame the player holds the same pitch class).
        if (_pendingModulation != alternate) {
          _pendingModulation = alternate;
          _pendingModulationAt = DateTime.now();
        }
      }
      // During 350–1500 ms, always reduce reported stability so the
      // brain shows "modulating" in the status pill. The actual
      // modulation commits in update() once pending > 1 s.
      return current.copyWith(
        tonalStability: max(0.2, current.tonalStability * 0.6),
      );
    }

    // > 1500 ms with no resolution: pedal. Drop stability hard. The
    // brain transitions to BrainStatus.pedal — hold the current drone
    // root, drop the pad to root+fifth only.
    return current.copyWith(
      tonalStability: 0.15,
    );
  }

  // ─── Internal: key resolution ──────────────────────────────────

  (int, Scale) _resolveWorkingKey(AnalysisFrame frame, AppState app) {
    switch (app.mode) {
      case AppMode.manual:
        return (app.manualKeyPc, app.manualScale);

      case AppMode.progression:
        final step = app.progression.current; // never null (bug #20)
        return (step.rootPc, _scaleForChordQuality(step.quality));

      case AppMode.listen:
      case AppMode.harmonize:
        if (frame.keyCandidates.isNotEmpty) {
          final top = frame.keyCandidates.first;
          if (top.$3 > _minKeyScore) return (top.$1, top.$2);
        }
        return (_committedKeyPc, _committedScale);
    }
  }

  /// Only commit to a new key after N consecutive consistent
  /// observations.
  (int, Scale) _smoothKeyChange((int, Scale) candidate) {
    _keyHistory.add(
        _KeyObservation(candidate.$1, candidate.$2, DateTime.now()));
    if (_keyHistory.length > _keyHistoryCap) _keyHistory.removeAt(0);

    // Already committed to this candidate?
    if (candidate.$1 == _committedKeyPc &&
        candidate.$2.name == _committedScale.name) {
      return candidate;
    }

    // Count trailing run of same-key observations.
    int consecutive = 0;
    for (int i = _keyHistory.length - 1; i >= 0; i--) {
      final obs = _keyHistory[i];
      if (obs.rootPc == candidate.$1 &&
          obs.scale.name == candidate.$2.name) {
        consecutive++;
      } else {
        break;
      }
    }

    if (consecutive >= _stableObservations) {
      _committedKeyPc = candidate.$1;
      _committedScale = candidate.$2;
      _committedAt = DateTime.now();
      return candidate;
    }

    return (_committedKeyPc, _committedScale);
  }

  /// Find a nearby key that contains the out-of-context pitch class.
  /// Searches in order of musical distance: parallel, relative,
  /// subdominant, dominant, then relative of sub/dom.
  (int, Scale)? _findAlternateKeyContaining(int pitchClass) {
    final root = _committedKeyPc;
    final isMinor = _committedScale == kNatMinor ||
        _committedScale == kHarmMinor;

    final candidates = <(int, Scale)>[
      // Parallel mode
      (root, isMinor ? kMajor : kNatMinor),
      // Relative major/minor
      ((root + (isMinor ? 3 : 9)) % 12, isMinor ? kMajor : kNatMinor),
      // Subdominant (same mode)
      ((root + 5) % 12, _committedScale),
      // Dominant (same mode)
      ((root + 7) % 12, _committedScale),
      // Subdominant relative
      ((root + 5 + (isMinor ? 3 : 9)) % 12, isMinor ? kMajor : kNatMinor),
      // Dominant relative
      ((root + 7 + (isMinor ? 3 : 9)) % 12, isMinor ? kMajor : kNatMinor),
    ];

    for (final (r, s) in candidates) {
      if (s.pitchClassesFor(r).contains(pitchClass)) return (r, s);
    }
    return null;
  }

  // ─── Internal: chord selection ─────────────────────────────────

  Chord _pickChord(List<double> chroma, int keyPc, Scale scale) {
    Chord best = Chord(keyPc, ChordQuality.maj);
    double bestScore = -1e9;
    final scalePcs = scale.pitchClassesFor(keyPc);

    for (final rootPc in scalePcs) {
      for (final quality in ChordQuality.values) {
        final chord = Chord(rootPc, quality);
        double score = 0.0;

        // Chroma energy over the chord's pitch classes.
        for (final pc in chord.pitchClasses()) {
          score += chroma[pc];
        }

        // Penalty for chord tones outside the scale.
        for (final pc in chord.pitchClasses()) {
          if (!scalePcs.contains(pc)) score -= 0.4;
        }

        // Prior: prefer tonic, subdominant, dominant.
        if (rootPc == keyPc) score += 0.20;
        if ((rootPc - keyPc + 12) % 12 == 5) score += 0.12;
        if ((rootPc - keyPc + 12) % 12 == 7) score += 0.12;

        // Prior: mild preference for triads over 7ths.
        if (quality == ChordQuality.maj || quality == ChordQuality.min) {
          score += 0.08;
        }

        if (score > bestScore) {
          bestScore = score;
          best = chord;
        }
      }
    }
    return best;
  }

  // ─── Internal: voicing ─────────────────────────────────────────

  List<int> _voiceLeadPad(Chord chord, List<int> previous) {
    final chordPcs = chord.pitchClasses();
    final result = <int>[];

    for (int i = 0; i < chordPcs.length; i++) {
      final pc = chordPcs[i];
      final target = i < previous.length ? previous[i] : 60 + pc;

      int bestMidi = 60 + pc;
      int bestDist = 1 << 20;
      for (int m = 55; m <= 75; m++) {
        if (m % 12 != pc) continue;
        final d = (m - target).abs();
        if (d < bestDist) {
          bestDist = d;
          bestMidi = m;
        }
      }
      result.add(bestMidi);
    }
    result.sort();
    return result;
  }

  List<int> _seedVoicing(int keyPc, Scale scale) {
    final pcs = scale.pitchClassesFor(keyPc).toList()..sort();
    final result = <int>[];
    for (int i = 0; i < 3 && i < pcs.length; i++) {
      int midi = 60 + pcs[i];
      while (midi > 75) midi -= 12;
      while (midi < 55) midi += 12;
      result.add(midi);
    }
    if (result.isEmpty) result.add(60);
    result.sort();
    return result;
  }

  int _bassMidiFor(int rootPc) => 48 + (rootPc % 12);

  // ─── Internal: quality → scale ─────────────────────────────────

  Scale _scaleForChordQuality(ChordQuality quality) {
    switch (quality) {
      case ChordQuality.maj:
      case ChordQuality.maj7:
      case ChordQuality.sus2:
      case ChordQuality.sus4:
        return kMajor;
      case ChordQuality.min:
      case ChordQuality.min7:
        return kNatMinor;
      case ChordQuality.dom7:
        return kMixolydian;
      case ChordQuality.dim:
      case ChordQuality.min7b5:
        return kLocrian;
      case ChordQuality.aug:
        return kWholeTone;
    }
  }

  // ─── Internal: stability ───────────────────────────────────────

  double _computeTonalStability(
      AnalysisFrame frame, (int, Scale) working) {
    if (frame.keyCandidates.isEmpty) return 0.5;
    final top = frame.keyCandidates.first;
    if (top.$1 == working.$1 && top.$2.name == working.$2.name) {
      return top.$3.clamp(0.0, 1.0);
    }
    return (top.$3 * 0.6).clamp(0.0, 1.0);
  }
}

// ─── Support type ──────────────────────────────────────────────────

class _KeyObservation {
  final int rootPc;
  final Scale scale;
  final DateTime at;
  _KeyObservation(this.rootPc, this.scale, this.at);
}