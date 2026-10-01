import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:mylittlenotebooks/models/nav_level.dart';
import 'package:mylittlenotebooks/models/panel_geometry.dart';
import 'package:mylittlenotebooks/shell/nav_panel.dart';
import 'package:mylittlenotebooks/state/panel_state.dart';

/// The shell View.
///
/// Owns the `LayoutBuilder` because its builder is a *callback* and therefore
/// cannot legally hold hooks — the single most likely place to break the hook
/// rules. Window width is read here and resolved through the plain
/// [PanelGeometry] functions, so there is exactly one source for the panel's
/// size and nothing derived from it is ever stored.
class AppShellView extends StatelessWidget {
  final PanelState panel;
  final NavLevel navLevel;
  final Widget child;

  const AppShellView({
    super.key,
    required this.panel,
    required this.navLevel,
    required this.child,
  });

  /// `Cmd+B` on Apple platforms, `Ctrl+B` elsewhere. The only platform branch
  /// in the app; nothing about the layout itself varies by platform (NFR4).
  static SingleActivator get _collapseActivator =>
      switch (defaultTargetPlatform) {
        TargetPlatform.macOS ||
        TargetPlatform.iOS =>
          const SingleActivator(LogicalKeyboardKey.keyB, meta: true),
        _ => const SingleActivator(LogicalKeyboardKey.keyB, control: true),
      };

  @override
  Widget build(BuildContext context) {
    final router = GoRouter.of(context);
    return CallbackShortcuts(
      // Bound at the shell rather than the panel on purpose: Flutter resolves
      // shortcuts from the focused node upward, so a focused TextField keeps
      // its own Escape handling and this binding does not swallow it (AC16).
      bindings: <ShortcutActivator, VoidCallback>{
        _collapseActivator: panel.toggleCollapsed,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (router.canPop()) router.pop();
        },
      },
      child: Scaffold(
        body: LayoutBuilder(
          builder: (context, constraints) {
            // Prefer the available constraint; fall back to the view size when
            // the shell is placed in an unbounded container.
            final windowWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width;
            return Row(
              children: [
                NavPanel(
                  width: PanelGeometry.widthFor(
                    windowWidth: windowWidth,
                    collapsedByUser: panel.collapsedByUser,
                  ),
                  collapsed: PanelGeometry.isCollapsed(
                    windowWidth: windowWidth,
                    collapsedByUser: panel.collapsedByUser,
                  ),
                  navLevel: navLevel,
                  onToggleCollapsed: panel.toggleCollapsed,
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(child: child),
              ],
            );
          },
        ),
      ),
    );
  }
}