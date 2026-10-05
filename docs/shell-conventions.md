# Shell conventions

The conventions this spec exists to establish. Later specs (sources, chat,
studio) plug into these rather than re-deriving them.

## Two regions, and nothing else

The shell is a navigation panel plus a centre content page. No third pane, no
right-hand panel, no bottom dock, and nothing floats over the content.

```
lib/shell/
  app_shell.dart          # Coordinator — HookWidget, reads useProvided
  app_shell_view.dart     # View — owns the LayoutBuilder
  nav_panel.dart          # StatelessWidget, receives a resolved width
  nav_panel_body.dart     # dispatches on NavLevel
  nav_destination_tile.dart
```

## Intent versus presentation

This split is the single most important idea here, and it is what removed a
contradiction that could not otherwise be resolved.

> **Amended (add-notes).** Dock-vs-overlay is now decided by **form factor**
> (`lib/shell/form_factor.dart`), not by window width. The width-derived dock
> breakpoint described here is **retired**; a narrow desktop window narrows the
> panel rather than collapsing it, and the overlay is the mobile form only.

- **Intent** — whether the user collapsed the docked panel. One boolean. The only
  persisted value. Never changed by the app acting on its own.
- **Form factor** — desktop or mobile, read from `defaultTargetPlatform` (with a
  `formFactorOverride` test seam). Desktop **docks**; mobile shows a rail plus a
  transient **overlay**. A build-target decision, not a window-size one.
- **Presentation** — rail or expanded, derived from intent. Window width only
  sets *how wide* the expanded panel is; it never collapses it.

```dart
PanelGeometry.isCollapsed(collapsedByUser: c)          // intent alone
PanelGeometry.widthFor(windowWidth: w, collapsedByUser: c)
```

There is no mode enum and no presentation table, because **a single rule cannot
contradict itself**. Revision 1 of the spec stated two unconditional rules — "at
most 20% of the window" and "at least 180 px" — which cannot both hold below
900 px. The original fix was a width-derived breakpoint; that is now gone,
because it made the app's default 800 px window show a transient overlay that
closed on every navigation. Form factor replaces it: the expanded width is
clamped to `minExpandedWidth..maxExpandedWidth` **and** capped so the centre page
keeps at least `minContentWidth`, so a narrow desktop panel shrinks instead of
disappearing. `panel_geometry_test.dart` asserts the cap.

## Measuring: where window width comes from

Window width is `LayoutBuilder`'s `constraints.maxWidth`, read in
`AppShellView`. It is **never stored**.

- Do **not** use a `PlatformDispatcher`/`View` metrics listener that stashes the
  size in state. A stashed metric is a frame stale during a resize, and the 20%
  cap must be evaluated against the **live** window width.
- Do **not** wrap `widthFor` in `useMemoized`. The function is one comparison
  and two `min`/`max` calls, and the one case where caching would pay — a
  continuous drag — is exactly when nothing is cached, because the inputs change
  every frame. It would also need an extra widget purely to be legal (below).
- `constraints.maxWidth` equals the window width because the shell occupies the
  whole window. The two diverge if that ever stops being true — an embedded
  view, multi-window, Flutter-side chrome.

`LayoutBuilder` is relatively expensive in Flutter. Keep it narrow; it wraps a
`Row`, never a page body.

## Hook rules, and the one place they bite

- `LayoutBuilder`'s `builder` is a **callback**, so no hook may be called inside
  it. The View owns the `LayoutBuilder` and calls the plain `PanelGeometry`
  functions there; the Coordinator above it holds all the hooks.
- Global state is registered in `HookProviderContainerWidget` and read with
  `useProvided<T>()`. Dependencies are constructor-injected.
- `useState` takes **no `keys`** for stored intent: keys reset the value on
  change, which is exactly wrong for a user preference.

### Two traps in `utopia_hooks`

1. **`HookProviderContainerWidget`'s providers map is positional.** The pub.dev
   README shows `HookProviderContainerWidget(providers: {…})`, which does not
   compile against 0.4.26+1. The real signature takes the map as its first
   argument.
2. **`usePersistedState` is asynchronous by design.** Its `value` is `null` until
   `get()` resolves and it flows through `ComputedStateValueInProgress` on the
   first build — an already-completed future still yields. It is right for
   values that may arrive late (drafts, per-account settings) and **wrong** for
   anything that must be correct on frame one. For that, read in `main()` and
   pass the result down as a constructor argument, then seed `useState`
   synchronously:

   ```dart
   final deps = await bootstrapDependencies();   // in main(), before runApp
   runApp(App(preloadedCollapsed: deps.panelCollapsed, ...));
   ```

   This is why panel intent shows up correctly on the first frame with no
   loading state anywhere in the shell.

## State / Hook / View / Coordinator

- **State** (`lib/state/*_state.dart`) — immutable, holds values and actions.
  Imports neither hooks nor Flutter, so it is constructible in a plain test.
- **Hook** (`lib/state/use_*.dart`) — a `use…`-prefixed function returning a
  State. Actions are closures built in the hook body; they mutate `useState`
  values and never *call* hooks.
- **View** (`lib/shell/app_shell_view.dart`) — a `StatelessWidget` that renders a
  State and nothing else.
- **Coordinator** (`lib/shell/app_shell.dart`) — a `HookWidget` that binds the
  two and owns navigation.

State holds **no derived width**. Width depends on the window, which the View
owns; keeping window maths out of the hook is what lets the geometry be tested
with no window at all.

### Testing hooks

`SimpleHookContext` needs no widget tree and no container:

```dart
final ctx = SimpleHookContext(() => usePanelState(preloaded: false, store: store));
ctx.value.toggleCollapsed();
await ctx.waitUntil((s) => s.collapsedByUser);
ctx.dispose();
```

`PanelGeometry` is plain Dart with no Flutter import, so it is tested with a bare
`test()`. If a geometry test ever needs a widget binding or a hook context, a
framework dependency has leaked.

## The route is the single source of truth

Navigation level is **derived** from the open route, never stored:

```dart
NavLevel navLevelFrom(Uri uri)   // a plain function — testable with no router
```

No component keeps a parallel flag, so nothing can drift out of sync with the
rendered page, and there is no half-completed drill-down to restore. **No
navigation state is persisted**; `initialLocation` is always `/`.

`appRouter(repo)` takes the repository as a **constructor argument** because a
`redirect` callback runs outside any `HookContext` — `useProvided` is not
available there. That is the concrete reason the app needs no service locator.
`get_it` is not used.

Drill-down and Settings **push**; they do not replace. `go()` swaps the stack,
which would leave nothing to pop back to.

## Extension points for later specs

| Add | Where |
|---|---|
| A notebook detail section | `lib/models/notebook_section.dart` — the registry, not the widget tree |
| A notebook list row affordance | `NavDestinationTile` — leave room for rename/reorder/delete hit targets |
| Durable notebook storage | `NotebookRepository` — the interface is the seam; the shell does not change |
| A new panel destination | `NavPanelListLevel` / `NavPanelDetailLevel` — both already take a declarative list |

## Deliberately not built

- **Panel sizing by the user.** Removed in spec revision 4. Re-opening it means
  re-introducing the width/breakpoint conflict and the presentation-mode system
  that the removal deleted.
- **Durable notebook data.** In-memory only; a relaunch returning to the three
  seeds is expected, not data loss.
- **Mobile polish.** Android and iOS now get the rail + overlay form
  (`isDesktopFormFactor` false), but a phone-specific layout (hamburger,
  edge-swipe) is not specified.