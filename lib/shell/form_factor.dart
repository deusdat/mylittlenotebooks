import 'package:flutter/foundation.dart';

/// Whether [platform] is a desktop form factor (a dockable sidebar makes sense).
///
/// The navigation panel docks on desktop and uses a transient overlay on
/// mobile. This is a **build target** decision, not a window-size one: a narrow
/// desktop window still gets a docked (narrowed) panel, and mobile always gets
/// the overlay.
bool isDesktopPlatform(TargetPlatform platform) => switch (platform) {
  TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.linux => true,
  TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia => false,
};

/// Test seam. When non-null, the shell uses this platform for the
/// dock-vs-overlay decision instead of `defaultTargetPlatform`.
///
/// Deliberately a **plain** variable rather than a foundation debug var: tests
/// set and clear it in `setUp`/`tearDown`, and `debugAssertAllFoundationVarsUnset`
/// (which runs before tearDown) does not flag it the way
/// `debugDefaultTargetPlatformOverride` would.
TargetPlatform? formFactorOverride;

/// The form factor the shell should render for: the override if set, else the
/// real target platform.
bool get isDesktopFormFactor =>
    isDesktopPlatform(formFactorOverride ?? defaultTargetPlatform);
