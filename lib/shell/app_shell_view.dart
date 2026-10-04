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
    // Read once here so the keyboard binding can resolve intent against the
    // same window width the layout uses. `LayoutBuilder` is a callback and
    // cannot hold this; `MediaQuery` is the fallback the layout also uses.
    final windowWidth = MediaQuery.sizeOf(context).width;
    final dockable = PanelGeometry.isDockable(windowWidth);

    void togglePanel() {
      if (dockable) {
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
          // A narrow-window overlay dismisses first: it is the topmost surface,
          // so Escape must close it before any route pop (spec FR15).
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
            final dockable = PanelGeometry.isDockable(windowWidth);
            final dockedCollapsed = PanelGeometry.isCollapsed(
              windowWidth: windowWidth,
              collapsedByUser: panel.collapsedByUser,
            );

            // On a dockable window the control flips and persists intent; on a
            // narrow one it opens the transient overlay and leaves intent alone
            // (spec FR15).
            final railToggle = dockable ? panel.toggleCollapsed : panel.openOverlay;

            final content = Row(
              children: [
                NavPanel(
                  width: PanelGeometry.widthFor(
                    windowWidth: windowWidth,
                    collapsedByUser: panel.collapsedByUser,
                  ),
                  collapsed: dockedCollapsed,
                  navLevel: navLevel,
                  onToggleCollapsed: railToggle,
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(child: child),
              ],
            );

            // The overlay exists only on a sub-breakpoint window, and only while
            // the user has opened it (spec FR15). On a dockable window the panel
            // is in the layout and there is no scrim.
            final showOverlay = !dockable && panel.overlayOpen;
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

/// Closes the narrow-window overlay whenever a descendant is tapped, without
/// consuming the tap, so the destination's own handler still runs.
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