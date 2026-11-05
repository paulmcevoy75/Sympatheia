// lib/state.dart
//
// AppState — all user-facing state, plus the couple of runtime fields
// that the engine and UI need to read from the same object.
//
// Persisted to SharedPreferences under key 'sympatheia_preset_v1'.
// Every mutating method that represents a *user action* calls
// notifyListeners() and save(). Runtime fields (latestState,
// latestFrame, aecErleDb, etc.) call notifyListeners() only.
//
// The three "coupling mode" methods (§8.3.3, §9.7) live here rather
// than in a separate object because they're logically user state. The
// _couplingModeChangedAt timestamp is a one-way signal to AudioEngine
// — AppState writes it, AudioEngine reads it to detect a mode change
// and reset the AEC filter state.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dsp_profile.dart';
import 'input_router.dart';
import 'models.dart';

class AppState extends ChangeNotifier {
  // ─── Mode & language ─────────────────────────────────────────────
  AppMode mode = AppMode.listen;
  String harmonicLanguageId = 'tonal';
  String soundWorldId = 'tame_impala_fan';

  // Tonal language params
  int manualKeyPc = 0;
  Scale manualScale = kMajor;

  // ─── Sliders (0..1 unless noted) ─────────────────────────────────
  double rhythm = 0.30;
  double drone = 0.45;
  double chords = 0.55;
  double sounds = 0.10;
  double harmony = 0.55;
  double master = 0.35;
  double reverb = 0.45;
  double antiphonalIntensity = 0.70;
  double inputGainDb = 0.0;   // -20..+20
  double midiIntensity = 0.0; // 0 hides MIDI panel

  /// Input sensitivity 0..1. Sets the noise gate (0 = only loud playing
  /// counts, 1 = very quiet playing counts) and how quickly the key
  /// detector commits to a new key.
  double sensitivity = 0.5;

  /// How much the accompaniment follows the notes you play (0 = plays its
  /// own progression in the key, 1 = chords track your notes closely).
  double follow = 0.35;

  // ─── Toggles ─────────────────────────────────────────────────────
  bool tempoFollow = true;
  bool autoTrimEnabled = true;
  bool couplingGuardEnabled = true;
  Duration uiInactivityTimeout = const Duration(seconds: 30);

  // ─── Progression ─────────────────────────────────────────────────
  ChordProgression progression = ChordProgression([
    ProgressionStep(Chord(0, ChordQuality.maj7), 7),
    ProgressionStep(Chord(9, ChordQuality.min7), 0),
  ]);

  // ─── Coupling & tier ─────────────────────────────────────────────
  CouplingMode couplingMode = CouplingMode.openAir;
  bool _couplingModeTouchedByUser = false;
  DateTime? _couplingModeChangedAt;
  DateTime? get couplingModeChangedAt => _couplingModeChangedAt;
  DspProfile? currentProfile;

  // Tier selection state
  double _masterSmoothed = 0.35;
  DspProfile _lastAppliedTier = DspProfile.chamber;
  DateTime _lastTierChange = DateTime(2000);

  // ─── Harmonizer ──────────────────────────────────────────────────
  HarmonyInterval harmonyInterval = HarmonyInterval.diatonic3;
  HarmonyTimbre harmonyTimbre = HarmonyTimbre.organ;
  HarmonizerMode? forcedHarmonizerMode;

  // ─── Multichannel / spatial ──────────────────────────────────────
  int desiredVirtualChannels = 4;
  AntiphonalPattern? forcedAntiphonalPattern;

  // ─── Language-specific parameters ────────────────────────────────
  int renaissanceFinalPc = 2;         // D
  String renaissanceModeName = 'dorian';
  String atonalRowId = 'op25';
  String atonalMode = 'strict';
  String stravinskyCollection = 'octatonic_hw';
  double stravinskyStability = 0.5;

  // ─── Input / Output ──────────────────────────────────────────────
  String? selectedInputDeviceId;
  String? selectedOutputDeviceId;
  List<int>? selectedInputChannels;

  // ─── MIDI ────────────────────────────────────────────────────────
  String? midiDeviceId;

  Map<String, bool> midiLayerEnabled = {
    'rhythm':  false,
    'drone':   true,
    'chords':  true,
    'sounds':  false,
    'harmony': true,
    'bass':    true,
  };

  Map<String, int> midiLayerChannel = {
    'drone':   2,
    'chords':  3,
    'rhythm':  1,
    'sounds':  4,
    'harmony': 5,
    'bass':    6,
  };

  /// Per-layer General MIDI program (0..127), or null for "no program
  /// change sent". Persisted alongside the channel map.
  Map<String, int?> midiLayerProgram = {
    'drone':   89, // Pad 2 (Warm)
    'chords':  52, // Choir Aahs
    'harmony': 16, // Drawbar Organ (0-based GM)
    'bass':    38, // Synth Bass 1 (0-based GM)
    'rhythm':  null,
    'sounds':  null,
  };

  /// Most recent MIDI note event sent to the device. Used by the
  /// MIDI panel's "Last note" readout. Set by AudioEngine.
  NoteEvent? midiLastNote;

  // ─── Live readouts (engine → UI) ─────────────────────────────────
  MusicalState? latestState;
  AnalysisFrame? latestFrame;
  BrainStatus status = BrainStatus.idle;
  double aecErleDb = 0;

  /// Current noise-gate level (linear RMS) — live readout for the meter.
  double gateRms = 0.01;

  // ─── UI state (not persisted) ────────────────────────────────────
  DateTime lastUiInteraction = DateTime.now();
  bool minimalUI = false;

  // ─── Engine → UI updates ─────────────────────────────────────────

  void updateFromAnalysis(AnalysisFrame f) {
    latestFrame = f;
    notifyListeners();
  }

  void updateFromBrain(MusicalState s, BrainStatus st, DspProfile? p) {
    latestState = s;
    status = st;
    currentProfile = p;
    notifyListeners();
  }

  void updateAec(double erle) {
    aecErleDb = erle;
    notifyListeners();
  }

  // ─── Tier selection (called every frame by AudioEngine) ──────────

  /// Update the active DSP profile based on coupling mode and smoothed
  /// master volume. 3-second exponential smoothing, 1.5 s hysteresis.
  void updateProfile(CouplingMode mode, double masterLinear) {
    _masterSmoothed = _masterSmoothed * 0.97 + masterLinear * 0.03;
    final proposed = DspProfile.forMode(mode, _masterSmoothed);

    if (identical(proposed, _lastAppliedTier)) {
      if (!identical(currentProfile, proposed)) {
        currentProfile = proposed;
        notifyListeners();
      }
      return;
    }

    if (DateTime.now().difference(_lastTierChange).inMilliseconds < 1500) {
      return;
    }

    _lastAppliedTier = proposed;
    currentProfile = proposed;
    _lastTierChange = DateTime.now();
    notifyListeners();
  }

  // ─── UI interaction tracking ─────────────────────────────────────

  void touchUI() {
    lastUiInteraction = DateTime.now();
    if (minimalUI) {
      minimalUI = false;
      notifyListeners();
    }
  }

  void setMinimalUI(bool v) {
    if (minimalUI == v) return;
    minimalUI = v;
    notifyListeners();
  }

  // ─── Simple setters (used by the UI) ─────────────────────────────

  void setMode(AppMode m) {
    if (mode == m) return;
    mode = m;
    notifyListeners();
    save();
  }

  void setLanguage(String id) {
    if (harmonicLanguageId == id) return;
    harmonicLanguageId = id;
    notifyListeners();
    save();
  }

  void setWorld(String id) {
    if (soundWorldId == id) return;
    soundWorldId = id;
    notifyListeners();
    save();
  }

  void setRhythm(double v) {
    rhythm = v.clamp(0.0, 1.0);
    notifyListeners();
    save();
  }

  void setDrone(double v) {
    drone = v.clamp(0.0, 1.0);
    notifyListeners();
    save();
  }

  void setChords(double v) {
    chords = v.clamp(0.0, 1.0);
    notifyListeners();
    save();
  }

  void setSounds(double v) {
    sounds = v.clamp(0.0, 1.0);
    notifyListeners();
    save();
  }

  void setHarmony(double v) {
    harmony = v.clamp(0.0, 1.0);
    notifyListeners();
    save();
  }

  void setMaster(double v) {
    master = v.clamp(0.0, 1.0);
    notifyListeners();
    save();
  }

  void setReverb(double v) {
    reverb = v.clamp(0.0, 1.0);
    notifyListeners();
    save();
  }

  void setMidiIntensity(double v) {
    midiIntensity = v.clamp(0.0, 1.0);
    notifyListeners();
    save();
  }

  void setSensitivity(double v) {
    sensitivity = v.clamp(0.0, 1.0);
    notifyListeners();
    save();
  }

  void setFollow(double v) {
    follow = v.clamp(0.0, 1.0);
    notifyListeners();
    save();
  }

  void setAntiphonalIntensity(double v) {
    antiphonalIntensity = v.clamp(0.0, 1.0);
    notifyListeners();
    save();
  }

  void setInputGainDb(double v) {
    inputGainDb = v.clamp(-20.0, 20.0);
    notifyListeners();
    save();
  }

  void setDesiredVirtualChannels(int n) {
    desiredVirtualChannels = n;
    notifyListeners();
    save();
  }

  void setSelectedInputDevice(String? id) {
    selectedInputDeviceId = id;
    notifyListeners();
    save();
  }

  void setManualKey(int pc) {
    manualKeyPc = ((pc % 12) + 12) % 12;
    notifyListeners();
    save();
  }

  void setManualScaleByName(String name) {
    manualScale = kAllScales.firstWhere((s) => s.name == name,
        orElse: () => kMajor);
    notifyListeners();
    save();
  }

  /// Generic notifier for engine-side writes to plain fields.
  void markChanged({bool persist = false}) {
    notifyListeners();
    if (persist) save();
  }

  // ─── Coupling mode (§8.3.3, §9.7) ────────────────────────────────

  /// Explicit user selection. Marks the mode as user-touched so auto-
  /// suggestion won't undo it, timestamps the change so AudioEngine
  /// resets the AEC filter state on its next frame, and persists.
  void setCouplingMode(CouplingMode mode) {
    if (couplingMode == mode) return;
    couplingMode = mode;
    _couplingModeTouchedByUser = true;
    _couplingModeChangedAt = DateTime.now();
    notifyListeners();
    save();
  }

  /// Called when a new input device is selected. Suggests a coupling
  /// mode based on the device class, but only if the user hasn't
  /// already tapped the toggle this session.
  void suggestCouplingModeForDevice(InputDeviceInfo device) {
    if (_couplingModeTouchedByUser) return;
    final suggested = device.klass == InputClass.audioInterface
        ? CouplingMode.direct
        : CouplingMode.openAir;
    if (couplingMode != suggested) {
      couplingMode = suggested;
      _couplingModeChangedAt = DateTime.now();
      notifyListeners();
      // No save() — auto-suggestion is transient. The user tapping the
      // toggle calls setCouplingMode(), which persists.
    }
  }

  /// Called by CouplingGuard override. Marks the mode as user-relevant
  /// so auto-suggestion doesn't undo the override.
  void markCouplingModeTouched() {
    _couplingModeTouchedByUser = true;
  }

  // ─── Persistence ─────────────────────────────────────────────────

  static const String _kPrefsKey = 'sympatheia_preset_v1';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPrefsKey);
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;

      mode = AppMode.values[j['mode'] as int];
      harmonicLanguageId = j['harmonicLanguageId'] as String;
      soundWorldId = j['soundWorldId'] as String;
      manualKeyPc = j['manualKeyPc'] as int;
      manualScale = kAllScales.firstWhere(
        (s) => s.name == j['manualScale'],
        orElse: () => kMajor,
      );

      rhythm = (j['rhythm'] as num).toDouble();
      drone = (j['drone'] as num).toDouble();
      chords = (j['chords'] as num).toDouble();
      sounds = (j['sounds'] as num).toDouble();
      harmony = (j['harmony'] as num).toDouble();
      master = (j['master'] as num).toDouble();
      reverb = (j['reverb'] as num).toDouble();
      antiphonalIntensity = (j['antiphonalIntensity'] as num).toDouble();
      inputGainDb = (j['inputGainDb'] as num).toDouble();
      midiIntensity = (j['midiIntensity'] as num).toDouble();
      sensitivity = (j['sensitivity'] as num?)?.toDouble() ?? 0.5;
      follow = (j['follow'] as num?)?.toDouble() ?? 0.35;

      tempoFollow = j['tempoFollow'] as bool;
      autoTrimEnabled = j['autoTrimEnabled'] as bool;
      couplingGuardEnabled = j['couplingGuardEnabled'] as bool;
      uiInactivityTimeout = Duration(seconds: j['uiTimeoutS'] as int);

      couplingMode = CouplingMode.values[j['couplingMode'] as int];

      harmonyInterval =
          HarmonyInterval.values[j['harmonyInterval'] as int];
      harmonyTimbre =
          HarmonyTimbre.values[j['harmonyTimbre'] as int];
      final fhm = j['forcedHarmonizerMode'] as int?;
      forcedHarmonizerMode =
          fhm == null ? null : HarmonizerMode.values[fhm];

      desiredVirtualChannels = j['desiredVirtualChannels'] as int;

      // Language-specific params
      renaissanceFinalPc = (j['renaissanceFinalPc'] as int?) ?? 2;
      renaissanceModeName =
          (j['renaissanceModeName'] as String?) ?? 'dorian';
      atonalRowId = (j['atonalRowId'] as String?) ?? 'op25';
      atonalMode = (j['atonalMode'] as String?) ?? 'strict';
      stravinskyCollection =
          (j['stravinskyCollection'] as String?) ?? 'octatonic_hw';
      stravinskyStability =
          (j['stravinskyStability'] as num?)?.toDouble() ?? 0.5;

      // I/O
      selectedInputDeviceId =
          j['selectedInputDeviceId'] as String?;
      selectedOutputDeviceId =
          j['selectedOutputDeviceId'] as String?;
      final sic = j['selectedInputChannels'] as List?;
      selectedInputChannels = sic?.map((e) => e as int).toList();

      // MIDI
      midiDeviceId = j['midiDeviceId'] as String?;

      final mle = j['midiLayerEnabled'] as Map<String, dynamic>?;
      if (mle != null) {
        midiLayerEnabled =
            mle.map((k, v) => MapEntry(k, v as bool));
      }
      final mlc = j['midiLayerChannel'] as Map<String, dynamic>?;
      if (mlc != null) {
        midiLayerChannel =
            mlc.map((k, v) => MapEntry(k, v as int));
      }
      final mlp = j['midiLayerProgram'] as Map<String, dynamic>?;
      if (mlp != null) {
        midiLayerProgram = mlp.map(
          (k, v) => MapEntry(k, v is int ? v : null),
        );
      }

      // Progression
      final prog = j['progression'] as Map<String, dynamic>?;
      if (prog != null) {
        progression = ChordProgression.fromJson(prog);
      }

      notifyListeners();
    } catch (e) {
      // Corrupt preset — ignore and continue with defaults.
      debugPrint('AppState.load failed: $e');
    }
  }

  Timer? _saveTimer;

  /// Debounced save (500 ms trailing edge): the LAST change in a burst
  /// is always written.
  Future<void> save() async {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      _doSave();
    });
  }

  /// Write immediately (used on dispose).
  Future<void> flush() async {
    _saveTimer?.cancel();
    await _doSave();
  }

  Future<void> _doSave() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPrefsKey, jsonEncode(toJson()));
    } catch (e) {
      debugPrint('AppState._doSave failed: $e');
    }
  }

  Map<String, dynamic> toJson() => {
        'mode': mode.index,
        'harmonicLanguageId': harmonicLanguageId,
        'soundWorldId': soundWorldId,
        'manualKeyPc': manualKeyPc,
        'manualScale': manualScale.name,
        'rhythm': rhythm,
        'drone': drone,
        'chords': chords,
        'sounds': sounds,
        'harmony': harmony,
        'master': master,
        'reverb': reverb,
        'antiphonalIntensity': antiphonalIntensity,
        'inputGainDb': inputGainDb,
        'midiIntensity': midiIntensity,
        'sensitivity': sensitivity,
        'follow': follow,
        'tempoFollow': tempoFollow,
        'autoTrimEnabled': autoTrimEnabled,
        'couplingGuardEnabled': couplingGuardEnabled,
        'uiTimeoutS': uiInactivityTimeout.inSeconds,
        'couplingMode': couplingMode.index,
        'harmonyInterval': harmonyInterval.index,
        'harmonyTimbre': harmonyTimbre.index,
        'forcedHarmonizerMode': forcedHarmonizerMode?.index,
        'desiredVirtualChannels': desiredVirtualChannels,
        'renaissanceFinalPc': renaissanceFinalPc,
        'renaissanceModeName': renaissanceModeName,
        'atonalRowId': atonalRowId,
        'atonalMode': atonalMode,
        'stravinskyCollection': stravinskyCollection,
        'stravinskyStability': stravinskyStability,
        'selectedInputDeviceId': selectedInputDeviceId,
        'selectedOutputDeviceId': selectedOutputDeviceId,
        'selectedInputChannels': selectedInputChannels,
        'midiDeviceId': midiDeviceId,
        'midiLayerEnabled': midiLayerEnabled,
        'midiLayerChannel': midiLayerChannel,
        'midiLayerProgram': midiLayerProgram,
        'progression': progression.toJson(),
      };
}