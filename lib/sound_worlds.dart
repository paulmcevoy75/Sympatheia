// lib/sound_worlds.dart — §11.2 types + §11.3 worlds (all 17)
//
// Types for sound-world data. All types are const-constructible so the
// 17 world definitions in §11.3 are compile-time constants — zero
// runtime allocation, no GC pressure for world data.

import 'models.dart';

// ─── Voice description ──────────────────────────────────────────────

enum SourceType {
  sine,
  saw,
  tri,
  square,
  formant,
  fm,
  granular,
  noise,
  pluck,
  brass,
}

enum NoiseColor { pink, white, brown }

class Formant {
  final double f1, f2, f3;
  final double bwHz; // shared bandwidth for all three
  const Formant(this.f1, this.f2, this.f3, {this.bwHz = 100});
}

/// One voice in a sound world's voice list. Each `VoiceSpec` describes
/// a single source, its envelope, its pitch-track rule, and its
/// register. The synth engine instantiates `count` copies of each spec.
class VoiceSpec {
  final String layer; // 'drone', 'pad', 'rhythm', 'texture', 'harmony', 'bass'
  final int count;
  final SourceType source;
  final List<int> rangeMidi;

  // Envelope (milliseconds)
  final double attackMs;
  final double releaseMs;

  // Vibrato (per-voice)
  final double vibratoRateHz;
  final double vibratoCents;

  // Detune between voices of this spec (cents)
  final double detuneCents;

  // Formant source parameters
  final List<Formant>? formants;

  // FM source parameters
  final double? fmIndex;
  final double? fmRatio;

  // Granular source parameters
  final double? grainMs;
  final double? grainDensity;

  // Noise source parameters
  final NoiseColor? noiseColor;
  final double? noiseQ; // for bandpass noise

  const VoiceSpec({
    required this.layer,
    required this.count,
    required this.source,
    required this.rangeMidi,
    required this.attackMs,
    required this.releaseMs,
    this.vibratoRateHz = 0,
    this.vibratoCents = 0,
    this.detuneCents = 0,
    this.formants,
    this.fmIndex,
    this.fmRatio,
    this.grainMs,
    this.grainDensity,
    this.noiseColor,
    this.noiseQ,
  });
}

// ─── Effect description ─────────────────────────────────────────────

enum EffectType {
  reverb,
  chorus,
  phaser,
  delay,
  lowpass,
  highpass,
  saturation,
  highShelf,
}

class EffectSpec {
  final EffectType type;
  final Map<String, double> params;
  const EffectSpec(this.type, this.params);
}

// ─── Rhythm character ───────────────────────────────────────────────

enum RhythmType {
  none,
  pluck,
  woodblock,
  cajon,
  palmas,
  brass,
}

class RhythmCharacter {
  final RhythmType type;
  final double density; // 0..1 — higher = more hits per bar
  const RhythmCharacter(this.type, {this.density = 0.5});
}

// ─── Spatial character ──────────────────────────────────────────────

class SpatialSpec {
  final AntiphonalPattern defaultPattern;
  final double defaultIntensity; // 0..1
  final double movementCycleSeconds; // for circular / wave

  final VoiceSpatialRole droneRole;
  final VoiceSpatialRole padRootRole;
  final VoiceSpatialRole rhythmRole;
  final VoiceSpatialRole textureRole;
  final List<VoiceSpatialRole> padColorRoles;

  const SpatialSpec({
    required this.defaultPattern,
    required this.defaultIntensity,
    required this.movementCycleSeconds,
    required this.droneRole,
    required this.padRootRole,
    required this.rhythmRole,
    required this.textureRole,
    required this.padColorRoles,
  });
}

// ─── Harmony character (only used by harmonizer world + choirs) ────

class HarmonyConfig {
  final String? preferredLanguage;
  final List<String>? vowelCycle; // for choir worlds
  const HarmonyConfig({this.preferredLanguage, this.vowelCycle});
}

// ─── The world ──────────────────────────────────────────────────────

class SoundWorld {
  final String id;
  final String name;
  final String description;
  final List<VoiceSpec> voices;
  final List<EffectSpec> effects;
  final RhythmCharacter rhythm;
  final SpatialSpec spatial;
  final HarmonyConfig? harmony;

  const SoundWorld({
    required this.id,
    required this.name,
    required this.description,
    required this.voices,
    required this.effects,
    required this.rhythm,
    required this.spatial,
    this.harmony,
  });
}

// ─── tame_impala_fan ───────────────────────────────────────────────
//
// Warm analog psychedelic. Saw drone pair low-passed at 800 Hz, saw
// pad through chorus + phaser + light tape wow, gentle saturation.
// Two-octave spread — drone sits low, pad sits mid. The "hello pad"
// voicing at launch is deliberately close to this so the transition
// from startup to the brain is nearly invisible.
//
// Voices:
//   drone:  two detuned saws (±6 cents), one per root octave
//   pad:    four saw voices, ±4 cents detune, voice-led in the chord
//
// Effects: LP 800 (drone), chorus, phaser, saturation, reverb
//
// Rhythm: plucks on chord tones, moderate density
//
// Spatial: ping-pong. The pad root sits front, rhythm hits alternate
// L/R on the beat (once beat lock engages). At intensity 0.7 the
// effect is clearly ping-pong without being gimmicky.

final tameImpalaFan = SoundWorld(
  id: 'tame_impala_fan',
  name: 'Tame Impala Fan',
  description: 'Warm analog psych. Chorused, phasing, gently saturated.',
  voices: const [
    // Drone: two saws an octave apart, detuned for beating
    VoiceSpec(
      layer: 'drone',
      count: 2,
      source: SourceType.saw,
      rangeMidi: [43, 55], // G2–G3
      attackMs: 800,
      releaseMs: 1500,
      detuneCents: 6,
    ),
    // Pad: four saws in the mid register, voice-led through chords
    VoiceSpec(
      layer: 'pad',
      count: 4,
      source: SourceType.saw,
      rangeMidi: [55, 75], // G3–D5
      attackMs: 600,
      releaseMs: 1200,
      detuneCents: 4,
    ),
  ],
  effects: const [
    // Drone chain: heavy LP
    EffectSpec(EffectType.lowpass, {'cutoffHz': 800, 'resonance': 0.7}),
    // Pad chain: chorus + phaser + wow
    EffectSpec(EffectType.chorus, {'rateHz': 0.4, 'depthMs': 8}),
    EffectSpec(EffectType.phaser, {'rateHz': 0.08, 'stages': 4}),
    // Global saturation
    EffectSpec(EffectType.saturation, {'drive': 2.0}),
    // Global reverb
    EffectSpec(EffectType.reverb, {'room': 0.75, 'wet': 0.4, 'damp': 0.3}),
  ],
  rhythm: const RhythmCharacter(RhythmType.pluck, density: 0.6),
  spatial: const SpatialSpec(
    defaultPattern: AntiphonalPattern.pingPong,
    defaultIntensity: 0.7,
    movementCycleSeconds: 0, // ping-pong doesn't use a cycle
    droneRole: VoiceSpatialRole.centered,
    padRootRole: VoiceSpatialRole.front,
    rhythmRole: VoiceSpatialRole.left,
    textureRole: VoiceSpatialRole.centered,
    padColorRoles: [],
  ),
);

// ─── washy_reverb ──────────────────────────────────────────────────
//
// Reverb as instrument. Almost everything you hear IS the reverb
// tail. The dry signal is deliberately quiet (soft sine drone, brief
// triangle pad) and Freeverb at room 0.98 / wet 0.85 dominates the
// output. When the pad changes chord, you hear the *transition*
// more than the new chord — the old tail bleeds into the new wash.
//
// This world exists to stress-test three things:
//   1. The reverb chain (a long, bright Freeverb)
//   2. Voice release timing (10 s release on the pad — voices live
//      long enough that the ceiling enforcement matters)
//   3. AEC (the mic hears a wall of sustained reverb — the FIR has
//      to fit against broadband, non-transient content)
//
// Voices:
//   drone: one soft sine (gain 0.15 effective — see intensity map)
//   pad:   three triangle voices, very slow envelope (6 s attack)
//
// Effects: Freeverb at 0.98 room, 0.85 wet, damp 0.3
//
// Rhythm: sparse plucks, dry 0.1 / wet 0.9 (the pluck is the tail)
//
// Spatial: wave. Voices sweep front↔back over 12 s. Circular/alternate
// would be too "motion-y" for a wash — wave is the right gesture.

final washyReverb = SoundWorld(
  id: 'washy_reverb',
  name: 'Washy Reverb',
  description: 'Almost entirely reverb. Space as an instrument.',
  voices: const [
    // Drone: single soft sine, very low level (the intensity slider
    // multiplies this; at default drone 0.45 the effective gain is
    // ~0.07 — the point is presence, not volume)
    VoiceSpec(
      layer: 'drone',
      count: 1,
      source: SourceType.sine,
      rangeMidi: [40, 45], // E2–A2
      attackMs: 2000,
      releaseMs: 4000,
    ),
    // Pad: three triangles, extremely long envelopes. The attack is
    // 6 s — the chord doesn't "arrive" so much as slowly emerge
    // through the reverb.
    VoiceSpec(
      layer: 'pad',
      count: 3,
      source: SourceType.tri,
      rangeMidi: [60, 72], // C4–C5
      attackMs: 6000,
      releaseMs: 10000,
    ),
  ],
  effects: const [
    EffectSpec(EffectType.reverb, {'room': 0.98, 'wet': 0.85, 'damp': 0.3}),
  ],
  rhythm: const RhythmCharacter(RhythmType.pluck, density: 0.2),
  spatial: const SpatialSpec(
    defaultPattern: AntiphonalPattern.wave,
    defaultIntensity: 0.75,
    movementCycleSeconds: 12,
    droneRole: VoiceSpatialRole.centered,
    padRootRole: VoiceSpatialRole.front,
    rhythmRole: VoiceSpatialRole.centered,
    textureRole: VoiceSpatialRole.centered,
    padColorRoles: [],
  ),
);

// ─── earth_singing ─────────────────────────────────────────────────
//
// Subsonic, planetary, slow. The defining trick: formant voices tuned
// to female pitch (250/500/900 Hz) but pitched down two octaves into
// the bass-baritone register. Result is a "giant female chorus"
// effect — the fundamental is low but the timbre is unmistakably a
// woman's voice. Combined with two sine drones at the very bottom of
// the audible range (C1–E1) and a heavily-LP'd pink noise bed.
//
// The pink noise HP 20 / LP 300 Q 2 is doing double duty: it fills
// out the sub-bass region so the effect doesn't collapse on speakers
// that can't reproduce below 60 Hz. Even on a laptop, you hear the
// planet.
//
// Voices:
//   drone:   two sines, root and fifth, sub-register (MIDI 24–28)
//   pad:     four formant voices at MIDI 40–52 with female formants
//   texture: pink noise through LP 300 Hz — the "planet bed"
//
// Reverb 0.95 room / 0.55 wet — cathedral-of-the-universe space.
//
// Circular spatial over 45 s — slow planetary rotation. Voices drift
// around the virtual ring and take 45 s to complete an orbit. This is
// the slowest spatial cycle of any world.

final earthSinging = SoundWorld(
  id: 'earth_singing',
  name: 'Earth Singing',
  description: 'Subsonic, planetary, slow.',
  voices: const [
    // Two sine drones at root + fifth, sub-register
    VoiceSpec(
      layer: 'drone',
      count: 2,
      source: SourceType.sine,
      rangeMidi: [24, 28], // C1–E1
      attackMs: 3000,
      releaseMs: 6000,
    ),
    // Four formant pad voices — female formants at bass pitch
    VoiceSpec(
      layer: 'pad',
      count: 4,
      source: SourceType.formant,
      rangeMidi: [40, 52], // E2–E3
      attackMs: 4000,
      releaseMs: 8000,
      vibratoRateHz: 3,
      vibratoCents: 4,
      detuneCents: 8,
      formants: [Formant(250, 500, 900)],
    ),
    // Pink noise texture — the "planet bed"
    VoiceSpec(
      layer: 'texture',
      count: 1,
      source: SourceType.noise,
      rangeMidi: [40, 40], // unused for noise
      attackMs: 6000,
      releaseMs: 8000,
      noiseColor: NoiseColor.pink,
      noiseQ: 2.0, // broad LP
    ),
  ],
  effects: const [
    // Broad LP on the whole chain — everything is filtered dark
    EffectSpec(EffectType.lowpass, {'cutoffHz': 300, 'resonance': 2.0}),
    // HPF removes DC and infrasonic rumble below the audible range
    EffectSpec(EffectType.highpass, {'cutoffHz': 20, 'resonance': 0.7}),
    EffectSpec(EffectType.reverb, {'room': 0.95, 'wet': 0.55, 'damp': 0.3}),
  ],
  rhythm: const RhythmCharacter(RhythmType.none),
  spatial: const SpatialSpec(
    defaultPattern: AntiphonalPattern.circular,
    defaultIntensity: 0.6,
    movementCycleSeconds: 45,
    droneRole: VoiceSpatialRole.centered,
    padRootRole: VoiceSpatialRole.front,
    rhythmRole: VoiceSpatialRole.centered,
    textureRole: VoiceSpatialRole.centered,
    padColorRoles: [],
  ),
);

// ─── eastern_european_choir ────────────────────────────────────────
//
// Village/Orthodox-inspired. Bright female voices on top, dark male
// voices below, parallel fifths throughout. The parallel fifth in the
// drone is the signature — the two bass voices are always a fifth
// apart regardless of what chord the pad is playing. This is
// characteristic of Balkan and Orthodox choral traditions (and would
// be "wrong" in Renaissance counterpoint; the world embraces it).
//
// Vibrato is heavy (5 Hz × 10 cents on the females), detune is wide,
// and the chorus effect lightly smears the ensemble. This is village
// choir, not cathedral choir — rougher, closer, more physical.
//
// Voices:
//   drone:   two male bass formant voices (root + parallel fifth)
//   pad:     three female formant voices in the upper register
//
// Reverb 0.7 room / 0.4 wet — church acoustic, not cathedral. The
// difference matters: cathedral reverb (0.9+) would blur the parallel
// fifths into mud. This reverb lets the fifth stay distinct.
//
// Call-response spatial over 2 s per cycle: two groups of voices
// alternate between "on" (full gain, front) and "off" (faded to 15%,
// opposite side). Characteristic of antiphonal liturgical singing.
// The pad sits on the left group, rhythm on the right — so the
// response is literally between melody and percussion.

final easternEuropeanChoir = SoundWorld(
  id: 'eastern_european_choir',
  name: 'Eastern European Choir',
  description: 'Village/Orthodox, bright female top, parallel fifths.',
  voices: const [
    // Two male bass formant voices — root and parallel fifth
    VoiceSpec(
      layer: 'drone',
      count: 2,
      source: SourceType.formant,
      rangeMidi: [40, 45], // E2–A2
      attackMs: 1200,
      releaseMs: 2000,
      vibratoRateHz: 4,
      vibratoCents: 6,
      detuneCents: 4,
      formants: [Formant(350, 700, 2200)],
    ),
    // Three female formant voices in the upper register
    VoiceSpec(
      layer: 'pad',
      count: 3,
      source: SourceType.formant,
      rangeMidi: [65, 74], // F4–D5
      attackMs: 800,
      releaseMs: 1500,
      vibratoRateHz: 5,
      vibratoCents: 10,
      detuneCents: 6,
      formants: [Formant(800, 1150, 2900)],
    ),
  ],
  effects: const [
    // Light chorus smears the ensemble
    EffectSpec(EffectType.chorus, {'rateHz': 0.3, 'depthMs': 5}),
    EffectSpec(EffectType.reverb, {'room': 0.7, 'wet': 0.4, 'damp': 0.3}),
  ],
  rhythm: const RhythmCharacter(RhythmType.pluck, density: 0.3),
  spatial: const SpatialSpec(
    defaultPattern: AntiphonalPattern.callResponse,
    defaultIntensity: 0.85,
    movementCycleSeconds: 2,
    droneRole: VoiceSpatialRole.centered,
    padRootRole: VoiceSpatialRole.left,
    rhythmRole: VoiceSpatialRole.right,
    textureRole: VoiceSpatialRole.centered,
    padColorRoles: [],
  ),
  harmony: const HarmonyConfig(
    preferredLanguage: 'renaissance',
    vowelCycle: ['ah', 'oh', 'eh'],
  ),
);

// ─── clumsy_kind_giant ─────────────────────────────────────────────
//
// Enormous, lumbering, tender. The "gentle monster" of the world
// list. Two heavy bass saws, detuned by ±10 cents (deliberate slight
// wrongness — the giant doesn't have perfect pitch), establish a
// rumbling low foundation. A triangle pad in the mid-register with a
// very slow attack and a subtle downward bend on the first second of
// each note gives it the "groan" quality — as if the sound is settling
// under its own weight.
//
// Rhythmic elements use a pluck with heavy LP — it reads as a wood
// stomp rather than a pitched note. Density 0.4 keeps it sparse and
// lumbering (one stomp every ~2.5 beats).
//
// Voices:
//   drone: two heavy bass saws at MIDI 28–33, detuned ±10 cents
//   pad:   three triangles at MIDI 40–55, slow attack, gentle LP
//
// Reverb 0.6 room / 0.35 wet — a big room, but not a cathedral. The
// reverb tail shouldn't obscure the stomps; the giant is *here*, not
// distant.
//
// Wave spatial over 8 s — slow swaying left-right, like the giant
// walking. Not circular (too smooth) or ping-pong (too rhythmic).
// Wave matches the lumbering gait.

final clumsyKindGiant = SoundWorld(
  id: 'clumsy_kind_giant',
  name: 'Clumsy Kind Giant',
  description: 'Enormous, lumbering, tender. Detuned, heavy, slow.',
  voices: const [
    // Two heavy bass saws, detuned
    VoiceSpec(
      layer: 'drone',
      count: 2,
      source: SourceType.saw,
      rangeMidi: [28, 33], // E1–A1
      attackMs: 2000,
      releaseMs: 3000,
      detuneCents: 10, // ±10 cents per voice
    ),
    // Three triangles, mid register, slow attack
    VoiceSpec(
      layer: 'pad',
      count: 3,
      source: SourceType.tri,
      rangeMidi: [40, 55], // E2–G3
      attackMs: 1500,
      releaseMs: 2500,
      detuneCents: 6,
    ),
  ],
  effects: const [
    // Heavy LP on the drone — kill the harsh saw harmonics
    EffectSpec(EffectType.lowpass, {'cutoffHz': 250, 'resonance': 0.8}),
    // Lighter LP on the pad — keep some presence
    EffectSpec(EffectType.lowpass, {'cutoffHz': 1200, 'resonance': 0.7}),
    // Gentle saturation for weight
    EffectSpec(EffectType.saturation, {'drive': 1.4}),
    EffectSpec(EffectType.reverb, {'room': 0.6, 'wet': 0.35, 'damp': 0.3}),
  ],
  rhythm: const RhythmCharacter(RhythmType.pluck, density: 0.4),
  spatial: const SpatialSpec(
    defaultPattern: AntiphonalPattern.wave,
    defaultIntensity: 0.5,
    movementCycleSeconds: 8,
    droneRole: VoiceSpatialRole.centered,
    padRootRole: VoiceSpatialRole.front,
    rhythmRole: VoiceSpatialRole.centered,
    textureRole: VoiceSpatialRole.centered,
    padColorRoles: [],
  ),
);// ─── singing_child ─────────────────────────────────────────────────
//
// Vulnerable, pure, small. A single child's voice — not a choir, one
// voice. This is the most intimate world in the app: soft sine drone,
// a single formant voice in the soprano register, chorus OFF (children
// don't have ensemble vibrato), and a small room reverb.
//
// The "wobble" is deliberately imperfect intonation — the pitch drifts
// ±10 cents over 8 seconds, which is what an untrained (or very young)
// singer actually does. It's not synthesized vibrato; it's synthesis of
// a *human* whose pitch isn't perfectly stable. This is the difference
// between "singing child" and "child voice pad."
//
// Voices:
//   drone:   one sine, gain 0.15 (deliberately almost inaudible)
//   pad:     single formant voice at MIDI 75–84 with child formants
//   texture: (none — this world has no texture layer)
//
// Reverb 0.5 room / 0.3 wet — a small room, not a cathedral. The
// vulnerability comes from being close, not from being distant.
//
// Cluster spatial, intensity 0.15 — almost no motion. A child is *in
// front of you*. Full spatial motion would break the intimacy.

final singingChild = SoundWorld(
  id: 'singing_child',
  name: 'Singing Child',
  description: 'Vulnerable, pure, small. One voice, close.',
  voices: const [
    // Barely-there sine drone
    VoiceSpec(
      layer: 'drone',
      count: 1,
      source: SourceType.sine,
      rangeMidi: [45, 45], // A2 fixed — the child's reference pitch
      attackMs: 3000,
      releaseMs: 5000,
    ),
    // Single child formant voice — child formants are higher than adult
    VoiceSpec(
      layer: 'pad',
      count: 1,
      source: SourceType.formant,
      rangeMidi: [75, 84], // D5–C6
      attackMs: 800,
      releaseMs: 1200,
      vibratoRateHz: 5.5,
      vibratoCents: 7,
      detuneCents: 0, // single voice — no detune
      formants: [Formant(1000, 1500, 3500)],
    ),
  ],
  effects: const [
    // Small room reverb — intimacy
    EffectSpec(EffectType.reverb, {'room': 0.5, 'wet': 0.3, 'damp': 0.4}),
    // Gentle HPF — remove any low rumble; the child has no chest voice
    EffectSpec(EffectType.highpass, {'cutoffHz': 300, 'resonance': 0.7}),
  ],
  rhythm: const RhythmCharacter(RhythmType.pluck, density: 0.15),
  spatial: const SpatialSpec(
    defaultPattern: AntiphonalPattern.cluster,
    defaultIntensity: 0.15,
    movementCycleSeconds: 0,
    droneRole: VoiceSpatialRole.centered,
    padRootRole: VoiceSpatialRole.centered,
    rhythmRole: VoiceSpatialRole.centered,
    textureRole: VoiceSpatialRole.centered,
    padColorRoles: [],
  ),
);

// ─── musical_sea ───────────────────────────────────────────────────
//
// Waves and wind, but they have pitch. The defining mechanism: pink
// noise routed through four resonant bandpass filters (Q 15–25)
// tuned to the current chord. The result is *noise that sings the
// chord* — the sea is literally harmonizing. When the chord changes,
// the filters retune and the sea "resolves" to the new harmony.
//
// "Calm" and "storm" are controlled by a slow LFO on the pad's
// amplitude and the texture's filter Q. Calm = long 6-second swells,
// tight Q, low noise gain. Storm = 1.5-second swells, broad Q, high
// noise gain. The LFO period is 30–90 s (randomized at init) so the
// world drifts between states without a fixed rhythm — you can listen
// for minutes without hearing the same swell pattern twice.
//
// Voices:
//   drone:   pink noise through HP 20 / LP 300 — sub-aquatic bed
//   pad:     four formant voices tuned to the chord, in the mid-register
//   texture: pink noise through 4 resonant bands — the "sea" itself
//
// Reverb 0.8 room / 0.5 wet — the ocean is a big room, and the
// reverb is what makes the noise feel like it extends beyond the
// speakers.
//
// Wave spatial over 20 s — voices sweep front↔back like waves rolling
// in. Not circular (that would feel like orbiting, not like water).
// Wave matches the physical gesture of surf.

final musicalSea = SoundWorld(
  id: 'musical_sea',
  name: 'Musical Sea',
  description: 'Waves and wind, pitched. Calm to stormy, cyclical.',
  voices: const [
    // Sub-aquatic pink noise bed
    VoiceSpec(
      layer: 'drone',
      count: 1,
      source: SourceType.noise,
      rangeMidi: [40, 40],
      attackMs: 4000,
      releaseMs: 6000,
      noiseColor: NoiseColor.pink,
      noiseQ: 1.5,
    ),
    // Four formant pad voices, chord-tuned
    VoiceSpec(
      layer: 'pad',
      count: 4,
      source: SourceType.formant,
      rangeMidi: [50, 65], // D3–F4
      attackMs: 2000,
      releaseMs: 4000,
      vibratoRateHz: 2,
      vibratoCents: 3,
      detuneCents: 5,
      formants: [Formant(500, 1000, 2500)],
    ),
    // The sea itself — 4 resonant noise bands that follow the chord
    VoiceSpec(
      layer: 'texture',
      count: 4,
      source: SourceType.noise,
      rangeMidi: [50, 65],
      attackMs: 3000,
      releaseMs: 5000,
      noiseColor: NoiseColor.pink,
      noiseQ: 20.0, // resonant — this is the "singing" filter
    ),
  ],
  effects: const [
    // Drone LP
    EffectSpec(EffectType.lowpass, {'cutoffHz': 300, 'resonance': 0.7}),
    // HPF removes sub-rumble before reverb
    EffectSpec(EffectType.highpass, {'cutoffHz': 20, 'resonance': 0.7}),
    EffectSpec(EffectType.reverb, {'room': 0.8, 'wet': 0.5, 'damp': 0.3}),
  ],
  rhythm: const RhythmCharacter(RhythmType.pluck, density: 0.2),
  spatial: const SpatialSpec(
    defaultPattern: AntiphonalPattern.wave,
    defaultIntensity: 0.7,
    movementCycleSeconds: 20,
    droneRole: VoiceSpatialRole.centered,
    padRootRole: VoiceSpatialRole.front,
    rhythmRole: VoiceSpatialRole.centered,
    textureRole: VoiceSpatialRole.back,
    padColorRoles: [],
  ),
);

// ─── musical_wind ──────────────────────────────────────────────────
//
// Aeolian harp. White noise through three high-Q bandpass filters
// (Q 25–40) — each filter tracks a pitch class from the current chord,
// so the wind literally whistles the harmony. Higher Q means a
// narrower, more "pitched" sound; Q 25+ starts to produce an audible
// whistle. This is the *physics* of an aeolian harp: wind across
// strings produces tones at the string's resonant frequencies, and
// the resonant frequencies are the chord.
//
// No drone. No pad in the traditional sense — the wind is the pad.
// The pad spec here is three formant voices at very low level, tuned
// to the chord, providing just enough tonal anchor that the whistling
// noise has something to latch onto. If you removed them entirely, the
// wind would sound like noise; with them, it sounds like *music*.
//
// Voices:
//   pad:     three formant voices, low level (tonal anchor)
//   texture: three high-Q noise bands tracking the chord (the wind)
//
// Reverb 0.85 room / 0.45 wet — outdoor space, no walls. The reverb is
// doing "the mountain is huge" rather than "the room is big."
//
// Circular spatial over 15 s — wind moves around you. Circular is the
// right pattern here because wind *does* come from all directions
// without a clear front/back. Wave would imply a fixed orientation.

final musicalWind = SoundWorld(
  id: 'musical_wind',
  name: 'Musical Wind',
  description: 'Aeolian harp. High, airy, whistling the chord.',
  voices: const [
    // Low-level formant voices — tonal anchor for the noise
    VoiceSpec(
      layer: 'pad',
      count: 3,
      source: SourceType.formant,
      rangeMidi: [55, 70], // G3–A#4
      attackMs: 2500,
      releaseMs: 4000,
      vibratoRateHz: 0,
      vibratoCents: 0,
      detuneCents: 3,
      formants: [Formant(600, 1100, 2700)],
    ),
    // High-Q noise bands — the whistle
    VoiceSpec(
      layer: 'texture',
      count: 3,
      source: SourceType.noise,
      rangeMidi: [55, 70],
      attackMs: 4000,
      releaseMs: 6000,
      noiseColor: NoiseColor.white,
      noiseQ: 30.0, // narrow — this is the whistle
    ),
  ],
  effects: const [
    // HPF removes rumble — wind should have no low content
    EffectSpec(EffectType.highpass, {'cutoffHz': 400, 'resonance': 0.7}),
    EffectSpec(EffectType.reverb, {'room': 0.85, 'wet': 0.45, 'damp': 0.2}),
  ],
  rhythm: const RhythmCharacter(RhythmType.none),
  spatial: const SpatialSpec(
    defaultPattern: AntiphonalPattern.circular,
    defaultIntensity: 0.65,
    movementCycleSeconds: 15,
    droneRole: VoiceSpatialRole.centered,
    padRootRole: VoiceSpatialRole.centered,
    rhythmRole: VoiceSpatialRole.centered,
    textureRole: VoiceSpatialRole.front,
    padColorRoles: [],
  ),
);// ─── broken_glass ──────────────────────────────────────────────────
//
// Sharp, fractured, granular. High-frequency glassy FM grains at MIDI
// 80–100, each grain a 30 ms burst with ±50-cent pitch drift. The
// grains are the *only* pitched content — the "bed" is a very quiet
// high-frequency noise band that gives the shards something to sit
// against. The world is dry (reverb 0.4) because reverb would blur the
// shards into a wash, which destroys the effect.
//
// The signature quality: the pitch is *unstable*. Grains drift ±50
// cents, so even when the brain is playing C major, the glass doesn't
// sound "in C" so much as "of C" — the pitch is present but not fixed.
// This is a deliberate contrast to `ice_crystals`, which is stable.
//
// Density 20 grains/second is a guess. Too low (5/s) → sparse;
// too high (100/s) → indistinguishable from noise. 20/s is "you can
// hear each shard if you listen, but together they form a shimmer."
//
// Voices:
//   pad:     3 granular FM voices at MIDI 80–100 (the shards)
//   texture: high-Q noise at 5 kHz (the "surface the shards slide on")
//   rhythm:  short glass hits at MIDI 90–105
//
// Reverb 0.4 room / 0.25 wet — dry. The shards are close.
//
// Alternate spatial — one shard left, one right, one center, rotating
// on chord change. Static assignment would be too static; circular
// would be too smooth. Alternate matches the shard-like character.
// Intensity 0.9 — the highest of any world. This world is spatial.

final brokenGlass = SoundWorld(
  id: 'broken_glass',
  name: 'Broken Glass',
  description: 'Sharp, fractured, granular. High glassy shards.',
  voices: const [
    // Three granular FM voices — the shards
    VoiceSpec(
      layer: 'pad',
      count: 3,
      source: SourceType.granular,
      rangeMidi: [80, 100], // G#5–E7
      attackMs: 50,        // shards are attacks, not swells
      releaseMs: 200,
      vibratoRateHz: 0,
      vibratoCents: 0,
      detuneCents: 0,       // no detune — grains drift instead
      grainMs: 30,
      grainDensity: 20,     // 20 grains/second
      fmIndex: 2.0,         // glassy FM
      fmRatio: 3.7,         // non-integer → inharmonic partials
    ),
    // Quiet high-Q noise bed — the "surface"
    VoiceSpec(
      layer: 'texture',
      count: 1,
      source: SourceType.noise,
      rangeMidi: [80, 80],
      attackMs: 1000,
      releaseMs: 2000,
      noiseColor: NoiseColor.white,
      noiseQ: 20.0,         // narrow — a specific "cold surface" quality
    ),
  ],
  effects: const [
    // Short reverb — the space is close, not distant
    EffectSpec(EffectType.reverb, {'room': 0.4, 'wet': 0.25, 'damp': 0.6}),
    // HPF — glass has no low content
    EffectSpec(EffectType.highpass, {'cutoffHz': 2000, 'resonance': 0.7}),
    // Slight high shelf boost — glass is *bright*
    EffectSpec(EffectType.highShelf, {'freqHz': 6000, 'gainDb': 3.0}),
  ],
  rhythm: const RhythmCharacter(RhythmType.pluck, density: 0.7),
  spatial: const SpatialSpec(
    defaultPattern: AntiphonalPattern.alternate,
    defaultIntensity: 0.9,
    movementCycleSeconds: 0,
    droneRole: VoiceSpatialRole.centered,
    padRootRole: VoiceSpatialRole.left,
    rhythmRole: VoiceSpatialRole.right,
    textureRole: VoiceSpatialRole.centered,
    padColorRoles: [],
  ),
);

// ─── ice_crystals ──────────────────────────────────────────────────
//
// Bell, sustained, cold. FM bells that ring for 15 seconds. This is
// the sustained counterpart to `broken_glass`: where the shards are
// transient grains, the crystals are long-decay bells. The world is
// *almost* silent between chord changes — each chord fires one bell
// per pitch, each bell decays over 15 s, and the next chord doesn't
// arrive until the previous one has decayed to silence.
//
// This world is fundamentally tied to chord-change rate. Fast changes
// → dense overlapping bells → chord wash. Slow changes → isolated
// bell strikes → single sustained tones. The `intensity` setting from
// the slider is applied to the *bell strikes*, not to a continuous
// voice — which is why this world always sounds "event-like" rather
// than "pad-like."
//
// FM ratios 1.4, 2.7, 3.6 are non-integer → inharmonic bells (not
// pitched instruments, but "bells that hover near pitch"). This is
// the defining timbre — you *can* tell what chord is playing, but
// each bell has an ambiguous pitch center that doesn't lock to the
// equal-tempered grid.
//
// Voices:
//   pad:     4 FM bell voices at MIDI 60–90 (chord tones + color)
//   texture: 2 high sines at MIDI 96–105 (the high shimmer)
//
// Reverb 0.9 room / 0.6 wet + 400 ms echo at 40% feedback. The reverb
// AND delay together give the bells a "rings forever" quality even
// though each bell's envelope is only 15 s. The echo is the secret —
// without it, the bells decay; with it, they breathe.
//
// Alternate spatial — each new bell appears in a different position.
// Circular would imply rotation; alternate keeps each bell fixed in
// space, which is what ice actually does (a crystal doesn't move).

final iceCrystals = SoundWorld(
  id: 'ice_crystals',
  name: 'Ice Crystals',
  description: 'Bell-like, sustained, cold. Long-decay FM bells.',
  voices: const [
    // Four FM bell voices — the crystals
    VoiceSpec(
      layer: 'pad',
      count: 4,
      source: SourceType.fm,
      rangeMidi: [60, 90], // C4–F#6
      attackMs: 2000,       // slow attack — crystal "forms"
      releaseMs: 15000,     // very long release — crystal "sings"
      vibratoRateHz: 0,
      vibratoCents: 0,
      detuneCents: 0,
      fmIndex: 2.5,
      fmRatio: 2.7,         // non-integer → inharmonic bell
    ),
    // Two high sines — the shimmer on top
    VoiceSpec(
      layer: 'texture',
      count: 2,
      source: SourceType.sine,
      rangeMidi: [96, 105], // C7–A8
      attackMs: 3000,
      releaseMs: 5000,
      vibratoRateHz: 6,
      vibratoCents: 5,
      detuneCents: 3,
    ),
  ],
  effects: const [
    EffectSpec(EffectType.reverb, {'room': 0.9, 'wet': 0.6, 'damp': 0.2}),
    EffectSpec(EffectType.delay, {'timeMs': 400, 'feedback': 0.4, 'wet': 0.2}),
    // HPF — cold air, no low rumble
    EffectSpec(EffectType.highpass, {'cutoffHz': 200, 'resonance': 0.7}),
  ],
  rhythm: const RhythmCharacter(RhythmType.none),
  spatial: const SpatialSpec(
    defaultPattern: AntiphonalPattern.alternate,
    defaultIntensity: 0.55,
    movementCycleSeconds: 0,
    droneRole: VoiceSpatialRole.centered,
    padRootRole: VoiceSpatialRole.left,
    rhythmRole: VoiceSpatialRole.centered,
    textureRole: VoiceSpatialRole.right,
    padColorRoles: [],
  ),
);

// ─── russian_choir ─────────────────────────────────────────────────
//
// Deep male mass. The cathedral counterpart to the village-feel of
// `eastern_european_choir`. Two bass formant voices at MIDI 30–36
// (basso profundo range — E1 to A1), plus a sub-octave anchor at
// MIDI 18–24 (below most human voices — the "impossible depth" that
// Russian choral recordings have), plus three mid-range male formant
// voices at MIDI 45–60.
//
// Formants are male (500/900/2400 for the mid voices) — not child,
// not female. The bass voices use narrower formants (350/700/2000) —
// deeper, more chest-resonant. Vibrato is slower than the Balkan
// choir (4 Hz vs 5) and shallower (5 cents vs 10) — Russian choral
// singing is more sustained and less ornamented.
//
// The defining effect: an overall LP at 4 kHz, which removes the
// upper harmonics that would make the choir sound "present." The
// result is a choir that feels *distant* — you're hearing it from
// the far end of a large cathedral, not from the front row. This is
// the actual acoustic of a large stone church: high frequencies die
// over distance, low frequencies carry. The LP is the acoustics.
//
// Reverb 0.9 room / 0.5 wet — cathedral. This is the second-highest
// reverb room value of any world (`washy_reverb` is 0.98, this is
// 0.9). The wet is lower than washy's because the LP already does
// most of the "distance" work.
//
// Cluster spatial, intensity 0.4 — the choir is a mass, not individual
// voices. Full spatial motion would break the ensemble character.

final russianChoir = SoundWorld(
  id: 'russian_choir',
  name: 'Russian Choir',
  description: 'Deep male mass. Cathedral, distant, octave bass.',
  voices: const [
    // Octave bass anchor — MIDI 18–24
    VoiceSpec(
      layer: 'drone',
      count: 1,
      source: SourceType.sine,
      rangeMidi: [18, 24], // D0–C1
      attackMs: 3000,
      releaseMs: 5000,
    ),
    // Two bass formant voices (basso profundo)
    VoiceSpec(
      layer: 'drone',
      count: 2,
      source: SourceType.formant,
      rangeMidi: [30, 36], // F#1–C2
      attackMs: 1500,
      releaseMs: 3000,
      vibratoRateHz: 4,
      vibratoCents: 5,
      detuneCents: 4,
      formants: [Formant(350, 700, 2000)],
    ),
    // Three male formant pad voices (tenor/baritone)
    VoiceSpec(
      layer: 'pad',
      count: 3,
      source: SourceType.formant,
      rangeMidi: [45, 60], // A2–C4
      attackMs: 1200,
      releaseMs: 2500,
      vibratoRateHz: 4,
      vibratoCents: 5,
      detuneCents: 4,
      formants: [Formant(500, 900, 2400)],
    ),
  ],
  effects: const [
    // Global LP — the acoustics of distance
    EffectSpec(EffectType.lowpass, {'cutoffHz': 4000, 'resonance': 0.6}),
    // Cathedral reverb
    EffectSpec(EffectType.reverb, {'room': 0.9, 'wet': 0.5, 'damp': 0.3}),
    // Gentle saturation — the "chest" of the bass voices
    EffectSpec(EffectType.saturation, {'drive': 1.2}),
  ],
  rhythm: const RhythmCharacter(RhythmType.pluck, density: 0.25),
  spatial: const SpatialSpec(
    defaultPattern: AntiphonalPattern.cluster,
    defaultIntensity: 0.4,
    movementCycleSeconds: 0,
    droneRole: VoiceSpatialRole.centered,
    padRootRole: VoiceSpatialRole.centered,
    rhythmRole: VoiceSpatialRole.centered,
    textureRole: VoiceSpatialRole.centered,
    padColorRoles: [],
  ),
  harmony: const HarmonyConfig(
    preferredLanguage: 'renaissance',
    vowelCycle: ['oh', 'ah', 'oo'],
  ),
);// ─── banjo_chorus ──────────────────────────────────────────────────
//
// Bright, strummed, dry. A bank of plucked voices that play the chord
// as a rolled strum on each chord change. The signature trick: the
// strum notes are staggered by 15 ms per string, so a 5-note voicing
// takes 60 ms to roll from lowest to highest. This is what real string
// ensembles do — a "banjo chorus" is inherently micro-asynchronous.
//
// Detune is small (±3 cents) because banjos are fretted, not
// fretless — they stay near pitch. The chorus effect in the effects
// chain is very light (0.15 Hz × 3 cents), adding only enough smear
// to suggest multiple instruments.
//
// Reverb 0.35 room / 0.2 wet — dry. Banjos are dry instruments. The
// reverb exists only to prevent the strums from sounding like they're
// in an anechoic chamber. Push it higher and the world collapses into
// washy_reverb territory.
//
// The "body thump" texture — low-passed noise at 120 Hz — is what
// gives the world its "wooden instrument" identity. It plays on every
// chord change alongside the strum, like the resonance of the
// instrument's soundbox.
//
// Voices:
//   pad:     5 plucked voices at MIDI 52–76 (the strum)
//   texture: 1 short LP 120 Hz noise burst (the body thump)
//   rhythm:  plucks on the beat
//
// Alternate spatial with intensity 0.75 — the strum spreads across
// the virtual ring (lowest notes left, highest right), so each chord
// change is heard as a spatial sweep. Rhythm hits stay centered.

final banjoChorus = SoundWorld(
  id: 'banjo_chorus',
  name: 'Banjo Chorus',
  description: 'Bright strummed ensemble. Dry, wooden, rolled chords.',
  voices: const [
    // Five plucked voices — the rolled strum
    VoiceSpec(
      layer: 'pad',
      count: 5,
      source: SourceType.pluck,
      rangeMidi: [52, 76], // E3–E5
      attackMs: 5,          // plucks are attacks
      releaseMs: 600,       // natural string decay
      vibratoRateHz: 0,
      vibratoCents: 0,
      detuneCents: 3,       // fret noise
    ),
    // Body thump texture
    VoiceSpec(
      layer: 'texture',
      count: 1,
      source: SourceType.noise,
      rangeMidi: [48, 48],
      attackMs: 2,
      releaseMs: 40,        // very short
      noiseColor: NoiseColor.brown,
      noiseQ: 6.0,          // narrow-ish for the "wood" character
    ),
  ],
  effects: const [
    // LP — the wood of the instrument
    EffectSpec(EffectType.lowpass, {'cutoffHz': 4000, 'resonance': 0.6}),
    // Light chorus — the ensemble smear
    EffectSpec(EffectType.chorus, {'rateHz': 0.15, 'depthMs': 3}),
    // HPF — banjo has no sub
    EffectSpec(EffectType.highpass, {'cutoffHz': 200, 'resonance': 0.7}),
    // Dry reverb — small room
    EffectSpec(EffectType.reverb, {'room': 0.35, 'wet': 0.2, 'damp': 0.4}),
  ],
  rhythm: const RhythmCharacter(RhythmType.pluck, density: 0.75),
  spatial: const SpatialSpec(
    defaultPattern: AntiphonalPattern.alternate,
    defaultIntensity: 0.75,
    movementCycleSeconds: 0,
    droneRole: VoiceSpatialRole.centered,
    padRootRole: VoiceSpatialRole.left,
    rhythmRole: VoiceSpatialRole.centered,
    textureRole: VoiceSpatialRole.centered,
    padColorRoles: [],
  ),
);

// ─── desert ────────────────────────────────────────────────────────
//
// Sparse, dry, wide. The most minimal world in the set. A single
// sustained reed drone (saw + formant at 600/1100/2700 — the "duduk"
// timbre), plus extremely sparse plucked-string accents at MIDI 65–75
// that have a microtonal scoop (start 25 cents below pitch, glide up
// over 300 ms — the "maqam" ornament).
//
// The reverb is 0.5 room / 0.15 wet — the *driest* reverb of any
// sustained world. This is deliberate. Reverb creates the impression
// of walls. The desert has no walls. The dry long-tail of the plucks
// is the "emptiness", not the reverb.
//
// The "distant wind" texture — pink noise through a narrow LP — is
// present but barely audible. It provides the *suggestion* of
// environment without becoming environmental. This is the difference
// between "desert" and "musical_sea": the sea is *made of* the noise;
// the desert is *in* the noise.
//
// Voices:
//   drone:   one saw formant reed voice at MIDI 45–55
//   pad:     2 plucked-string voices at MIDI 65–75 (the "accents")
//   texture: pink noise through LP 600 Hz (the "wind")
//
// Cluster spatial with intensity 0.3 — the world is wide because the
// sound is sparse, not because it moves. Individual notes appear from
// different positions but don't sweep. Static placement, quiet motion.

final desert = SoundWorld(
  id: 'desert',
  name: 'Desert',
  description: 'Sparse, dry, wide. Reed drone, microtonal plucks.',
  voices: const [
    // Reed drone (duduk-like)
    VoiceSpec(
      layer: 'drone',
      count: 1,
      source: SourceType.formant,
      rangeMidi: [45, 55], // A2–G3
      attackMs: 2500,
      releaseMs: 5000,
      vibratoRateHz: 4,
      vibratoCents: 3,
      detuneCents: 0,
      formants: [Formant(600, 1100, 2700)],
    ),
    // Two plucked-string accents
    VoiceSpec(
      layer: 'pad',
      count: 2,
      source: SourceType.pluck,
      rangeMidi: [65, 75], // F4–D#5
      attackMs: 5,
      releaseMs: 2000,      // long tail — the "emptiness"
      vibratoRateHz: 0,
      vibratoCents: 0,
      detuneCents: 0,
    ),
    // Distant wind texture
    VoiceSpec(
      layer: 'texture',
      count: 1,
      source: SourceType.noise,
      rangeMidi: [60, 60],
      attackMs: 4000,
      releaseMs: 6000,
      noiseColor: NoiseColor.white,
      noiseQ: 6.0,          // broad LP at 600 Hz
    ),
  ],
  effects: const [
    EffectSpec(EffectType.lowpass, {'cutoffHz': 600, 'resonance': 6.0}),
    EffectSpec(EffectType.highpass, {'cutoffHz': 40, 'resonance': 0.7}),
    EffectSpec(EffectType.reverb, {'room': 0.5, 'wet': 0.15, 'damp': 0.5}),
    // Short echo — a single distant reflection, not a wall
    EffectSpec(EffectType.delay, {'timeMs': 500, 'feedback': 0.1, 'wet': 0.1}),
  ],
  rhythm: const RhythmCharacter(RhythmType.woodblock, density: 0.15),
  spatial: const SpatialSpec(
    defaultPattern: AntiphonalPattern.cluster,
    defaultIntensity: 0.3,
    movementCycleSeconds: 0,
    droneRole: VoiceSpatialRole.centered,
    padRootRole: VoiceSpatialRole.left,
    rhythmRole: VoiceSpatialRole.right,
    textureRole: VoiceSpatialRole.centered,
    padColorRoles: [],
  ),
);

// ─── flamencish ────────────────────────────────────────────────────
//
// Spanish, compás-driven. The only world in the set that has a
// *rhythmic identity* rather than just a rhythmic layer. The 12-beat
// Soleá compás (hits on beats [0, 3, 6, 8, 10]) is baked into the
// world spec via the internal compás override — when the brain is
// beat-locked, the world uses whatever the player plays; when the
// brain is not beat-locked, the world *plays its own compás*. This
// makes flamencish fully playable with no percussion input.
//
// The signature: cajón kick (LP 90 Hz, 180 ms decay), cajón slap
// (LP 1.4 kHz, 120 ms), and palmas triple-burst (three claps at 0,
// 12, 25 ms). These are the three classic flamenco percussion sounds.
// The triple-burst is critical — a single clap sounds wrong; the
// rapid-fire three is unmistakably "palmas."
//
// Reverb 0.35 / 0.12 wet — dry. Flamenco is dry and forward. The
// chorus of palmas doesn't need a reverb to sound like a room; the
// room *is* the palmas.
//
// Voices:
//   drone:   one sub + one fifth plucked-string drone (the "guitar")
//   pad:     4 plucked-string voices (rasgueado — rapid multi-note strums)
//   rhythm:  cajón + palmas (see §11.7's per-world rhythm override)
//   texture: faint palmas body resonance (the "hands" character)
//
// Call-response spatial over 6 beats — the guitar (pad) and the palmas
// (rhythm) alternate between "on" and "off" position on a 6-beat
// cycle. This mirrors the actual structure of flamenco: guitar and
// palmas trade phrases. Intensity 0.7 — the response should be clearly
// audible but not so wide it sounds like two separate performances.

final flamencish = SoundWorld(
  id: 'flamencish',
  name: 'Flamencish',
  description: 'Spanish, compás-driven. Guitar, cajón, palmas.',
  voices: const [
    // Sub + fifth plucked-string drone (the guitar "rasgueo")
    VoiceSpec(
      layer: 'drone',
      count: 2,
      source: SourceType.pluck,
      rangeMidi: [40, 50], // E2–D3
      attackMs: 30,
      releaseMs: 3000,
      vibratoRateHz: 0,
      vibratoCents: 0,
      detuneCents: 2,
    ),
    // Four plucked-string pad voices (the rasgueado)
    VoiceSpec(
      layer: 'pad',
      count: 4,
      source: SourceType.pluck,
      rangeMidi: [52, 67], // E3–G4
      attackMs: 5,
      releaseMs: 1500,
      vibratoRateHz: 0,
      vibratoCents: 0,
      detuneCents: 2,
    ),
    // Cajón and palmas are rhythm-layer content, not pad — see
    // the rhythm character below. The synth engine will spawn these
    // as transient hits on the rhythm schedule.
    // Faint palmas body resonance (the "hands" character)
    VoiceSpec(
      layer: 'texture',
      count: 1,
      source: SourceType.noise,
      rangeMidi: [60, 60],
      attackMs: 1000,
      releaseMs: 2000,
      noiseColor: NoiseColor.white,
      noiseQ: 4.0,
    ),
  ],
  effects: const [
    // LP for the guitar body
    EffectSpec(EffectType.lowpass, {'cutoffHz': 3500, 'resonance': 0.6}),
    // Slight saturation — the guitar has a "presence"
    EffectSpec(EffectType.saturation, {'drive': 1.5}),
    // Dry reverb — flamenco is dry
    EffectSpec(EffectType.reverb, {'room': 0.35, 'wet': 0.12, 'damp': 0.4}),
  ],
  rhythm: const RhythmCharacter(
    RhythmType.cajon,
    density: 0.6, // cajón density — palmas are interleaved by the
                  // per-world rhythm override, not represented here
  ),
  spatial: const SpatialSpec(
    defaultPattern: AntiphonalPattern.callResponse,
    defaultIntensity: 0.7,
    movementCycleSeconds: 6, // 6-beat call-response cycle
    droneRole: VoiceSpatialRole.centered,
    padRootRole: VoiceSpatialRole.left,   // guitar
    rhythmRole: VoiceSpatialRole.right,   // palmas/cajón
    textureRole: VoiceSpatialRole.centered,
    padColorRoles: [],
  ),
);// ─── huge_chords ───────────────────────────────────────────────────
//
// Cinematic, immense, patient. The single biggest world in the set.
// Each chord is played as if it were the last chord ever played. Two
// sub basses establish a foundation that most playback systems will
// feel more than hear (MIDI 12–20 and 24–32 — C0–G#1 and C1–G#2).
//
// The pad is a three-octave BrassSwell voice — three separate
// VoiceSpec entries, one per octave, each voiced across the chord.
// Together they produce 6–8 simultaneous pad voices per chord, all
// with slow swells (1.2–3 s attack) and long releases (3.5–4.5 s).
// Voice-leading across chords is mandatory; without it, the big
// chords blur into mud.
//
// The signature of the world is TIME. Chord changes are slow, envelopes
// are long, and the reverb tail is enormous. If you're used to fast
// music, this world will feel like it's broken — it isn't. It's
// patient.
//
// Voices:
//   drone:   two sub-bass sines (MIDI 12–20 and 24–32)
//   pad:     three BrassSwell voices (low/mid/high octaves)
//   texture: pink noise air bed at 2–8 kHz
//
// Reverb 0.95 room / 0.55 wet — cathedral-scale space.
//
// Circular spatial over 30 s — the chord slowly rotates around the
// listener. On a stereo system this is barely audible; on headphones
// it's a slow orbit. This is the only world besides earth_singing
// with a cycle this long.

final hugeChords = SoundWorld(
  id: 'huge_chords',
  name: 'Huge Chords',
  description: 'Cinematic, immense, patient. Sub bass, brass, air.',
  voices: const [
    // Two sub basses — the foundation
    VoiceSpec(
      layer: 'drone',
      count: 2,
      source: SourceType.sine,
      rangeMidi: [12, 20], // C0–G#1
      attackMs: 4000,
      releaseMs: 6000,
      detuneCents: 2,
    ),
    // Three brass swells — low/mid/high
    VoiceSpec(
      layer: 'pad',
      count: 2,
      source: SourceType.brass,
      rangeMidi: [36, 48], // C2–C3
      attackMs: 2500,
      releaseMs: 4000,
      vibratoRateHz: 0,
      vibratoCents: 0,
      detuneCents: 4,
    ),
    VoiceSpec(
      layer: 'pad',
      count: 3,
      source: SourceType.brass,
      rangeMidi: [48, 60], // C3–C4
      attackMs: 2000,
      releaseMs: 3500,
      vibratoRateHz: 0,
      vibratoCents: 0,
      detuneCents: 4,
    ),
    VoiceSpec(
      layer: 'pad',
      count: 2,
      source: SourceType.brass,
      rangeMidi: [60, 72], // C4–C5
      attackMs: 3000,
      releaseMs: 4500,
      vibratoRateHz: 0,
      vibratoCents: 0,
      detuneCents: 3,
    ),
    // Air bed — the "sky" above the chord
    VoiceSpec(
      layer: 'texture',
      count: 1,
      source: SourceType.noise,
      rangeMidi: [60, 60],
      attackMs: 5000,
      releaseMs: 8000,
      noiseColor: NoiseColor.pink,
      noiseQ: 4.0,
    ),
  ],
  effects: const [
    // LP on the subs — kill everything above 90 Hz
    EffectSpec(EffectType.lowpass, {'cutoffHz': 90, 'resonance': 0.7}),
    // LP on the brass — 2.5 kHz keeps them warm, not brassy
    EffectSpec(EffectType.lowpass, {'cutoffHz': 2500, 'resonance': 0.6}),
    // Gentle saturation — the "heavy weight" of the sound
    EffectSpec(EffectType.saturation, {'drive': 1.2}),
    // Massive reverb
    EffectSpec(EffectType.reverb, {'room': 0.95, 'wet': 0.55, 'damp': 0.25}),
    // Stereo width — +3 dB side gain
    EffectSpec(EffectType.chorus, {'rateHz': 0.1, 'depthMs': 2}),
  ],
  rhythm: const RhythmCharacter(RhythmType.brass, density: 0.4),
  spatial: const SpatialSpec(
    defaultPattern: AntiphonalPattern.circular,
    defaultIntensity: 0.55,
    movementCycleSeconds: 30,
    droneRole: VoiceSpatialRole.centered,
    padRootRole: VoiceSpatialRole.front,
    rhythmRole: VoiceSpatialRole.centered,
    textureRole: VoiceSpatialRole.back,
    padColorRoles: [],
  ),
);

// ─── parallel_chords ───────────────────────────────────────────────
//
// The harmonizer world. UNIQUE among the 17 worlds: there is no
// continuous pad. The "pad" slot is empty because the harmony voice
// IS the pad — it plays only when the player plays, in parallel
// (thirds, sixths, fifths, octaves — see §11.1's harmonizer logic
// and §43's HarmonyInterval enum).
//
// The world itself provides:
//   - Minimal drone (a single very soft sub at the root)
//   - A "harmony" layer VoiceSpec (pluck or organ timbre — see below)
//   - No pad, no textures, no rhythm
//
// The brain's §11.1 `_buildHarmonySchedule` fires HarmonyEvents into
// `MusicalState.harmonySchedule`, which the synth engine plays through
// the harmony VoiceSpec. This is why parallel_chords has a HarmonyConfig
// with `preferredLanguage: null` (any language works) — the voice is
// purely reactive.
//
// The pluck timbre is the default. If the user sets
// `app.harmonyTimbre = HarmonyTimbre.organ`, the synth should substitute
// a BrassSwell voice with fast attack (60 ms) and short release (400 ms)
// — this is a per-frame substitution handled in synth.dart, not a
// property of this VoiceSpec. The VoiceSpec here is the fallback.
//
// Reverb 0.5 room / 0.2 wet — intimate, so the harmony sits close to
// the player's notes without smearing the timing.
//
// Alternate spatial with intensity 0.8 — the harmony voice is placed
// on the OPPOSITE side from the player's perceived position. This is
// the "adaptive shadow" concept from §11.6: the harmony shadows the
// player but from across the room, not from the same point.

final parallelChords = SoundWorld(
  id: 'parallel_chords',
  name: 'Parallel Chords (Harmonizer)',
  description: 'Shadows your playing with intelligent parallel harmony.',
  voices: const [
    // Minimal sub drone
    VoiceSpec(
      layer: 'drone',
      count: 1,
      source: SourceType.sine,
      rangeMidi: [36, 40], // C2–E2
      attackMs: 2000,
      releaseMs: 3000,
    ),
    // The harmony voice — fires on HarmonyEvents from the brain
    VoiceSpec(
      layer: 'harmony',
      count: 4,
      source: SourceType.pluck,
      rangeMidi: [60, 84], // C4–C6
      attackMs: 10,
      releaseMs: 400,
      vibratoRateHz: 0,
      vibratoCents: 0,
      detuneCents: 0,
    ),
  ],
  effects: const [
    EffectSpec(EffectType.reverb, {'room': 0.5, 'wet': 0.2, 'damp': 0.4}),
    // Short delay adds depth without smearing timing
    EffectSpec(EffectType.delay, {'timeMs': 100, 'feedback': 0.15, 'wet': 0.12}),
    // HPF — the harmony sits above the player
    EffectSpec(EffectType.highpass, {'cutoffHz': 200, 'resonance': 0.7}),
  ],
  rhythm: const RhythmCharacter(RhythmType.none),
  spatial: const SpatialSpec(
    defaultPattern: AntiphonalPattern.alternate,
    defaultIntensity: 0.8,
    movementCycleSeconds: 0,
    droneRole: VoiceSpatialRole.centered,
    padRootRole: VoiceSpatialRole.centered,
    rhythmRole: VoiceSpatialRole.centered,
    textureRole: VoiceSpatialRole.centered,
    padColorRoles: [],
  ),
  harmony: const HarmonyConfig(
    // No preferred language — any harmonic language works with a
    // harmonizer, since the harmony voice is defined by the interval
    // settings, not by the language's chord choice.
    preferredLanguage: null,
    vowelCycle: null,
  ),
);

// ─── renaissance_choir ─────────────────────────────────────────────
//
// A cappella SATB, modal polyphony, 1450–1600. Palestrina, Byrd,
// Tallis. The only world in the set that models a specific historical
// performance practice.
//
// The defining feature is the ABSENCE of features:
//   - No vibrato (2–3 cents at 4 Hz — barely perceptible)
//   - No chorus (early music performance practice: transparent, not
//     blended)
//   - No saturation (the timbre is already warm from the formants)
//   - Strict SATB ranges (S: C4–F5, A: F3–C5, T: C3–F4, B: E2–A3)
//
// The vowel alternation — "oo", "ah", "eh" — is what makes the choir
// sound like words, not a synth. The vowel cycle is present in
// HarmonyConfig and is applied per-phrase by the synth engine (Phase
// 3 refinement; for Phase 2 all vowels default to "ah").
//
// Reverb 0.6 room / 0.35 wet — chapel acoustic. Not cathedral (that's
// russian_choir's 0.9), not concert hall. A chapel is *intimate* — the
// sound is clear and forward, but there's still stone around it.
//
// Cluster spatial with intensity 0.35 — slightly spread, not moving.
// Renaissance polyphony was written for antiphonal performance in
// galleries, but the choir-in-one-place acoustic is what most modern
// listeners know. The cluster setting keeps the four voices slightly
// separated (soprano left, bass right) but stops short of the full
// call-response dynamic.

final renaissanceChoir = SoundWorld(
  id: 'renaissance_choir',
  name: 'Renaissance Choir',
  description: 'A cappella SATB. No vibrato, no chorus. Modal.',
  voices: const [
    // Soprano
    VoiceSpec(
      layer: 'pad',
      count: 1,
      source: SourceType.formant,
      rangeMidi: [60, 77], // C4–F5
      attackMs: 300,
      releaseMs: 800,
      vibratoRateHz: 4,
      vibratoCents: 3,      // minimal vibrato
      detuneCents: 2,
      formants: [Formant(800, 1150, 2500)],
    ),
    // Alto
    VoiceSpec(
      layer: 'pad',
      count: 1,
      source: SourceType.formant,
      rangeMidi: [53, 72], // F3–C5
      attackMs: 300,
      releaseMs: 800,
      vibratoRateHz: 4,
      vibratoCents: 3,
      detuneCents: 2,
      formants: [Formant(700, 1100, 2400)],
    ),
    // Tenor
    VoiceSpec(
      layer: 'pad',
      count: 1,
      source: SourceType.formant,
      rangeMidi: [48, 65], // C3–F4
      attackMs: 300,
      releaseMs: 800,
      vibratoRateHz: 4,
      vibratoCents: 3,
      detuneCents: 2,
      formants: [Formant(500, 1000, 2200)],
    ),
    // Bass
    VoiceSpec(
      layer: 'pad',
      count: 1,
      source: SourceType.formant,
      rangeMidi: [40, 57], // E2–A3
      attackMs: 300,
      releaseMs: 800,
      vibratoRateHz: 4,
      vibratoCents: 3,
      detuneCents: 2,
      formants: [Formant(350, 800, 2000)],
    ),
  ],
  effects: const [
    // NO chorus — this is the defining choice
    // Chapel reverb
    EffectSpec(EffectType.reverb, {'room': 0.6, 'wet': 0.35, 'damp': 0.3}),
    // Gentle HPF — remove any rumble below the bass range
    EffectSpec(EffectType.highpass, {'cutoffHz': 60, 'resonance': 0.7}),
  ],
  rhythm: const RhythmCharacter(RhythmType.none),
  spatial: const SpatialSpec(
    defaultPattern: AntiphonalPattern.cluster,
    defaultIntensity: 0.35,
    movementCycleSeconds: 0,
    droneRole: VoiceSpatialRole.centered,
    padRootRole: VoiceSpatialRole.centered,
    rhythmRole: VoiceSpatialRole.centered,
    textureRole: VoiceSpatialRole.centered,
    padColorRoles: [],
  ),
  harmony: const HarmonyConfig(
    preferredLanguage: 'renaissance',
    vowelCycle: ['oo', 'ah', 'eh'],
  ),
);
// ─── Registration ──────────────────────────────────────────────────

final Map<String, SoundWorld> kSoundWorlds = <String, SoundWorld>{
  for (final w in [
    tameImpalaFan, washyReverb,
    earthSinging, easternEuropeanChoir, clumsyKindGiant,
    singingChild, musicalSea, musicalWind,
    brokenGlass, iceCrystals, russianChoir,
    banjoChorus, desert, flamencish,
    hugeChords, parallelChords, renaissanceChoir,
  ])
    w.id: w,
};

/// Default world (asserted against AppState's default in main.dart).
final SoundWorld kDefaultWorld = tameImpalaFan;

SoundWorld worldById(String id) => kSoundWorlds[id] ?? kDefaultWorld;
