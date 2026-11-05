// lib/ui.dart — §13 (Phase 1 subset of the final §14.4 UI)
//
// Flat, three-tone, two-weight, collapsible rows (one open at a time),
// inactivity fade. Phase 1 rows: Language (Tonal + mode/key/scale),
// Sound (worlds, Space, ring), four layer sliders, Input, Output
// (master/reverb/virtual channels). Presets and MIDI arrive in Phases 3–4.

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'audio_engine.dart';
import 'dsp_profile.dart';
import 'harmonic_language.dart';
import 'input_router.dart';
import 'models.dart';
import 'sound_worlds.dart';
import 'state.dart';

const Color kBg = Color(0xFF141416);
const Color kLabel = Color(0xFF8A8A8E);
const Color kValue = Color(0xFFECECEC);
const Color kAccent = Color(0xFFC8954A);

const TextStyle kLabelStyle =
    TextStyle(fontSize: 15, fontWeight: FontWeight.w400, color: kLabel);
const TextStyle kValueStyle = TextStyle(
  fontSize: 15,
  fontWeight: FontWeight.w500,
  color: kValue,
  fontFeatures: [FontFeature.tabularFigures()],
);
const TextStyle kHeadlineStyle =
    TextStyle(fontSize: 28, fontWeight: FontWeight.w500, color: kValue);
const TextStyle kAccentStyle =
    TextStyle(fontSize: 15, fontWeight: FontWeight.w400, color: kAccent);

class SympatheiaApp extends StatelessWidget {
  const SympatheiaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sympatheia',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: const MainScreen(),
    );
  }
}

ThemeData _buildTheme() {
  const colorScheme = ColorScheme.dark(
    primary: kAccent,
    onPrimary: kBg,
    secondary: kAccent,
    onSecondary: kBg,
    surface: kBg,
    onSurface: kValue,
    error: kAccent,
    onError: kBg,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: kBg,
    canvasColor: kBg,
    dividerColor: kLabel,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    sliderTheme: const SliderThemeData(
      trackHeight: 2,
      activeTrackColor: kValue,
      inactiveTrackColor: Color(0x33ECECEC),
      thumbColor: kValue,
      overlayColor: Colors.transparent,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
      trackShape: RectangularSliderTrackShape(),
      showValueIndicator: ShowValueIndicator.never,
    ),
    dividerTheme: const DividerThemeData(color: Color(0x558A8A8E), thickness: 1, space: 1),
  );
}

// ─── MainScreen ────────────────────────────────────────────────────

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  String? _openRowId; // bug #49
  String? _warningMsg;
  Timer? _warningTimer;
  Timer? _inactivityTimer;
  StreamSubscription<String>? _warningSub;

  @override
  void initState() {
    super.initState();
    _warningSub = context.read<AudioEngine>().warnings.listen(_onWarning);
    // bug #48: periodic, not one-shot.
    _inactivityTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _checkInactivity());
  }

  @override
  void dispose() {
    _warningSub?.cancel();
    _warningTimer?.cancel();
    _inactivityTimer?.cancel();
    super.dispose();
  }

  void _onWarning(String msg) {
    if (!mounted) return;
    setState(() => _warningMsg = msg);
    _warningTimer?.cancel();
    _warningTimer = Timer(const Duration(seconds: 6), () {
      if (mounted && _warningMsg == msg) setState(() => _warningMsg = null);
    });
  }

  void _checkInactivity() {
    if (!mounted) return;
    final app = context.read<AppState>();
    if (DateTime.now().difference(app.lastUiInteraction) >
            app.uiInactivityTimeout &&
        !app.minimalUI) {
      app.setMinimalUI(true);
    }
  }

  void _toggleRow(String id) =>
      setState(() => _openRowId = _openRowId == id ? null : id);

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => app.touchUI(),
      onPointerMove: (_) => app.touchUI(),
      onPointerHover: (_) => app.touchUI(),
      child: Scaffold(
        backgroundColor: kBg,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _StatusBar(app: app),
                if (_warningMsg != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_warningMsg!, style: kAccentStyle),
                  ),
                const SizedBox(height: 24),
                Expanded(
                  child: AnimatedOpacity(
                    opacity: app.minimalUI ? 0.15 : 1.0,
                    duration: const Duration(milliseconds: 400),
                    child: IgnorePointer(
                      ignoring: app.minimalUI,
                      child: _Body(
                        app: app,
                        openRowId: _openRowId,
                        onToggleRow: _toggleRow,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final AppState app;
  const _StatusBar({required this.app});

  @override
  Widget build(BuildContext context) {
    final color = switch (app.status) {
      BrainStatus.stable => kValue,
      BrainStatus.modulating || BrainStatus.pedal => kAccent,
      BrainStatus.listening || BrainStatus.idle => kLabel,
    };
    final label = switch (app.status) {
      BrainStatus.stable => 'Stable',
      BrainStatus.modulating => 'Modulating',
      BrainStatus.pedal => 'Pedal',
      BrainStatus.listening => 'Listening',
      BrainStatus.idle => 'Idle',
    };
    return Row(
      children: [
        const Text('Sympatheia', style: kHeadlineStyle),
        const Spacer(),
        Text(label, style: kValueStyle),
        const SizedBox(width: 8),
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ],
    );
  }
}

class _Body extends StatelessWidget {
  final AppState app;
  final String? openRowId;
  final void Function(String) onToggleRow;
  const _Body({required this.app, required this.openRowId, required this.onToggleRow});

  @override
  Widget build(BuildContext context) {
    final state = app.latestState;
    final frame = app.latestFrame;
    final bpm = frame?.tempoBpm;
    return ListView(
      children: [
        Text(
          state == null
              ? 'Waiting for input…'
              : '${state.languageLabel} · ${worldById(state.worldId).name}'
                  '${bpm != null ? ' · ${bpm.round()} BPM' : ''}',
          style: kHeadlineStyle.copyWith(fontSize: 22),
        ),
        const SizedBox(height: 8),
        Text(
          '${_levelMeter(frame?.rmsLevel ?? 0)} · ${_tierLabel(app.currentProfile)}'
          '${state?.chord != null ? ' · ${state!.chord!.symbol()}' : ''}',
          style: kLabelStyle,
        ),
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 8),
        _CollapsibleRow(
          label: 'Language',
          value: app.mode == AppMode.manual
              ? 'Tonal · fixed ${pitchName(app.manualKeyPc)} ${app.manualScale.name}'
              : 'Tonal · follows you',
          isOpen: openRowId == 'language',
          onTap: () => onToggleRow('language'),
          child: _LanguagePanel(app: app),
        ),
        _CollapsibleRow(
          label: 'Sound',
          value: worldById(app.soundWorldId).name,
          isOpen: openRowId == 'sound',
          onTap: () => onToggleRow('sound'),
          child: _SoundPanel(app: app),
        ),
        const SizedBox(height: 8),
        const Divider(),
        const SizedBox(height: 8),
        _SliderRow(label: 'Rhythm', value: app.rhythm, onChanged: app.setRhythm),
        _SliderRow(label: 'Drone', value: app.drone, onChanged: app.setDrone),
        _SliderRow(label: 'Chords', value: app.chords, onChanged: app.setChords),
        _SliderRow(label: 'Sounds', value: app.sounds, onChanged: app.setSounds),
        const SizedBox(height: 8),
        _SliderRow(label: 'Sensitivity', value: app.sensitivity, onChanged: app.setSensitivity),
        _SliderRow(label: 'Follow', value: app.follow, onChanged: app.setFollow),
        const SizedBox(height: 16),
        const Divider(),
        const SizedBox(height: 8),
        _CollapsibleRow(
          label: 'Input',
          value: app.selectedInputDeviceId == null ? 'System default' : 'Selected device',
          isOpen: openRowId == 'input',
          onTap: () => onToggleRow('input'),
          child: _InputPanel(app: app),
        ),
        _CollapsibleRow(
          label: 'Output',
          value: 'Master ${(app.master * 100).round()}%',
          isOpen: openRowId == 'output',
          onTap: () => onToggleRow('output'),
          child: _OutputPanel(app: app),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  static String _levelMeter(double rms) {
    const blocks = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
    // dB-scaled so normal playing moves the meter.
    final db = 20 * log(max(rms, 1e-5)) / ln10; // -100..0
    final idx = ((db + 60) / 60 * 8).floor().clamp(0, 8);
    final buf = StringBuffer();
    for (int i = 0; i < 8; i++) {
      buf.write(i < idx ? blocks[i] : '·');
    }
    return buf.toString();
  }

  static String _tierLabel(DspProfile? p) {
    if (identical(p, DspProfile.direct)) return 'Direct';
    if (identical(p, DspProfile.whisper)) return 'Whisper';
    if (identical(p, DspProfile.hall)) return 'Hall';
    if (identical(p, DspProfile.amplified)) return 'Amplified';
    return 'Chamber';
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final String? valueText;
  const _SliderRow({required this.label, required this.value, required this.onChanged, this.valueText});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 80, child: Text(label, style: kLabelStyle)),
          Expanded(
            child: Slider(value: value.clamp(0.0, 1.0), onChanged: onChanged),
          ),
          SizedBox(
            width: 56,
            child: Text(valueText ?? value.toStringAsFixed(2),
                textAlign: TextAlign.right, style: kValueStyle),
          ),
        ],
      ),
    );
  }
}

class _CollapsibleRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isOpen;
  final VoidCallback onTap;
  final Widget child;
  const _CollapsibleRow({
    required this.label,
    required this.value,
    required this.isOpen,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Text(label, style: kLabelStyle),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(value,
                      style: kValueStyle,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right),
                ),
                const SizedBox(width: 8),
                Icon(isOpen ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    color: kLabel, size: 18),
              ],
            ),
          ),
        ),
        if (isOpen) Padding(padding: const EdgeInsets.only(bottom: 16), child: child),
      ],
    );
  }
}

class _PanelRadio<T> extends StatelessWidget {
  final T value;
  final T? groupValue;
  final String label;
  final ValueChanged<T> onChanged;
  const _PanelRadio({required this.value, required this.groupValue, required this.label, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final selected = value == groupValue;
    return InkWell(
      onTap: () => onChanged(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: selected ? kAccent : kLabel, width: selected ? 4 : 1),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label,
                  style: selected ? kValueStyle : kLabelStyle,
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Language panel ────────────────────────────────────────────────

class _LanguagePanel extends StatelessWidget {
  final AppState app;
  const _LanguagePanel({required this.app});

  @override
  Widget build(BuildContext context) {
    final lang = languageById(app.harmonicLanguageId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(lang.description, style: kLabelStyle),
        const SizedBox(height: 8),
        _PanelRadio<AppMode>(
          value: AppMode.listen,
          groupValue: app.mode == AppMode.manual ? AppMode.manual : AppMode.listen,
          label: 'Follow my playing (detect key)',
          onChanged: app.setMode,
        ),
        _PanelRadio<AppMode>(
          value: AppMode.manual,
          groupValue: app.mode == AppMode.manual ? AppMode.manual : AppMode.listen,
          label: 'Fixed key',
          onChanged: app.setMode,
        ),
        if (app.mode == AppMode.manual) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(width: 80, child: Text('Key', style: kLabelStyle)),
              DropdownButton<int>(
                value: app.manualKeyPc,
                dropdownColor: kBg,
                style: kValueStyle,
                underline: const SizedBox.shrink(),
                items: [
                  for (int i = 0; i < 12; i++)
                    DropdownMenuItem(value: i, child: Text(pitchName(i))),
                ],
                onChanged: (v) {
                  if (v != null) app.setManualKey(v);
                },
              ),
              const SizedBox(width: 24),
              DropdownButton<String>(
                value: app.manualScale.name,
                dropdownColor: kBg,
                style: kValueStyle,
                underline: const SizedBox.shrink(),
                items: [
                  for (final s in kAllScales)
                    DropdownMenuItem(value: s.name, child: Text(s.name)),
                ],
                onChanged: (v) {
                  if (v != null) app.setManualScaleByName(v);
                },
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        const Text('Renaissance, Atonal and Rite languages arrive in Phase 3.',
            style: kLabelStyle),
      ],
    );
  }
}

// ─── Sound panel ───────────────────────────────────────────────────

class _SoundPanel extends StatelessWidget {
  final AppState app;
  const _SoundPanel({required this.app});

  @override
  Widget build(BuildContext context) {
    final worlds = kSoundWorlds.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final w in worlds)
          _PanelRadio<String>(
            value: w.id,
            groupValue: app.soundWorldId,
            label: w.name,
            onChanged: app.setWorld,
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(worldById(app.soundWorldId).description, style: kLabelStyle),
        ),
        const Divider(),
        const SizedBox(height: 8),
        _SliderRow(
          label: 'Space',
          value: app.antiphonalIntensity,
          onChanged: app.setAntiphonalIntensity,
        ),
        _SliderRow(label: 'Reverb', value: app.reverb, onChanged: app.setReverb),
      ],
    );
  }
}

// ─── Input panel ───────────────────────────────────────────────────

class _InputPanel extends StatefulWidget {
  final AppState app;
  const _InputPanel({required this.app});
  @override
  State<_InputPanel> createState() => _InputPanelState();
}

class _InputPanelState extends State<_InputPanel> {
  List<InputDeviceInfo>? _devices;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() => _loading = true);
    final devs = await context.read<AudioEngine>().input.listDevices();
    if (!mounted) return;
    setState(() {
      _devices = devs;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final engine = context.read<AudioEngine>();
    final current = app.selectedInputDeviceId ??
        ((_devices?.isNotEmpty ?? false) ? _devices!.first.id : null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text('Device', style: kLabelStyle),
            const Spacer(),
            IconButton(
              onPressed: _loading ? null : _refresh,
              icon: const Icon(Icons.refresh, size: 18, color: kLabel),
            ),
          ],
        ),
        if (_loading)
          const Text('Scanning…', style: kLabelStyle)
        else if (_devices == null || _devices!.isEmpty)
          const Text('No input devices found', style: kLabelStyle)
        else
          for (final d in _devices!)
            _PanelRadio<String>(
              value: d.id,
              groupValue: current,
              label: d.label,
              onChanged: (_) => engine.selectInput(d),
            ),
        const SizedBox(height: 8),
        _SliderRow(
          label: 'Gain',
          value: (app.inputGainDb + 20) / 40,
          valueText: '${app.inputGainDb >= 0 ? '+' : ''}${app.inputGainDb.toStringAsFixed(0)} dB',
          onChanged: (v) => app.setInputGainDb(v * 40 - 20),
        ),
        const SizedBox(height: 8),
        const Text('You hear Sympatheia through', style: kLabelStyle),
        _PanelRadio<CouplingMode>(
          value: CouplingMode.openAir,
          groupValue: app.couplingMode,
          label: 'Speakers (echo cancelling on)',
          onChanged: (_) => app.setCouplingMode(CouplingMode.openAir),
        ),
        _PanelRadio<CouplingMode>(
          value: CouplingMode.direct,
          groupValue: app.couplingMode,
          label: 'Headphones',
          onChanged: (_) => app.setCouplingMode(CouplingMode.direct),
        ),
        if (app.couplingMode == CouplingMode.openAir)
          Text(
            app.aecErleDb > 0.5
                ? 'Echo removed: ${app.aecErleDb.toStringAsFixed(0)} dB'
                : 'Echo cancelling: listening for the speakers…',
            style: kLabelStyle,
          ),
      ],
    );
  }
}

// ─── Output panel ──────────────────────────────────────────────────

class _OutputPanel extends StatelessWidget {
  final AppState app;
  const _OutputPanel({required this.app});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SliderRow(label: 'Master', value: app.master, onChanged: app.setMaster),
        const SizedBox(height: 8),
        // bug #47: never guess latency.
        const Text('Output latency: unknown', style: kLabelStyle),
      ],
    );
  }
}
