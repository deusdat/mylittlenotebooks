import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mylittlenotebooks/data/notebook_repository.dart';
import 'package:mylittlenotebooks/pages/not_found_page.dart';
import 'package:mylittlenotebooks/pages/notebook_detail_page.dart';
import 'package:mylittlenotebooks/pages/notebooks_home_page.dart';
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
GoRouter appRouter(NotebookRepository repo) => GoRouter(
  initialLocation: '/',
  routes: [
    ShellRoute(
      builder: (context, state, child) =>
          AppShell(uri: state.uri, child: child),
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const NotebooksHomePage(),
        ),
        GoRoute(
          path: '/notebook/:notebookId',
          pageBuilder: (context, state) {
            final notebookId = state.pathParameters['notebookId']!;
            // A stable per-notebook key gives each notebook its own retained
            // route state, which is what restores scroll position on back
            // (spec AC13).
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