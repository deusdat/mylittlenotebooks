import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mylittlenotebooks/data/note_environment.dart';
import 'package:mylittlenotebooks/data/notebook_repository.dart';
import 'package:mylittlenotebooks/pages/not_found_page.dart';
import 'package:mylittlenotebooks/pages/note_editor_page.dart';
import 'package:mylittlenotebooks/pages/notebook_detail_page.dart';
import 'package:mylittlenotebooks/pages/notebooks_home_page.dart';
import 'package:mylittlenotebooks/pages/notes_overview_page.dart';
import 'package:mylittlenotebooks/pages/settings_page.dart';
import 'package:mylittlenotebooks/shell/app_shell.dart';

/// The route table.
///
/// [repo] arrives as a constructor argument rather than being resolved from a
/// locator because `redirect` runs inside the router's navigation machinery,
/// *outside* any hook context — `useProvided` is not available there, and there
/// is no widget to hang a hook off. This is the concrete reason the app needs no
/// service locator.
///
/// Navigation state is never persisted: `initialLocation` is always `/`, so
/// every launch starts at the notebook list and there is no half-completed
/// drill-down to restore (spec FR13).
GoRouter appRouter(NotebookRepository repo, NoteEnvironment noteEnv) => GoRouter(
  initialLocation: '/',
  routes: [
    ShellRoute(
      builder: (context, state, child) =>
          AppShell(uri: state.uri, noteEnv: noteEnv, child: child),
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const NotebooksHomePage(),
        ),
        GoRoute(
          path: '/notebook/:notebookId',
          pageBuilder: (context, state) {
            final notebookId = state.pathParameters['notebookId']!;
            return CustomTransitionPage<void>(
              key: ValueKey('notebook-$notebookId'),
              transitionDuration: const Duration(milliseconds: 150),
              child: NotebookDetailPage(notebookId: notebookId),
              transitionsBuilder:
                  (context, animation, secondaryAnimation, child) =>
                      FadeTransition(opacity: animation, child: child),
            );
          },
        ),
        GoRoute(
          path: '/notebook/:notebookId/notes',
          builder: (context, state) => NotesOverviewPage(
            env: noteEnv,
            notebookId: state.pathParameters['notebookId']!,
          ),
        ),
        // The literal `new` segment is declared before the `:noteId` param so a
        // new-note route is not captured as a note id.
        GoRoute(
          path: '/notebook/:notebookId/note/new',
          pageBuilder: (context, state) => CustomTransitionPage<void>(
            key: const ValueKey('note-new'),
            transitionDuration: const Duration(milliseconds: 150),
            child: NoteEditorPage(
              env: noteEnv,
              notebookId: state.pathParameters['notebookId']!,
              noteId: null,
            ),
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) =>
                    FadeTransition(opacity: animation, child: child),
          ),
        ),
        GoRoute(
          path: '/notebook/:notebookId/note/:noteId',
          pageBuilder: (context, state) {
            final noteId = state.pathParameters['noteId']!;
            return CustomTransitionPage<void>(
              key: ValueKey('note-$noteId'),
              transitionDuration: const Duration(milliseconds: 150),
              child: NoteEditorPage(
                env: noteEnv,
                notebookId: state.pathParameters['notebookId']!,
                noteId: noteId,
              ),
              transitionsBuilder:
                  (context, animation, secondaryAnimation, child) =>
                      FadeTransition(opacity: animation, child: child),
            );
          },
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => const SettingsPage(),
        ),
      ],
    ),
  ],
  errorBuilder: (context, state) => const NotFoundPage(),
  redirect: (context, state) {
    final notebookId = state.pathParameters['notebookId'];
    if (notebookId == null) return null;
    return repo.exists(notebookId) ? null : '/';
  },
);
