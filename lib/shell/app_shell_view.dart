import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:mylittlenotebooks/data/note_environment.dart';
import 'package:mylittlenotebooks/models/nav_level.dart';
import 'package:mylittlenotebooks/models/panel_geometry.dart';
import 'package:mylittlenotebooks/shell/form_factor.dart';
import 'package:mylittlenotebooks/shell/nav_panel.dart';
import 'package:mylittlenotebooks/state/panel_state.dart';

/// The shell View.
///
/// Owns the `LayoutBuilder` because its builder is a *callback* and therefore
/// cannot legally hold hooks. Window width is read here and resolved through
/// the plain [PanelGeometry] functions, so there is one source for the panel's
/// size and nothing derived from it is stored.
///
/// **Form factor decides dock-vs-overlay** (`isDesktopPlatform`), not window
/// width: desktop docks the panel (collapsible, persists across navigation, and
/// narrows on a small window); mobile shows a rail plus a transient overlay.
class AppShellView extends StatelessWidget {
  final PanelState panel;
  final NavLevel navLevel;
  final NoteEnvironment noteEnv;
  final Widget child;

  const AppShellView({
    super.key,
    required this.panel,
    required this.navLevel,
    required this.noteEnv,
    required this.child,
  });

  /// `Cmd+B` on Apple platforms, `Ctrl+B` elsewhere.
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
    final isDesktop = isDesktopFormFactor;

    void togglePanel() {
      // Desktop flips and persists the collapsed preference; mobile opens the
      // transient overlay and leaves intent alone.
      if (isDesktop) {
        panel.toggleCollapsed();
      } else if (panel.overlayOpen) {
        panel.closeOverlay();
      } else {
        panel.openOverlay();
      }
    }

    return CallbackShortcuts(
      // Bound at the shell rather than the panel on purpose: Flutter resolves
      // shortcuts from the focused node upward, so a focused TextField keeps
      // its own Escape handling and this binding does not swallow it (AC16).
      bindings: <ShortcutActivator, VoidCallback>{
        _collapseActivator: togglePanel,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          // The mobile overlay is the topmost surface, so Escape closes it
          // before any route pop.
          if (panel.overlayOpen) {
            panel.closeOverlay();
          } else if (router.canPop()) {
            router.pop();
          }
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

            // Desktop: docked, honouring the user's collapsed preference (and
            // narrowing rather than collapsing on a small window). Mobile: an
            // always-narrow rail, with the expanded panel shown as an overlay.
            final dockedCollapsed =
                isDesktop ? panel.collapsedByUser : true;
            final dockedWidth = isDesktop
                ? PanelGeometry.widthFor(
                    windowWidth: windowWidth,
                    collapsedByUser: panel.collapsedByUser,
                  )
                : PanelGeometry.railWidthFor(windowWidth);
            final railToggle =
                isDesktop ? panel.toggleCollapsed : panel.openOverlay;

            final content = Row(
              children: [
                NavPanel(
                  width: dockedWidth,
                  collapsed: dockedCollapsed,
                  navLevel: navLevel,
                  noteEnv: noteEnv,
                  onToggleCollapsed: railToggle,
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(child: child),
              ],
            );

            final showOverlay = !isDesktop && panel.overlayOpen;
            if (!showOverlay) return content;

            final overlayWidth = PanelGeometry.expandedWidthFor(windowWidth);
            return Stack(
              children: [
                content,
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: panel.closeOverlay,
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.32),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: overlayWidth,
                  // Dismiss after any destination is chosen, so the overlay never
                  // lingers across a route change. The tap still navigates.
                  child: _DismissOnTap(
                    onDismiss: panel.closeOverlay,
                    child: NavPanel(
                      width: overlayWidth,
                      collapsed: false,
                      navLevel: navLevel,
                      noteEnv: noteEnv,
                      onToggleCollapsed: panel.closeOverlay,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Closes the mobile overlay whenever a descendant is tapped, without consuming
/// the tap, so the destination's own handler still runs.
class _DismissOnTap extends StatelessWidget {
  final VoidCallback onDismiss;
  final Widget child;

  const _DismissOnTap({required this.onDismiss, required this.child});

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.deferToChild,
    onPointerUp: (_) => onDismiss(),
    child: child,
  );
}
