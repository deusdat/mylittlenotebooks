import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mylittlenotebooks/app.dart';
import 'package:mylittlenotebooks/bootstrap.dart';
import 'package:mylittlenotebooks/data/note_environment.dart';

/// Application entry point.
///
/// The one `await` before `runApp` is what makes the panel's restored state
/// correct on the very first frame: the stored intent is read here and handed
/// to `App` as a constructor argument, so `usePanelState` can seed `useState`
/// synchronously. Making the UI wait on an async hook instead would render one
/// frame at the default width before snapping to the rail (spec AC8, AC9).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final deps = await bootstrapDependencies();

  runApp(
    App(
      preloadedCollapsed: deps.panelCollapsed,
      store: deps.store,
      repo: deps.notebooks,
      initialNotebooks: deps.initialNotebooks,
      aiConfigs: deps.aiConfigs,
      initialAiConfigs: deps.initialAiConfigs,
      noteEnv: NoteEnvironment(
        notes: deps.notes,
        chatMessages: deps.chatMessages,
        embedding: deps.embedding,
      ),
    ),
  );

  // Boot recovery (spec FR11a): after the first frame, re-embed any note left
  // in-process by an interrupted save. Fire-and-forget; each note commits on
  // its own, so progress is durable.
  unawaited(deps.embedding.recoverAll());
}