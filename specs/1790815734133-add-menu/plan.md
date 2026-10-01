# Plan: Application Shell & Navigation Panel

**Spec directory:** `1790815734133-add-menu`
**Spec revision:** 4 (streamlined)
**Plan date:** 2026-09-30
**Target toolchain (verified):** Flutter 3.47.0 stable · Dart 3.13.0 · macOS 26.6.2 (arm64)

---

## Approach

Five milestones. The whole panel fits in **one pure function and one boolean.**

### The design in one paragraph

There is exactly one width rule — `clamp(180, 20% of window width, 320)` — and it applies only when the panel is rendered expanded. The breakpoint is not a separate constant; it is where that rule's minimum would break the 20% proportion (`180 ÷ 0.20 = 900`). Below it the panel is a 56 px rail. The user's only stored value is whether they collapsed it, and the app never changes it. That is the entire panel model.

### Why this is smaller than revision 3

Revision 3 carried ~1,450 lines of artifacts, 45 tasks, 11 risks, and three presentation modes. The cause was traceable to a single decision: revision 1 stated *two* unconditional geometry rules — "at most 20% of the window" and "at least 180 px" — which are mutually unsatisfiable below 900 px. That collision forced a mode system to arbitrate, and the mode system forced an overlay drawer as a third escape hatch for narrow windows.

Removing drag-to-resize removes the collision, because with no user-settable width there is only one rule. A single rule cannot contradict itself, so the mode system and the overlay both become unnecessary. This is the whole streamlining argument, and it is recorded in the spec's *Streamlining Record* because it is a requirements change, not a refactor.

**What it costs:** the user cannot set the panel width. That is the entire trade, and it is the only thing that was given up.

### Current-state baseline (verified)

The repository is a pristine `flutter create` template.

| Assumption in `AGENTS.md` (pre-pivot) | Actual | Resolution |
|---|---|---|
| Use `Riverpod` + `@riverpod` codegen | — | Corrected: `utopia_hooks` mandated |
| Use `get_it` in `lib/di.dart` | — | Corrected: dropped for constructor injection |
| `utopia_hooks` is "reference only" | — | Corrected: the mandated dependency |
| Reference clone at `only-ai/utopia-flutter/` | **Does not exist** | Corrected to cite pub.dev |
| App lives in `frontend/` | App is at the **repo root** | Corrected |
| `lib/{services,pages,widgets,models}/` exist | Only `lib/main.dart` | Created in M1 |
| `make riverpod_watcher` exists | **No `Makefile`** | Corrected: no codegen, target gone |
| `.agents/*/instruction.md` personas exist | `.agents/` **does not exist** | Annotated as absent |

Toolchain: CocoaPods 1.16.2 ✅, ninja ✅, clang ✅, **cmake ❌** (Linux only — see R4).

---

## Architecture & Design Decisions

### A. Packages

| Package | Version | Why |
|---|---|---|
| `utopia_hooks` | `^0.4.26+1` | State management (NFR3). SDK `>=3.3.0 <4.0.0` |
| `go_router` | `^18.0.2` | Routing (FR9/FR11/FR13) |
| `shared_preferences` | `^2.5.5` | The one persisted boolean (FR5) |

Three packages, all verified to resolve on Dart 3.13.

**`go_router >= 18.0.2` is pinned deliberately.** 18.0.2 exists to fix a bug where `ShellRoute` chrome was dropped from the semantics tree by the active route's `ModalBarrier`. This app's shell *is* a `ShellRoute`, and AC19 requires every panel control to be semantically labelled — so 18.0.0/18.0.1 would silently regress AC19.

**Rejected: `utopia_widgets`.** Ten niche layout widgets, none matching a nav tile. `Collapsible` animates to *zero* size via `AnimatedAlign`, not to a 56 px rail. Not worth a 0.1.x dependency.

**Rejected: `window_manager`.** Window management is an explicit Non-Goal, and nothing needs it now that narrow windows get a rail.

**Rejected: `usePersistedState`.** Its `value` is null until an async `get()` resolves — it renders through `ComputedStateValueInProgress` on the first build even if the future is already completed. A persisted-collapsed panel would flash the expanded default for a frame. See H.

### B. Directory layout

```
lib/
  main.dart                     # bootstrap: bindings → bootstrap() → runApp
  bootstrap.dart                # async preload + dependency construction
  app.dart                      # HookProviderContainerWidget + MaterialApp.router
  router/
    app_router.dart             # appRouter(repo) — GoRouter, ShellRoute, redirect guard
    routes.dart                 # path constants + builders
  models/
    notebook.dart               # Notebook {id, title, createdAt}
    panel_geometry.dart         # PURE: width formula + collapse decision
    nav_level.dart              # NavLevel sealed type + navLevelFrom(Uri)
    notebook_section.dart       # declarative detail-nav descriptor
  data/
    notebook_repository.dart    # abstract interface
    in_memory_notebook_repository.dart
    panel_state_store.dart      # abstract interface
    prefs_panel_state_store.dart
  state/
    panel_state.dart            # State class — no hook or Flutter imports
    use_panel_state.dart        # usePanelState() global hook
    notebooks_state.dart
    use_notebooks_state.dart
  shell/
    app_shell.dart              # Coordinator: useProvided + view binding
    app_shell_view.dart         # View: LayoutBuilder → resolve → Row
    nav_panel.dart              # rail / panel container
    nav_panel_body.dart         # dispatches list-level vs detail-level content
    nav_panel_list_level.dart   # Add Notebook + notebook list (FR7/FR8)
    nav_panel_detail_level.dart # notebook header + detail nav (FR10)
    nav_destination_tile.dart   # one row/icon — tooltips + semantics (NFR6)
  pages/
    notebooks_home_page.dart
    notebook_detail_page.dart   # placeholder body
    settings_page.dart
    not_found_page.dart
  widgets/
    placeholder_body.dart
test/
  panel_geometry_test.dart      # pure width + collapse — AC2, AC3, AC6, AC18
  panel_state_test.dart         # SimpleHookContext — AC5, AC8, AC9
  panel_state_store_test.dart   # persistence round-trip + corrupt data
  nav_state_machine_test.dart   # list ↔ detail ↔ back — AC12-15, AC17
  app_shell_widget_test.dart    # widget-level geometry + a11y — AC2, AC3, AC6, AC19
  notebook_flow_test.dart       # add/select — AC10, AC11
```

No `.g.dart`, no `part` directives, no `state_store` for width.

### C. The core: `PanelGeometry` (pure, no Flutter import)

The entire panel model. This file is the spec.

```dart
abstract final class PanelGeometry {
  static const double maxWidthFraction = 0.20;
  static const double minExpandedWidth = 180.0;
  static const double maxExpandedWidth = 320.0;
  static const double railWidth = 56.0;

  static double get dockBreakpoint => minExpandedWidth / maxWidthFraction;

  static bool isDockable(double windowWidth) => windowWidth >= dockBreakpoint;

  static bool isCollapsed({
    required double windowWidth,
    required bool collapsedByUser,
  }) =>
      collapsedByUser || !isDockable(windowWidth);

  static double expandedWidthFor(double windowWidth) => math.min(
        maxExpandedWidth,
        math.max(minExpandedWidth, windowWidth * maxWidthFraction),
      );

  static double widthFor({
    required double windowWidth,
    required bool collapsedByUser,
  }) =>
      isCollapsed(windowWidth: windowWidth, collapsedByUser: collapsedByUser)
          ? railWidth
          : expandedWidthFor(windowWidth);
}
```

Two functions and two derived constants. Properties that follow, and they *are* the acceptance criteria:

1. **`expandedWidthFor` can never violate the 20% proportion.** It is only ever called when `isDockable` is true, which means `windowWidth ≥ 900`, which means `0.20 × windowWidth ≥ 180 = minExpandedWidth`. The `math.max` floor is therefore unreachable-but-harmless, retained as a defensive assertion of that invariant. This is the rev-1 contradiction, now structurally impossible rather than adjudicated.
2. **The clamp engages at exactly 1600 px** (`320 ÷ 0.20`), so the panel is exactly 20% from 900–1600 and then holds at 320 px. Continuous at both ends: at 901 px the width is 180.2, at 900 it is 180.
3. **Rail never exceeds the window.** 56 px, and it is the only thing rendered below 900 px, so the centre page always receives `windowWidth − 56`.
4. **`isCollapsed` is one boolean expression.** There is no mode enum, no table, and no state to migrate when the window crosses the breakpoint. Crossing it simply flips the result of `isDockable`.
5. **Nothing here is stored.** Width and presentation are recomputed from `windowWidth` on every layout pass (see F).

### D. Navigation model: routes are the source of truth

`go_router` owns three routes inside a `ShellRoute`:

```
ShellRoute (renders AppShell: nav panel + centre outlet)
├── /                    notebooksHomePage    → panel level: list
├── /notebook/:notebookId notebookDetailPage → panel level: detail
└── /settings            settingsPage         → panel level: list
```

Panel level is **derived**, never stored:

```dart
NavLevel navLevelFrom(Uri uri) => uri.pathSegments.length >= 2 &&
        uri.pathSegments.first == 'notebook'
    ? NavLevelDetail(uri.pathSegments[1])
    : const NavLevelList();
```

A plain function taking a `Uri` — testable with no router at all.

- **FR13 cannot be violated by drift.** No `isInsideNotebook` flag exists to disagree with the rendered page, and no navigation state is persisted, so every launch starts at `/`.
- **FR11 back is native.** `context.pop()` for the on-screen control, `PopScope` for Android/iOS, `CallbackShortcuts` for `Escape`.
- **FR12 needs no special case.** `/settings` is a sibling, so `pop()` returns to whichever of `/` or `/notebook/:id` was underneath.

**The redirect guard**, and the reason `get_it` is not missed:

```dart
GoRouter appRouter(NotebookRepository repo) => GoRouter(
  initialLocation: '/',
  routes: [ShellRoute(builder: …, routes: […])],
  redirect: (context, state) {
    final id = state.uri.pathParameters['notebookId'];
    if (id == null) return null;
    return repo.exists(id) ? null : '/';
  },
);
```

A `redirect` callback runs inside the router's navigation machinery, **outside any `HookContext`** — `useProvided` is unavailable there and there is no widget to hang a `HookWidget` off. Passing the repository as a constructor argument to `appRouter` is therefore the only mechanism available, not a stylistic preference. The same closure-capture logic is why `App` takes `preloaded`, `store`, and `repo` as constructor fields: the providers map is a `Map<Type, Object? Function()>`, so registering state requires closures over the widget's scope.

**Ordering (D5) — creation order, oldest first.**

### E. Back navigation (FR11, FR14, AC14, AC16)

| Affordance | Implementation | Platform |
|---|---|---|
| On-screen back | `context.pop()` in the detail panel and page header | all |
| OS / system back | `PopScope` at the shell | Android, iOS |
| Keyboard back | `CallbackShortcuts({SingleActivator(LogicalKeyboardKey.escape): pop})` | desktop |

Both shortcuts bind at the **shell**, not the panel: Flutter resolves shortcuts from the focused node *upward*, so a focused `TextField` keeps its own `Escape` handling (AC16). Putting it higher is correct, not a bug.

**Scroll restoration (AC13)** is not hand-rolled. go_router preserves a popped route's subtree, so each `/notebook/:notebookId` builds a `CustomTransitionPage` keyed on the notebook id, and the list carries `PageStorageKey('notebook-list')` with the default `keepScrollOffset: true`.

### F. Where window width comes from

Window width is read from a `LayoutBuilder`'s `constraints.maxWidth` at the shell — **not** from a `PlatformDispatcher`/`View` metrics listener that stashes size in state. Two reasons:

1. **Staleness.** A stashed metric is a frame behind during a resize. FR3's "20% of window width" and AC2's exact-width assertion both require the *live* width.
2. **Scope.** The listener approach reimplements `MediaQuery.fromView` by hand, with listener lifecycle and `View.of(context)` plumbing to stay correct under multi-view.

Layout only re-runs when something is dirty, so `widthFor` is not re-entered at all on a static window. **Memoization was considered and rejected:** `widthFor` is one comparison and two `min`/`max` calls, and the one scenario where caching would pay — a continuous panel drag — is precisely when nothing is cached, because the inputs change every frame. Wrapping it in `useMemoized` would add a hook and, worse, require an extra widget because `LayoutBuilder`'s `builder` is a callback and cannot legally hold hooks. That would have created a hazard to fix a problem that does not exist.

`constraints.maxWidth` equals the window width today because the shell occupies the whole window. The two diverge if that stops being true — an embedded view, multi-window, Flutter-side chrome. FR3 says "window width", so that is the case to watch, and it is not worth building for now.

### G. Panel interaction & animation restraint (FR4, NFR2)

- **Collapse/expand control** at the panel's top, above all content, reachable in both forms (FR7's "reachable in the rail" too).
- **No resize handle exists.** FR3 is a Non-Goal; there is no width for a user to set.
- **Animation:** `AnimatedContainer` (≈180 ms) for collapse/expand. Short and interruptible; nothing blocks input or the first frame of a new page (NFR2). No drag, so there is no "animation lags the pointer" failure mode to work around.
- **`Cmd/Ctrl+B`** via `CallbackShortcuts`, `Platform.isMacOS` selecting the modifier — the only intentional `dart:io Platform` branch and the only per-platform behavioral difference (NFR4).

### H. Persistence & hydration (FR5) — and why not `usePersistedState`

```dart
abstract interface class PanelStateStore {
  Future<bool> readCollapsed();
  Future<void> writeCollapsed(bool collapsed);
}
```

One boolean, one key (`nav_panel.collapsed`). Compare revision 3: a versioned JSON blob, four corrupt-data cases, and clamp-on-restore semantics. All of that existed only because there was a width to persist.

`PrefsPanelStateStore` uses `SharedPreferencesAsync` (pub.dev marks the legacy cached `SharedPreferences` API for future deprecation).

**`usePersistedState` is deliberately not used.** It takes a `Future<T?> get()`, and its `value` flows through `ComputedStateValueInProgress` on the first build — **an already-completed future still yields**, so pre-resolving in `main()` does not help. A persisted-collapsed panel would render one frame expanded, then snap to the rail. AC8 would pass on inspection while the app visibly flickered on every launch.

The anti-flash bootstrap does not need a hook at all:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final deps = await bootstrapDependencies();
  runApp(App(preloaded: deps.panelCollapsed, store: deps.store, repo: deps.repo));
}
```

`bootstrapDependencies()` awaits the read **before** `runApp`; `App` passes the result down as a constructor argument; `usePanelState` seeds `useState(preloaded)` **synchronously**. AC8 holds with no flash and no pending branch anywhere in the shell. This matches `AGENTS.md` Directive 6. `usePersistedState` remains right for later specs where late arrival is fine (drafts, per-account settings).

### I. State layer (utopia_hooks, NFR3)

**Registration** — two global states, dependencies by constructor:

```dart
HookProviderContainerWidget(
  {
    PanelState: () => usePanelState(preloaded: collapsed, store: store),
    NotebooksState: () => useNotebooksState(repo),
  },
  child: MaterialApp.router(routerConfig: appRouter(repo), …),
)
```

The providers map is **positional** — the pub.dev README shows a named `providers:` argument, which does not compile against 0.4.26+1. Only *reactive* state is registered; the store and repository are constructor-injected, because registering constants would obscure that `get_it` was removed rather than relocated.

**The State/Hook pair:**

```dart
// panel_state.dart — no hook or Flutter imports
class PanelState {
  final bool collapsedByUser;
  final void Function() toggleCollapsed;
  const PanelState({required this.collapsedByUser, required this.toggleCollapsed});
}

// use_panel_state.dart
PanelState usePanelState({
  required bool preloaded,
  required PanelStateStore store,
}) {
  final collapsed = useState(preloaded);
  return PanelState(
    collapsedByUser: collapsed.value,
    toggleCollapsed: () {
      collapsed.value = !collapsed.value;
      unawaited(store.writeCollapsed(collapsed.value));
    },
  );
}
```

Rules this shape obeys:

- **No derived width in State.** `widthFor` depends on the window, which the View owns. Keeping window math out of the hook is what lets NFR5's tests run with no window.
- **Actions are closures built in the hook body.** They mutate `useState` values and never *call* hooks, so the hook rules hold.
- **`useState` takes no `keys`** — keys would reset the value on change, which is exactly wrong for user intent.
- **No resize path**, so `dragTo` and its persist-on-drag-end timing are gone entirely.

**Hook rules that shape the widget layer:**

- **`LayoutBuilder` belongs in the View**, not the Coordinator. Its `builder` is a *callback*, so no hook may be called inside it. `AppShellView` owns the `LayoutBuilder`, calls `PanelGeometry.widthFor` there, and passes the result down; the Coordinator above it only calls hooks.
- Conditional hooks use `useIf` / `useIfNotNull` / `useMemoizedIf` / `useLet`. The main branch here — list-level vs detail-level content — is naturally a `switch` in the View on an already-resolved `NavLevel` with no hooks involved, so the hazard largely disappears.

**Testing (NFR5).** `SimpleHookContext` is exported from the package root and is the hook test harness — no widget tree, no container:

```dart
final ctx = SimpleHookContext(() => usePanelState(preloaded: false, store: fake));
ctx.value.toggleCollapsed();
await ctx.waitUntil((s) => s.collapsedByUser);
ctx.dispose();
```

### J. Accessibility (NFR6, AC19)

- Every panel control is a Material widget with a non-empty `Semantics(label:)`.
- `FocusTraversalGroup` + explicit `NumericFocusOrder`: collapse control → Add Notebook → notebook items → Settings.
- Rail (icon-only) controls carry `Tooltip` **and** `Semantics(label:)`; `Tooltip` alone does not reliably expose an accessible name.
- Keyboard resize is gone with the resize handle; there is nothing left to make non-pointer-operable.

### K. Theme and window chrome

Material 3 `ColorScheme.fromSeed`, `ThemeMode.system`, no custom themes (Non-Goal). No custom title bar, no `window_manager`.

### L. Decisions still open

| # | Decision | Alternative | Cost to switch |
|---|---|---|---|
| **L1** | 56 px rail on phones | Zero-width panel + hamburger in the centre page's app bar | Medium. Spec parks this as an Open Question for a mobile spec |
| **L2** | FR10 renders unimplemented sections **disabled with tooltips** | Hide them entirely | Trivial — one filter |
| **L3** | Detail nav registry has one enabled section today | Several stubs | Trivial |
| **L4** | Seeded repository starts with **3 notebooks** | Empty with an empty state | Trivial |

---

## Milestones

### M1 — Foundations
- Add the three packages; confirm resolution on Dart 3.13.
- **Verify two load-bearing API shapes against package source, not the README:** `HookProviderContainerWidget`'s providers map is **positional**; `SimpleHookContext`'s constructor signature and that it is exported from the root.
- Create the directory layout; a `Makefile` with `analyze`, `test`, `run_desktop`.
- `lib/bootstrap.dart` — async preload, replacing the rev-3 `lib/di.dart`.
- `lib/app.dart` with `HookProviderContainerWidget`; replace the counter app in `lib/main.dart`.
- Router skeleton with the three paths inside a `ShellRoute`.

**Gate:** `flutter analyze` clean; launches on macOS with no exceptions; both API shapes confirmed.

### M2 — Geometry core
- `models/panel_geometry.dart` exactly as in C, importing nothing from Flutter.
- `test/panel_geometry_test.dart` in **plain `test()`** — no `TestWidgetsFlutterBinding`, no `pumpWidget`, no `HookContext`.

**Gate:** width at 899/900/901/1200/1600/2000; the breakpoint equals 900; `cap ≥ 180` for every dockable width (the invariant behind the derivation); rail never exceeds the window; degenerate widths (`NaN`, negative, zero) degrade sanely.

### M3 — Shell, panel and rail
- `state/panel_state.dart` + `state/use_panel_state.dart`.
- `shell/app_shell.dart` (Coordinator) and `app_shell_view.dart` (View: `LayoutBuilder` → `widthFor` → `Row[NavPanel, Expanded]`).
- `shell/nav_panel.dart`, `nav_destination_tile.dart`.
- Collapse/expand control + `Cmd/Ctrl+B` + `Escape` binding.
- `widgets/placeholder_body.dart`, `pages/notebooks_home_page.dart`.

**Gate:** manual AC1–AC7; widget test asserting width at several sizes via `tester.view.physicalSize`, that a rail exposes every destination with a semantic label, and that the centre page never overflows down to a 320 px window.

### M4 — Persistence & navigation
- `data/panel_state_store.dart` + `prefs_panel_state_store.dart`.
- Wire the preload into `bootstrap.dart` → `App` → `usePanelState`, proving the first frame already holds the restored intent.
- `models/nav_level.dart`, router wiring, `appRouter(repo)` with the redirect guard.
- `state/notebooks_state.dart` + `use_notebooks_state.dart`; `models/notebook.dart`; the seeded repository.
- `nav_panel_body.dart`, `nav_panel_list_level.dart`, `nav_panel_detail_level.dart`.
- Back control, `PopScope`, `CustomTransitionPage` keys.
- Remaining centre pages.

**Gate:** `flutter test` green; manual AC8–AC17.

### M5 — Verification, accessibility, polish
- `flutter analyze` clean, `flutter test` green.
- macOS build + launch (the only platform buildable here).
- Windows/Linux: documented recipe + CI — see R4.
- Accessibility audit against AC19, re-running the assertion that guards R2.
- `docs/shell-conventions.md` — the interface later specs consume.

---

## Dependencies

**External (verified against pub.dev on Dart 3.13):** `utopia_hooks ^0.4.26+1`, `go_router ^18.0.2` (needs Dart ≥ 3.12), `shared_preferences ^2.5.5`.

**Toolchain (present):** Flutter 3.47.0, Dart 3.13.0, Xcode 26.6, CocoaPods 1.16.2, ninja, clang.

**Internal:** M1 → M2 → M3 → M4 → M5, strictly sequential. M2's pure math may start as soon as M1's dependency bump lands.

**Zero backend coupling.** The Non-Goals exclude durable notebook storage, so `NotebookRepository` is in-memory only and nothing waits on a server. The interface is the seam where a real implementation lands, and it is `async` from day one so that swap is source-compatible.

---

## Risks & Mitigations

**R1 — The pub.dev README for `utopia_hooks` does not match the package source.** Verified directly: the README shows `HookProviderContainerWidget(providers: {…})`, but 0.4.26+1's constructor takes the map **positionally**. Copying the README breaks the one line that registers all global state. The package has 35 likes and 246 total downloads, so community workarounds are thin.
→ **Mitigation:** M1 verifies both load-bearing shapes against extracted source before any feature code. Recorded in `AGENTS.md`'s Traps section.

**R2 — A `go_router` upgrade silently breaks AC19.** The 18.0.2 entry exists specifically because `ShellRoute` chrome was dropped from the semantics tree — and this app's shell *is* the panel whose controls must be semantically labelled. A downgrade to 18.0.1, or an unexamined major upgrade, re-opens it.
→ **Mitigation:** pin `^18.0.2`. M3's widget test asserts semantic labels on panel controls — the test, not a comment, is the guard. M5 re-runs it.

**R3 — The derived breakpoint is a coupling that rots silently.** `dockBreakpoint` is `minExpandedWidth ÷ maxWidthFraction`. Tuning the minimum to 220 moves it to 1100 and every threshold in the tests and the acceptance walk-through goes quietly wrong. Nothing crashes.
→ **Mitigation:** it is a single getter and **never a literal anywhere else** — tests reference `PanelGeometry.dockBreakpoint`. M2 asserts the getter equals 900 **and** that `0.20 × w ≥ 180` holds for every dockable `w`, checking the invariant behind the derivation directly rather than trusting it.

**R4 — AC20 (macOS + Windows + Linux) is not fully verifiable from this machine.** macOS arm64 host, no MSVC, no `cmake` (which the Linux desktop build requires). No amount of care here produces a green Windows or Linux build.
→ **Mitigation:** M5 verifies macOS, confirms no code path is platform-conditional except the single `Platform.isMacOS` modifier check, and ships a build recipe plus a CI workflow so AC20 becomes machine-verified. **Flagged as a genuine gap, not something M5 papers over.**

**R5 — Scroll restoration (AC13) is the easiest criterion to half-implement.** "Restore scroll position and selection" is easy to satisfy for the selection and easy to miss for the offset, because the list looks right when it is short.
→ **Mitigation:** `PageStorageKey` + `keepScrollOffset` wired in M4 with per-notebook `CustomTransitionPage` keys, and `nav_state_machine_test.dart` seeds enough notebooks to overflow the viewport, asserts a non-zero offset, drills in, pops, and asserts restoration. A short list cannot make it pass spuriously.

**R6 — `usePersistedState` looks like the obvious tool and silently reintroduces a launch flash.** It is the package's own persistence hook with the right shape, and its async-get semantics are easy to miss.
→ **Mitigation:** H records the decision with the source excerpt showing `ComputedStateValueInProgress` on first build. M4's acceptance is explicitly "the first frame already holds the restored intent", verified by asserting the rendered presentation **on the first frame** rather than after settling.

**R7 — Hook-rule violations compile but fail at runtime, most likely at `LayoutBuilder`.** Its builder is a callback; a hook inside it throws. It is also the natural place to want window width, so the temptation is structural.
→ **Mitigation:** the design puts `LayoutBuilder` in the **View** (a `StatelessWidget`, no hooks) and keeps the width call a plain function there, with hooks confined to the Coordinator above. M3's test rebuilds at several widths specifically to exercise this path.

**R8 — Seeded in-memory data is lost on relaunch, which reads as a bug.** The list returns to three seeds, superficially resembling data loss.
→ **Mitigation:** FR5 is scoped to the collapsed flag, and the Non-Goals are explicit that notebook data has no durable storage. Documented in `docs/shell-conventions.md`; seed names are stable so the reset is predictable.