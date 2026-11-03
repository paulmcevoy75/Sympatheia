// lib/main.dart — entry point.
//
// Load the saved preset BEFORE the first frame (no flash of defaults);
// start the audio engine AFTER the first frame so the UI paints at once.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'audio_engine.dart';
import 'sound_worlds.dart';
import 'state.dart';
import 'ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Dev-only check: AppState's default world must be the registered default.
  assert(
    AppState().soundWorldId == kDefaultWorld.id,
    'AppState default soundWorldId must equal kDefaultWorld.id',
  );

  final app = AppState();
  await app.load();
  if (!kSoundWorlds.containsKey(app.soundWorldId)) {
    app.soundWorldId = kDefaultWorld.id;
  }

  final engine = AudioEngine(app);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        Provider<AudioEngine>.value(value: engine),
      ],
      child: const SympatheiaApp(),
    ),
  );

  unawaited(engine.start().catchError((Object e) {
    debugPrint('AudioEngine.start failed: $e');
  }));
}
