# Sympatheia

An ambient accompaniment engine: it listens to you play (through a mic or
a line input), works out your key and tempo, and plays along — drones,
chords, rhythm and textures — in one of 17 sound worlds.

**Status: Phase 1** (Tonal language, key following, all sound worlds load,
no echo cancelling yet — use headphones).

## Get the Windows app

Every push builds the app on GitHub:

1. Open the repository's **Actions** tab → latest **Build & test** run.
2. Download the **Sympatheia-windows** artifact (a zip).
3. Unzip and run `sympatheia.exe`. Keep the whole folder together (the
   DLLs and `data/` folder are needed).

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
