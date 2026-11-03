// lib/harmonic_language.dart
//
// HarmonicLanguage — the pitch-decision abstraction.
//
// The brain delegates all "what notes to play" logic to a language.
// Everything that is NOT pitch (rhythm scheduling, spatial assignment,
// harmonizer mode selection) stays in the brain. This boundary is
// deliberate: it lets the same sound world pair with any language
// without retraining the world, and lets a new language drop in
// without touching the brain or the synth.

import 'models.dart';
import 'state.dart';
import 'tonal_language.dart';

// ─── HarmonicContext ────────────────────────────────────────────────
//
// The output of one language.update() call. Immutable. Contains both
// the pitches to play and the language-specific state to hand back on
// the next call (row form, mode, collection, etc.).
//
// The brain reads padPitchesMidi, bassPitchesMidi, and currentChord to
// build the MusicalState. harmonyPitchesMidi is only consumed by the
// harmonizer world (see brain.dart §11.1). The `data` map is the
// language's private scratchpad — no other subsystem reads it.

class HarmonicContext {
  /// Language-specific state carried across frames.
  ///
  /// Examples:
  ///   Tonal:       {'detectedKeyPc': 2, 'detectedScale': kDorian}
  ///   Renaissance: {'finalPc': 2, 'mode': 'dorian', 'lastVoicing': [...]}
  ///   Atonal:      {'row': [4,5,7,...], 'form': 'P', 'position': 3}
  ///   Stravinsky:  {'collection': 'octatonic_hw', 'chordIdx': 2,
  ///                 'setAt': DateTime}
  ///
  /// Never read by anything except the language itself.
  final Map<String, dynamic> data;

  /// The current chord, if the language has one. Tonal and Renaissance
  /// produce chords; Atonal and Stravinsky may leave this null (they
  /// work in pitch-class sets, not chord symbols).
  final Chord? currentChord;

  /// Pad pitches as absolute MIDI notes. The synth assigns one pad
  /// voice per entry, voice-led within each voice's range.
  /// Empty list = no pad this frame.
  final List<int> padPitchesMidi;

  /// Bass pitches as absolute MIDI. Usually one note. The drone voice
  /// plays the first entry; additional entries are available for
  /// worlds that use a multi-note bass.
  final List<int> bassPitchesMidi;

  /// Harmony pitches for the harmonizer world only. Ignored when the
  /// current sound world is not `parallel_chords`.
  final List<int> harmonyPitchesMidi;

  /// 0..1 — how confident the language is in the current tonal center.
  /// Used by the brain to weight modulation decisions. Tonal and
  /// Renaissance set this from key-detection confidence; Atonal and
  /// Stravinsky generally leave it at 1.0 (they don't have a tonal
  /// center to be uncertain about).
  final double tonalStability;

  /// Human-readable label for the status pill.
  /// Examples: "C Major", "D Dorian", "P₃ strict", "E♭ oct-HW".
  /// Must be non-null; the brain falls back to "—" if a language
  /// returns an empty string.
  final String displayLabel;

  const HarmonicContext({
    this.data = const {},
    this.currentChord,
    this.padPitchesMidi = const [],
    this.bassPitchesMidi = const [],
    this.harmonyPitchesMidi = const [],
    this.tonalStability = 1.0,
    required this.displayLabel,
  });

  /// Copy-with helper. Languages that only modify one or two fields
  /// per frame use this instead of reconstructing the whole context.
  HarmonicContext copyWith({
    Map<String, dynamic>? data,
    Chord? currentChord,
    List<int>? padPitchesMidi,
    List<int>? bassPitchesMidi,
    List<int>? harmonyPitchesMidi,
    double? tonalStability,
    String? displayLabel,
    bool clearChord = false,
  }) {
    return HarmonicContext(
      data: data ?? this.data,
      currentChord: clearChord ? null : (currentChord ?? this.currentChord),
      padPitchesMidi: padPitchesMidi ?? this.padPitchesMidi,
      bassPitchesMidi: bassPitchesMidi ?? this.bassPitchesMidi,
      harmonyPitchesMidi: harmonyPitchesMidi ?? this.harmonyPitchesMidi,
      tonalStability: tonalStability ?? this.tonalStability,
      displayLabel: displayLabel ?? this.displayLabel,
    );
  }
}

// ─── LanguageUIElement ──────────────────────────────────────────────
//
// Describes one control the UI should render for this language.
// Tonal returns 2 (key + scale). Stravinsky returns 2 (collection +
// stability). Atonal returns 2 (row + mode). Renaissance returns 2
// (final + mode).
//
// The UI iterates `language.uiElements` and renders a control per
// element, writing the chosen value back to AppState via the
// `AppState` field named in `stateFieldKey`.

enum UIElementType {
  /// Dropdown with string options. `currentValue` is the selected
  /// option string, and `stateFieldKey` points to the AppState
  /// string field that stores it.
  dropdown,

  /// Dropdown with integer options (e.g. key root 0..11, position
  /// 0..11). `currentValue` is the selected int.
  dropdownInt,

  /// Radio button group. Same storage as dropdown.
  radio,

  /// Slider 0..1. `currentValue` is a double.
  slider,
}

class LanguageUIElement {
  /// Stable identifier — used by the UI to key its widget tree.
  final String key;

  /// Human-readable label shown to the user.
  final String label;

  final UIElementType type;

  /// Options as (displayLabel, value) pairs. Empty for sliders.
  /// For dropdownInt, value is an int. For dropdown/radio, a String.
  final List<(String, dynamic)> options;

  /// The currently-selected value. Read from AppState by the language.
  final dynamic currentValue;

  /// The AppState field this element writes to, so the UI can update
  /// the correct state when the user changes the value.
  ///
  /// Examples: 'manualKeyPc', 'manualScale', 'stravinskyCollection',
  /// 'atonalRowId', 'renaissanceFinalPc'.
  ///
  /// The UI is expected to have a setter map from these keys to
  /// AppState methods. Unknown keys log a warning and render read-only.
  final String stateFieldKey;

  const LanguageUIElement({
    required this.key,
    required this.label,
    required this.type,
    required this.options,
    required this.currentValue,
    required this.stateFieldKey,
  });
}

// ─── HarmonicLanguage ───────────────────────────────────────────────

abstract class HarmonicLanguage {
  /// Stable identifier used in AppState.harmonicLanguageId and in the
  /// combined-preset table. Must be unique across all implementations.
  String get id;

  /// Display name shown in the language dropdown.
  String get name;

  /// One-line description shown in the UI when this language is
  /// selected. E.g. "Modal counterpoint, 1450–1600."
  String get description;

  /// Controls to show in the Harmonic Language row of the UI. May be
  /// empty (a language with no user-tunable params).
  List<LanguageUIElement> get uiElements;

  /// Initial context for a session. Called once when the language is
  /// first selected, and again after any reset. Not called per frame.
  /// Must NOT depend on any frame data — it's a fresh-start seed.
  HarmonicContext init(AppState app);

  /// Per-frame decision. Called by the brain once per audio frame.
  ///
  /// The language may read `frame.chroma`, `frame.keyCandidates`,
  /// `frame.pitchHz`, `frame.detectedNotes`, `frame.tempoBpm`, etc. to
  /// inform its decision. It may read `app.manualKeyPc`, `app.mode`,
  /// and any language-specific AppState fields.
  ///
  /// The language MUST return a new context (never null). If nothing
  /// changed this frame, it may return `current` unchanged.
  HarmonicContext update(
    HarmonicContext current,
    AnalysisFrame frame,
    AppState app,
  );

  /// Called by the brain when it detects a sustained out-of-context
  /// note (a pitch class outside the current key/collection/row for
  /// >350 ms). The language decides whether to:
  ///   - ignore it (passing tone — return `current` unchanged),
  ///   - modulate (return a new context with a different key/scale),
  ///   - transpose the collection (Stravinsky), or
  ///   - shift the row form (Atonal).
  ///
  /// The brain crossfades between old and new contexts over 2 s. The
  /// language does not need to manage the crossfade itself.
  HarmonicContext handleOutOfContextNote(
    HarmonicContext current,
    int pitchClass,
    Duration sustainedFor,
    AppState app,
  );
}

// ─── Language registry ──────────────────────────────────────────────
//
// Single point of construction. AudioEngine and the UI both resolve
// languages through this function so behavior is identical.

/// Construct the language for a given id. Phase 1 ships Tonal only;
/// other ids fall back to Tonal until §12.3–§12.5 land (Phase 3).
HarmonicLanguage languageById(String id) {
  switch (id) {
    case 'tonal':
    default:
      return TonalLanguage();
  }
}

/// Language ids selectable in the current phase.
const kAvailableLanguageIds = <String>['tonal'];
