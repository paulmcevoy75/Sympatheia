# Sympatheia

An ambient accompaniment engine: it listens to you play (through a mic or
a line input), works out your key and tempo, and plays along — drones,
chords, rhythm and textures — in one of 17 sound worlds.

**Status: Phase 2** (Tonal language with its own progression, key
following, Sensitivity/Follow controls, distinct sound worlds, echo
cancelling for speakers).

## Download

Latest build: **Releases → latest**
(https://github.com/paulmcevoy75/Sympatheia/releases/tag/latest)

* Android: tap `Sympatheia.apk` (allow "install unknown apps"), grant
  microphone access.
* Windows: download `Sympatheia-windows.zip`, unzip, run
  `sympatheia.exe` (keep the folder together).

Under **Input**, choose **Speakers** (echo cancelling on) or
**Headphones**. Bluetooth headphones work, with ~0.2 s extra delay.

## Build it yourself

Requires Flutter (stable) and Visual Studio 2022 with *Desktop development
with C++*.

```
flutter create --platforms=windows --project-name sympatheia --org com.paulmcevoy .
flutter pub get
flutter test
flutter run -d windows
```

(`flutter create` only generates the `windows/` runner folder; it does not
touch `lib/`. Delete the generated `test/widget_test.dart` if it appears.)

## Layout

| File | What it does |
|---|---|
| `lib/input_router.dart` | Mic input, device list, downmix to mono frames, hum detection |
| `lib/analysis.dart` | FFT, chroma, pitch (YIN), onsets, tempo, key detection |
| `lib/percussion.dart` | Beat tracking and 16-step rhythm learning |
| `lib/brain.dart` | Decides what to play each frame |
| `lib/tonal_language.dart` | Key/scale following, chord choice, voice-leading |
| `lib/sound_worlds.dart` | The 17 sound worlds (voices, effects, rhythm, space) |
| `lib/synth_core.dart`, `lib/dsp.dart` | The synthesizer (pure Dart) |
| `lib/synth.dart` | Streams the synth to the speakers via flutter_soloud |
| `lib/audio_engine.dart` | Wires it all together |
| `lib/ui.dart`, `lib/state.dart` | Screen and settings |

See `DEVIATIONS.md` for where this differs from the original spec.
