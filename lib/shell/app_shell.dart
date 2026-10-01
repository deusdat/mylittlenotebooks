import 'package:flutter/material.dart';
import 'package:mylittlenotebooks/models/nav_level.dart';
import 'package:mylittlenotebooks/shell/app_shell_view.dart';
import 'package:mylittlenotebooks/state/panel_state.dart';
import 'package:utopia_hooks/utopia_hooks.dart';

/// The shell Coordinator.
///
/// A [HookWidget] that reads the global [PanelState] and binds the View. It
/// performs no geometry: the navigation level arrives as a value derived from
/// the open route, and the width is resolved in the View.
class AppShell extends HookWidget {
  final Uri uri;
  final Widget child;

  const AppShell({super.key, required this.uri, required this.child});

  @override
  Widget build(BuildContext context) {
    final panel = useProvided<PanelState>();
    return AppShellView(
      panel: panel,
      navLevel: navLevelFrom(uri),
      child: child,
    );
  }
}