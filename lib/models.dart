// lib/models.dart — §5 data models (with build fixes; see DEVIATIONS.md)
import 'dart:math';

const kPitchNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
String pitchName(int pc) => kPitchNames[((pc % 12) + 12) % 12];

class Scale {
  final String name;
  final List<int> intervals;
  const Scale(this.name, this.intervals);
  Set<int> pitchClassesFor(int rootPc) =>
      intervals.map((i) => (rootPc + i) % 12).toSet();
  bool contains(int rootPc, int pc) => pitchClassesFor(rootPc).contains(pc % 12);
}

const kMajor = Scale('Major', [0, 2, 4, 5, 7, 9, 11]);
const kNatMinor = Scale('Natural Minor', [0, 2, 3, 5, 7, 8, 10]);
const kHarmMinor = Scale('Harmonic Minor', [0, 2, 3, 5, 7, 8, 11]);
const kDorian = Scale('Dorian', [0, 2, 3, 5, 7, 9, 10]);
const kPhrygian = Scale('Phrygian', [0, 1, 3, 5, 7, 8, 10]);
const kLydian = Scale('Lydian', [0, 2, 4, 6, 7, 9, 11]);
const kMixolydian = Scale('Mixolydian', [0, 2, 4, 5, 7, 9, 10]);
const kLocrian = Scale('Locrian', [0, 1, 3, 5, 6, 8, 10]);
const kPentaMaj = Scale('Pentatonic Major', [0, 2, 4, 7, 9]);
const kPentaMin = Scale('Pentatonic Minor', [0, 3, 5, 7, 10]);
const kBlues = Scale('Blues', [0, 3, 5, 6, 7, 10]);
const kWholeTone = Scale('Whole Tone', [0, 2, 4, 6, 8, 10]);
const kAllScales = [
  kMajor, kNatMinor, kHarmMinor, kDorian, kPhrygian, kLydian,
  kMixolydian, kLocrian, kPentaMaj, kPentaMin, kBlues, kWholeTone,
];

enum ChordQuality { maj, min, dim, aug, maj7, min7, dom7, sus2, sus4, min7b5 }

const kChordIntervals = <ChordQuality, List<int>>{
  ChordQuality.maj: [0, 4, 7],
  ChordQuality.min: [0, 3, 7],
  ChordQuality.dim: [0, 3, 6],
  ChordQuality.aug: [0, 4, 8],
  ChordQuality.maj7: [0, 4, 7, 11],
  ChordQuality.min7: [0, 3, 7, 10],
  ChordQuality.dom7: [0, 4, 7, 10],
  ChordQuality.sus2: [0, 2, 7],
  ChordQuality.sus4: [0, 5, 7],
  ChordQuality.min7b5: [0, 3, 6, 10],
};

const _kQualitySuffix = <ChordQuality, String>{
  ChordQuality.maj: '',
  ChordQuality.min: 'm',
  ChordQuality.dim: 'dim',
  ChordQuality.aug: 'aug',
  ChordQuality.maj7: 'maj7',
  ChordQuality.min7: 'm7',
  ChordQuality.dom7: '7',
  ChordQuality.sus2: 'sus2',
  ChordQuality.sus4: 'sus4',
  ChordQuality.min7b5: 'm7b5',
};

class Chord {
  final int rootPc;
  final ChordQuality quality;
  const Chord(this.rootPc, this.quality);
  List<int> pitchClasses() =>
      kChordIntervals[quality]!.map((i) => (rootPc + i) % 12).toList();
  String symbol() => '${pitchName(rootPc)}${_kQualitySuffix[quality]}';

  @override
  bool operator ==(Object other) =>
      other is Chord && other.rootPc == rootPc && other.quality == quality;
  @override
  int get hashCode => Object.hash(rootPc, quality);
}

class ProgressionStep {
  final Chord chord;
  final int triggerPc;
  const ProgressionStep(this.chord, this.triggerPc);
}

class ChordProgression {
  final List<ProgressionStep> steps;
  int cursor = 0;
  ChordProgression([List<ProgressionStep>? s])
      : steps = s ?? <ProgressionStep>[]; // bug #10

  /// Bug #20: never null — an empty progression yields C major.
  Chord get current => steps.isEmpty
      ? const Chord(0, ChordQuality.maj)
      : steps[cursor % steps.length].chord;

  bool tryAdvance(int pc) {
    if (steps.isEmpty) return false;
    if (steps[cursor % steps.length].triggerPc == pc) {
      cursor = (cursor + 1) % steps.length;
      return true;
    }
    return false;
  }

  Map<String, dynamic> toJson() => {
        'cursor': cursor,
        'steps': steps
            .map((s) => {
                  'r': s.chord.rootPc,
                  'q': s.chord.quality.index,
                  't': s.triggerPc,
                })
            .toList(),
      };

  static ChordProgression fromJson(Map<String, dynamic> j) {
    final c = ChordProgression((j['steps'] as List)
        .map((e) => ProgressionStep(
              Chord(e['r'] as int, ChordQuality.values[e['q'] as int]),
              e['t'] as int,
            ))
        .toList());
    final cur = (j['cursor'] as int?) ?? 0;
    c.cursor = c.steps.isEmpty ? 0 : cur % c.steps.length; // bug #9 clamp
    return c;
  }
}

class DetectedNote {
  final int pitchClass, midi;
  final double strength;
  const DetectedNote(this.pitchClass, this.midi, this.strength);
}

class AnalysisFrame {
  final List<double> chroma;
  final double? pitchHz;
  final double pitchConfidence, onsetStrength, percussiveOnset,
      percussiveConfidence, lowBandFlux;
  final double? tempoBpm;
  final List<(int, Scale, double)> keyCandidates;
  final double rmsLevel;
  final bool silent;
  final List<DetectedNote> detectedNotes;
  final List<double> rhythmPattern;
  final bool beatLocked;
  final double? beatPhase01;
  final double analysisConfidence;
  final DateTime timestamp;
  const AnalysisFrame({
    required this.chroma,
    required this.pitchHz,
    required this.pitchConfidence,
    required this.onsetStrength,
    required this.percussiveOnset,
    required this.percussiveConfidence,
    required this.lowBandFlux,
    required this.tempoBpm,
    required this.keyCandidates,
    required this.rmsLevel,
    required this.silent,
    required this.detectedNotes,
    required this.rhythmPattern,
    required this.beatLocked,
    required this.beatPhase01,
    required this.analysisConfidence,
    required this.timestamp,
  });
}

class RhythmHit {
  final double timeInBeats;
  final int pitchPc;
  final double velocity;
  const RhythmHit(this.timeInBeats, this.pitchPc, this.velocity);
}

class HarmonyEvent {
  final int pitchMidi;
  final double velocity;
  final Duration delay;
  final Duration glideDuration;
  final int? glideToMidi;
  const HarmonyEvent({
    required this.pitchMidi,
    required this.velocity,
    this.delay = Duration.zero,
    this.glideDuration = Duration.zero,
    this.glideToMidi,
  });
}

class MusicalState {
  final int keyPc;
  final Scale scale;
  final Chord? chord;
  final int droneRootPc;
  final List<int> padPcs;

  /// Absolute MIDI pad voicing from the language (voice-led). The synth
  /// uses this when present so the language's voice-leading is audible.
  final List<int> padMidi;
  final List<RhythmHit> rhythmSchedule;
  final List<String> textureIds;
  final List<HarmonyEvent> harmonySchedule;
  final Map<String, double> intensity;
  final bool silent;
  final String languageLabel;
  final String worldId;
  const MusicalState({
    required this.keyPc,
    required this.scale,
    required this.chord,
    required this.droneRootPc,
    required this.padPcs,
    this.padMidi = const [],
    required this.rhythmSchedule,
    required this.textureIds,
    required this.harmonySchedule,
    required this.intensity,
    required this.silent,
    required this.languageLabel,
    required this.worldId,
  });
}

enum SpatialFilterPreset { front, back, side, elevated, none }

enum AntiphonalPattern { alternate, callResponse, circular, wave, pingPong, cluster }

class ChannelTarget {
  final List<double> weights;
  final double fadeSeconds;
  final SpatialFilterPreset? filter;
  const ChannelTarget(this.weights, {this.fadeSeconds = 0.3, this.filter});
}

/// Angles in degrees: 0 = front, 90 = right, 180 = back, 270 = left.
class VoiceSpatialRole {
  final double anchorAngle, callAngle, responseAngle;
  const VoiceSpatialRole({
    required this.anchorAngle,
    required this.callAngle,
    required this.responseAngle,
  });
  static const centered =
      VoiceSpatialRole(anchorAngle: 0, callAngle: 0, responseAngle: 0);
  static const front =
      VoiceSpatialRole(anchorAngle: 0, callAngle: 0, responseAngle: 180);
  static const left =
      VoiceSpatialRole(anchorAngle: 270, callAngle: 270, responseAngle: 90);
  static const right =
      VoiceSpatialRole(anchorAngle: 90, callAngle: 90, responseAngle: 270);
  static const back =
      VoiceSpatialRole(anchorAngle: 180, callAngle: 180, responseAngle: 0);
  static const opposite =
      VoiceSpatialRole(anchorAngle: 180, callAngle: 180, responseAngle: 0);
}

enum NoteEventType { on, off, cc, pitchBend }

class NoteEvent {
  final NoteEventType type;
  final String layerId;
  final int midiNote;
  final double velocity;
  final DateTime timestamp;
  final int channel;
  final int? cc;
  final double? ccValue;
  const NoteEvent({
    required this.type,
    required this.layerId,
    required this.midiNote,
    required this.velocity,
    required this.timestamp,
    required this.channel,
    this.cc,
    this.ccValue,
  });
}

enum AppMode { listen, harmonize, manual, progression }

enum BrainStatus { idle, listening, stable, modulating, pedal }

enum CouplingMode { openAir, direct }

enum HarmonizerMode { predictive, canon, trailing, phrase, aestheticSilence }

enum HarmonyInterval { diatonic3, diatonic6, diatonic5, parallel5, parallel4, octave, triad }

enum HarmonyTimbre { organ, pluck }

int? pitchClassFromHz(double hz) {
  if (hz <= 0) return null;
  return (((69 + 12 * (log(hz / 440) / ln2)).round() % 12) + 12) % 12;
}

int midiFromHz(double hz) =>
    (69 + 12 * (log(hz / 440) / ln2)).round().clamp(0, 127);

double hzFromMidi(num midi) => 440.0 * pow(2, (midi - 69) / 12).toDouble();
