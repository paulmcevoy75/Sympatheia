# DEVIATIONS.md

Where the built code differs from the DeepSeek spec, and why. Read this
before each phase.

## Toolchain / packages (checked against the libraries' own source)

| Spec assumption | Reality | What the code does |
|---|---|---|
| `fftea.realFft` returns interleaved `[re0, im0, …]` (bug #11) | Returns `Float64x2List` (complex pairs) | `analysis.dart` reads `.x` / `.y` |
| `record`: `setInputDevice()`, `InputDevice.isDefault` | Device is passed in `RecordConfig.device`; no `isDefault` | `input_router.dart` keeps the `InputDevice` and restarts the stream; first listed device is treated as default |
| flutter_soloud `^3.1.0`, `setWaveformFreq` per voice, `filters.bandpass(handle)` | 4.1.7 (resolved): waveform frequency and filters are per **source**, no master output tap | **Synthesis moved to Dart** (`synth_core.dart`); `synth.dart` streams it to SoLoud through a released `setBufferStream` (f32le stereo) |
| `flutter_midi_command 0.5` `send(MidiMessage…)` | 1.4: `sendData(Uint8List, {deviceId, timestamp})` | Phase 4 |
| Package versions | Resolved by CI on 2026-11-03 | Pinned: flutter_soloud ^4.1.7, record ^7.1.2 (record_windows 2.3.0), fftea ^1.5.0, provider ^6.1.5, shared_preferences ^2.5.6 |

## Architecture

* **Dart synth core.** Every voice (sine/saw/tri/square with PolyBLEP,
  formant = saw → 3 bandpasses, brass = saw → lowpass, FM, granular FM,
  pink/white/brown noise with optional resonant bandpass, Karplus–Strong
  pluck) is rendered in Dart. World effects (lowpass/highpass/high-shelf,
  saturation, chorus, phaser≈chorus, delay, Freeverb-style reverb) run on
  the mix. The AEC reference (Phase 5) is the exact output, read from a
  2 s mono ring indexed by output-sample number.
* **Per-layer effects (Phase 2).** `EffectSpec` gained an optional
  `layer`; filters with a layer run per voice (e.g. the 250 Hz drone LP
  in `clumsy_kind_giant`). Global lowpasses are still floored at 1.2 kHz.
* **Rhythm clock lives in the synth.** The brain re-emits the whole
  `rhythmSchedule` every frame; the spec synth re-scheduled hits relative
  to "now" each frame, which machine-gunned beat-0 hits ~21 times/s. The
  synth now runs its own beat clock (tempo from the percussion analyzer)
  and fires a hit when the clock crosses its position in the bar.
* **Pads glide instead of re-spawning** (legato voice-leading using the
  language's voicing in `MusicalState.padMidi`, a new field). Pluck pads
  re-strike on chord change.
* **Brain keeps one language instance** per language id and calls
  `init()` once (spec called `init()` every frame, destroying all state).
  Out-of-context sustained notes now reach `handleOutOfContextNote`.
* **Percussion envelope is per analysis frame** (~46/93 ms), not 10 ms;
  PLL error is measured to the nearest beat.
* **Key detection:** binary scale masks are scaled ×0.85 so a major-key
  passage reports "C Major", not "D Dorian".

## Phase 1 scope

Implemented: §3–§8 (profiles), §10 (needed by the brain), §11.1–§11.4
(all 17 worlds load; Phase 2 refines their sound), §12.1–§12.2 (Tonal),
§13 (Phase 1 subset of the UI). Not yet: AEC/feedback/coupling guard/
AutoTrim (Phase 2/5), other languages + presets (Phase 3), antiphonal
engine + MIDI (Phase 4), native plugin (v1.1).

**Use headphones in Phase 1** — without AEC the mic hears the app.

## Small fixes

* `ChordProgression.current` never returns null (bug #20); cursor clamped
  on load (bug #9).
* `VoiceSpatialRole.left/right/back/opposite` added to §5 (worlds use them).
* `Chord.symbol()` added (reference card lists it).
* MIDI GM programs: 0-based 16 (Drawbar Organ) and 38 (Synth Bass 1).
* `AppState.save()` is a trailing-edge debounce (the spec's version could
  drop the last change); setters added so the UI never calls
  `notifyListeners()` from outside.
* Latency readout shows "unknown" (bug #47).
* Level meter is dB-scaled.

## Phase 2 (Nov 5, 2026)

* **Tonal plays its own progression** — chords held 4–8 beats, next chord
  by weighted random functional transitions, nudged by the player
  (Follow). Drone on the key tonic. Fast key switch on sustained
  accidentals. Not in the spec; from Paul's first test.
* **Noise gate + Sensitivity / Follow** controls (not in the spec).
* **Stray plucks removed**: ambient worlds (washy, choirs, singing child,
  musical sea, giant) have rhythm `none`; ice crystals and broken glass
  ring soft FM bells (`RhythmType.bell`, new).
* **VoiceSpec additions**: `vowelCycleSec` (choirs/sea/wind morph
  ah–oh–oo–eh), `swellSec` (sea/wind swells), `pitchDropSemis/Ms`
  (cajón boom), `pluckBrightness` (softer rhythm plucks).
* **Cajón**: pitch-dropping bass tone, slap = noise crack + body tone,
  attack softened per profile (`cajonAttackSofteningMs`).
* **AEC** (`aec.dart`): bulk delay by decimated cross-correlation
  (0–500 ms, ~1/s) + NLMS with Geigel-style double-talk slow-down. Taps
  capped at 512 on mobile / 1024 on desktop (the spec's 2048–4096 is too
  heavy in Dart). Feedback guard: low analysis confidence freezes key
  changes. No narrow-band feedback suppressor: the synth never plays the
  mic signal, so there is no howl loop to suppress.
* **App lifecycle**: on Android/iOS the output pauses and the mic is
  released when the app is hidden, and both resume on return.
