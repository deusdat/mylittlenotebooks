# Tasks: Application Shell & Navigation Panel

**Spec directory:** `1790815734133-add-menu`
**Spec:** [`spec.md`](./spec.md) (revision 4)
**Plan:** [`plan.md`](./plan.md)
**Generated:** 2026-09-30

## Prerequisites

- Read [`spec.md`](./spec.md) — in particular the **Geometry Constants** table, **FR3/FR6**, and the **Streamlining Record**. Most tasks trace directly to one of those.
- Read [`plan.md`](./plan.md) §C (the width formula), §H (persistence, and why not `usePersistedState`), §I (State/Hook pair and hook rules).
- Read `AGENTS.md` **Flutter/Dart Development Instructions** — `utopia_hooks`, State → Hook → View → Coordinator, constructor injection, no Riverpod, no `get_it`.
- **Toolchain:** Flutter 3.47.0 / Dart 3.13.0 (`go_router 18` needs Dart ≥ 3.12).
- The `.agents/` persona instruction files referenced by `AGENTS.md` still do not exist.

**How to read this list**

- Strictly sequential unless `Depends on` says otherwise.
- `Satisfies` names the acceptance criteria a task owns. Not done until demonstrable, not merely written.
- Each milestone ends with a gate. A gate is not "it compiles".
- **T1 is a verification spike**, not feature code. Do not skip it, do not keep it.

---

## Milestone 1 — Foundations

### T0: Add pinned dependencies
- **Files:** `pubspec.yaml`
- **Effort:** Small
- **Depends on:** —
- **Satisfies:** plan §A
- **Steps:**
    1. Add to `dependencies`: `utopia_hooks: ^0.4.26+1`, `go_router: ^18.0.2`, `shared_preferences: ^2.5.5`.
    2. `flutter pub get`; confirm `go_router` resolves to ≥ 18.0.2.
    3. Do **not** add `utopia_widgets`, `window_manager`, `flutter_riverpod`, `riverpod_generator`, `build_runner`, or `get_it`. Plan §A records why for the first two; the rest are removed by the pivot.
    4. Do not run `flutter pub upgrade` for this spec — plan R2 depends on the exact `go_router` minor.

### T1: Verify the two load-bearing `utopia_hooks` API shapes
- **Files:** none (scratch under `/tmp`)
- **Effort:** Small
- **Depends on:** T0
- **Satisfies:** plan R1, R6; AGENTS.md Traps
- **Steps:**
    1. Extract the `utopia_hooks` archive from pub.dev (or read the pub cache) and open `lib/src/base/flutter/hook_provider_container_widget.dart`.
    2. Confirm the constructor takes the providers map **positionally**. The README shows a named `providers:` argument, which does not compile against 0.4.26+1.
    3. Open `lib/src/base/test/simple_hook_context.dart`; confirm `SimpleHookContext` is exported from the package root, and record its constructor signature and `.value` / `.rebuild()` / `.waitUntil(...)` / `.setProvided<T>(...)` / `.dispose()` members.
    4. Open `lib/src/hook/complex/persisted/use_persisted_state.dart` and confirm `value` flows through `ComputedStateValueInProgress` on the first build, validating plan H.
    5. Record findings in the commit message. **If anything differs from plan §B/§I, stop and update the plan** before writing feature code.

### T2: Tooling and directory scaffold
- **Files:** `Makefile` (new), `lib/{router,models,data,state,shell,pages,widgets}/` (new)
- **Effort:** Small
- **Depends on:** T0
- **Satisfies:** plan §A, §B
- **Steps:**
    1. `Makefile` with `analyze` (`flutter analyze`), `test` (`flutter test`), `run_desktop` (`flutter run -d macos`). No codegen targets — there is no build step.
    2. Create the directory layout from plan §B with `.gitkeep` so empty directories are tracked.
    3. Do **not** add a `*.g.dart` gitignore rule — there are no generated files.
    4. Leave `analysis_options.yaml` alone beyond `flutter_lints`; there is no `riverpod_lint` plugin.

### T3: `bootstrap.dart` — async preload and dependency construction
- **Files:** `lib/bootstrap.dart` (new)
- **Effort:** Small
- **Depends on:** T0, T4
- **Satisfies:** NFR3, FR5; plan §H
- **Steps:**
    1. Create `lib/bootstrap.dart` — this **replaces** rev 3's `lib/di.dart`. No service locator.
    2. Expose `Future<BootstrapResult> bootstrapDependencies()` returning a constructed `PanelStateStore`, a `NotebookRepository`, and the preloaded `collapsed` boolean.
    3. `await` the store read here, **before** `runApp`, so intent is available synchronously to the hook (AC8 with no flash).
    4. Make it safe to call more than once — hot restart must not throw.

### T4: `PanelStateStore` and its `SharedPreferencesAsync` implementation
- **Files:** `lib/data/panel_state_store.dart` (new), `lib/data/prefs_panel_state_store.dart` (new)
- **Effort:** Small
- **Depends on:** T0
- **Satisfies:** FR5
- **Steps:**
    1. `abstract interface class PanelStateStore` with `Future<bool> readCollapsed()` and `Future<void> writeCollapsed(bool collapsed)`. Async so it is trivially fakeable in T15/T16.
    2. Implement over `SharedPreferencesAsync`. Do **not** use the legacy `SharedPreferences` API — pub.dev marks it for future deprecation.
    3. One key: `nav_panel.collapsed`. No JSON, no version field, no migration seam — there is exactly one boolean.
    4. A missing key resolves to `false` (expanded), matching AC9. Never throw.

### T5: `Notebook`, `NotebookRepository`, and the seeded in-memory implementation
- **Files:** `lib/models/notebook.dart` (new), `lib/data/notebook_repository.dart` (new), `lib/data/in_memory_notebook_repository.dart` (new)
- **Effort:** Medium
- **Depends on:** T0
- **Satisfies:** D4, D5, D10; FR13
- **Steps:**
    1. `Notebook`: immutable, `id` (String), `title` (String), `createdAt` (DateTime).
    2. `abstract interface class NotebookRepository` with `Future<List<Notebook>> list()`, `Future<Notebook> create()`, `Future<bool> exists(String id)` — all async so a real implementation is a source-compatible swap later.
    3. `InMemoryNotebookRepository` holds a `List<Notebook>` plus a monotonic ordinal. `create()` appends titled `Notebook N` — no dialog, no argument (FR7, D6).
    4. Seed three notebooks at construction so AC1/AC10/AC11 are demonstrable (D10). Seed titles must be stable.
    5. `list()` returns insertion order, oldest first, and must **not** re-sort per call (FR8, D5).
    6. `exists(String id)` backs the router's `redirect` guard (T12).

### T6: Bootstrap `main`, app widget, router skeleton
- **Files:** `lib/main.dart` (rewrite), `lib/app.dart` (new), `lib/router/routes.dart` (new), `lib/router/app_router.dart` (new)
- **Effort:** Medium
- **Depends on:** T1, T2, T3
- **Satisfies:** NFR3, FR1 (skeleton only)
- **Steps:**
    1. `lib/main.dart`: `WidgetsFlutterBinding.ensureInitialized()`, `await bootstrapDependencies()`, then `runApp(App(preloaded: …, store: …, repo: …))`. The `await` before `runApp` is what makes AC8 flash-free.
    2. `lib/app.dart` returns `HookProviderContainerWidget({ … }, child: MaterialApp.router(…))` using the **positional** map from T1.
    3. Register only **reactive** state: `PanelState`, `NotebooksState`. Do **not** register `PanelStateStore` or `NotebookRepository` — they are constructor-injected, and registering constants would obscure that `get_it` was removed rather than relocated.
    4. Build the router with `appRouter(repo)`. Material 3 `ColorScheme.fromSeed`, `ThemeMode.system`; no custom themes.
    5. Declare the three paths in `routes.dart` and wire them inside a `ShellRoute` returning a shell placeholder. Full wiring is T12.
    6. Delete `test/widget_test.dart` — it asserts on the deleted counter app.

### T7: Milestone 1 gate
- **Files:** —
- **Effort:** Medium
- **Depends on:** T6
- **Satisfies:** —
- **Steps:**
    1. `make analyze` reports zero issues.
    2. `flutter run -d macos` launches with no exceptions and shows the shell placeholder.
    3. `pubspec.lock` contains no `riverpod*`, `get_it`, or `build_runner`.
    4. No hydration flash visible on cold launch.

---

## Milestone 2 — Geometry core

No Flutter dependency, no `utopia_hooks` dependency, no widget dependency. If anything here needs `pumpWidget` or a `HookContext`, something leaked in.

### T8: `PanelGeometry` — width formula and collapse decision
- **Files:** `lib/models/panel_geometry.dart` (new)
- **Effort:** Small
- **Depends on:** T2
- **Satisfies:** FR3, FR4, FR6; AC2, AC3, AC6
- **Steps:**
    1. `abstract final class PanelGeometry` with the spec's constants: `maxWidthFraction = 0.20`, `minExpandedWidth = 180.0`, `maxExpandedWidth = 320.0`, `railWidth = 56.0`.
    2. `dockBreakpoint` as a getter `minExpandedWidth / maxWidthFraction` — **derived, never a literal**. FR3 and FR6 are then one rule, not two that can disagree.
    3. `isDockable(double)` as `windowWidth >= dockBreakpoint`.
    4. `isCollapsed({required double windowWidth, required bool collapsedByUser})` as `collapsedByUser || !isDockable(windowWidth)`. One boolean expression — no mode enum, no table.
    5. `expandedWidthFor(double)` as `min(maxExpandedWidth, max(minExpandedWidth, windowWidth * maxWidthFraction))`.
    6. `widthFor({required double windowWidth, required bool collapsedByUser})` returning `railWidth` or `expandedWidthFor`.
    7. No `dart:io`, `dart:ui`, or `package:flutter` imports.

### T9: `panel_geometry_test.dart`
- **Files:** `test/panel_geometry_test.dart` (new)
- **Effort:** Medium
- **Depends on:** T8
- **Satisfies:** AC2, AC3, AC6, AC7, AC18
- **Steps:**
    1. Plain `test()` only — **no** `TestWidgetsFlutterBinding`, no `pumpWidget`, no `SimpleHookContext`.
    2. Width at `899`, `900`, `901`, `1200`, `1600`, `2000`. Assert exactly 20% across 900–1600, 180 at 900, 320 at and above 1600, and continuity at both ends (901 → 180.2).
    3. Assert `dockBreakpoint == 900` **and** that `0.20 × w ≥ 180` for every dockable `w` — the invariant behind the derivation (plan R3). This is the assertion that proves the rev-1 contradiction is structurally impossible.
    4. `isCollapsed` across both sides of the breakpoint crossed with `collapsedByUser` true/false — all four combinations.
    5. Assert the rail never exceeds the window width, and that the centre page's share `windowWidth − widthFor(...)` stays positive down to a 320 px window (AC7).
    6. Assert degenerate widths (`NaN`, negative, zero) degrade sanely rather than producing negative or infinite widths.
    7. Assert `widthFor` is pure — identical inputs give identical outputs.

---

## Milestone 3 — Shell, panel and rail

### T10: `PanelState` and `usePanelState`
- **Files:** `lib/state/panel_state.dart` (new), `lib/state/use_panel_state.dart` (new)
- **Effort:** Small
- **Depends on:** T3, T8
- **Satisfies:** FR2, FR4, FR5, NFR3
- **Steps:**
    1. `panel_state.dart`: immutable `PanelState` holding `bool collapsedByUser` and `void Function() toggleCollapsed`. **No hook or Flutter imports** — it must be constructible in a plain test.
    2. `use_panel_state.dart`: `usePanelState({required bool preloaded, required PanelStateStore store})` seeding `useState(preloaded)` **synchronously** — this is what makes the first frame correct.
    3. `useState` takes **no `keys`** — keys would reset the value on change, exactly wrong for user intent.
    4. `toggleCollapsed` flips the value and writes via `unawaited(store.writeCollapsed(...))`.
    5. Actions are closures built in the hook body; they mutate `useState` values and never *call* hooks, so the hook rules hold.
    6. **Store no width in State.** Width depends on the window, which the View owns.
    7. Note in the file that there is deliberately no `dragTo` and no resize path — FR3 is a Non-Goal (spec D13).

### T11: `AppShell` Coordinator, `AppShellView`, and `NavPanel`
- **Files:** `lib/shell/app_shell.dart` (new), `lib/shell/app_shell_view.dart` (new), `lib/shell/nav_panel.dart` (new)
- **Effort:** Medium
- **Depends on:** T9, T10
- **Satisfies:** FR1, FR3, FR4, AC1, AC2, AC3, AC5, AC7; plan R7
- **Steps:**
    1. `app_shell.dart` is the **Coordinator**: a `HookWidget` calling `useProvided<PanelState>()`, binding the View. It performs no geometry.
    2. `app_shell_view.dart` is the **View**: a `StatelessWidget` rendering a `LayoutBuilder` that reads `constraints.maxWidth`, calls `PanelGeometry.widthFor`, and builds `Row[ NavPanel(width), Expanded(CentrePage) ]`.
    3. **`LayoutBuilder` must stay in the View.** Its `builder` is a callback, so no hook may be called inside it (plan R7). Do **not** introduce `useMemoized` around `widthFor` — plan §F explains why the trade is negative: the function is trivial, and the hook would require an extra widget purely to be legal.
    4. Read width from `constraints.maxWidth`, **never** from a `PlatformDispatcher`/`View` metrics listener. A stashed metric is a frame stale during a resize; FR3 requires the live width (plan §F).
    5. `Expanded` is what guarantees AC7's "the centre page always receives the remainder".
    6. `nav_panel.dart` is a `HookWidget` taking `width` and `collapsed`. Animate with `AnimatedContainer` (≈180 ms) for collapse/expand (NFR2). There is no drag, so there is no animation-under-pointer failure mode.
    7. **No resize handle is rendered** (spec D13). If a divider appears here, stop — FR4's removal is a requirements decision.
    8. Place the collapse/expand control at the top, above all content, so it is reachable in both forms.
    9. Wire the Coordinator into the `ShellRoute` builder from T6.

### T12: `NavDestinationTile` and the collapse shortcut
- **Files:** `lib/shell/nav_destination_tile.dart` (new), `lib/shell/nav_panel.dart`, `lib/shell/app_shell.dart`
- **Effort:** Medium
- **Depends on:** T11
- **Satisfies:** FR4, FR7, FR14, AC5, AC6, AC16, AC19; NFR6
- **Steps:**
    1. One `StatelessWidget` rendering a leading icon plus label, or icon only when collapsed. Collapse is driven by an explicit flag, never by measuring width.
    2. Truncate labels with `Overflow.ellipsis` so long titles fit at 180 px.
    3. Icon-only mode carries **both** `Tooltip` and `Semantics(label:)` — `Tooltip` alone does not reliably expose an accessible name (AC6).
    4. Support `selected:` with a visual state plus `Semantics(selected: true)`, and a disabled state for unimplemented sections with a "not yet available" tooltip.
    5. Use Material widgets so focusability and ink response come for free.
    6. Bind `Cmd+B` / `Ctrl+B` at the shell via `CallbackShortcuts`, `Platform.isMacOS` selecting the modifier — the only intentional `dart:io Platform` branch and the only per-platform difference (NFR4).
    7. Bind `Escape` at the shell for back navigation (T14 wires the handler; bind now so it exists in one place).
    8. Both bind at the **shell**, not the panel: Flutter resolves shortcuts from the focused node upward, so a focused `TextField` keeps its own `Escape` (AC16).

### T13: Placeholder body and home page
- **Files:** `lib/widgets/placeholder_body.dart` (new), `lib/pages/notebooks_home_page.dart` (new)
- **Effort:** Small
- **Depends on:** T6
- **Satisfies:** FR1
- **Steps:**
    1. `PlaceholderBody` takes a title and optional message and renders a centred empty state. Shared by every centre-page destination until real content exists.
    2. `NotebooksHomePage` wraps `PlaceholderBody`. No notebook content here — that is T17.

### T14: `app_shell_widget_test.dart`
- **Files:** `test/app_shell_widget_test.dart` (new)
- **Effort:** Medium
- **Depends on:** T12
- **Satisfies:** AC1, AC2, AC3, AC5, AC6, AC7, AC19; plan R2
- **Steps:**
    1. Drive window size with `tester.view.physicalSize` / `devicePixelRatio`, resetting both in `tearDown`.
    2. Assert the rendered panel width at 900, 1200, 1600, and 2000. **Rebuild at each size** — this exercises the `LayoutBuilder`-in-View path.
    3. Assert that narrowing below 900 renders the rail, and widening back restores the panel at its FR3 width (AC3).
    4. Assert an unrelated rebuild at an unchanged window size produces the same width.
    5. Assert the rail exposes every destination with a non-empty semantic label. **This assertion guards plan R2 and must not be deleted.**
    6. Assert no overflow at 900, 700, 480, and 320 px — the centre page must stay usable (AC7).
    7. Confirm the app builds with no `*.g.dart` and no `riverpod`/`get_it` imports.

### T15: Milestone 3 gate
- **Files:** —
- **Effort:** Small
- **Depends on:** T14
- **Satisfies:** AC1–AC7
- **Steps:**
    1. `make test` green.
    2. Manual: at ≥ 900 px the panel is 20% of the window; drag the **window** edge and confirm the panel tracks proportionally and clamps at 320 px.
    3. Manual: narrow the window below 900 px — the panel becomes a rail, every destination stays reachable, and **no overlay or modal menu appears**.
    4. Manual: `Cmd+B` collapses and expands; `Escape` at a detail route goes back.

---

## Milestone 4 — Persistence & navigation

### T16: Thread the preloaded intent from `main()` into the hook
- **Files:** `lib/bootstrap.dart`, `lib/app.dart`, `lib/state/use_panel_state.dart`
- **Effort:** Small
- **Depends on:** T10, T11
- **Satisfies:** FR5, AC8, AC9; plan R6
- **Steps:**
    1. Confirm `main()` awaits `bootstrapDependencies()` before `runApp` and that it awaits `PanelStateStore.readCollapsed()`.
    2. Thread `preloaded` → `App(preloaded:)` → the provider closure → `usePanelState(preloaded: …)` → `useState(preloaded)`.
    3. **Verify on the first frame, not after settling.** Pump with a stored collapsed state and assert the panel is a rail on the very first rendered frame. This is the assertion that distinguishes this design from `usePersistedState`, which would render one frame expanded (plan R6).
    4. Add a debug-only log of the loaded intent so AC8/AC9 can be diagnosed from the console.
    5. Do **not** add loading UI — a synchronous `useState` seed means no pending branch.

### T17: `panel_state_test.dart` and `panel_state_store_test.dart`
- **Files:** `test/panel_state_test.dart` (new), `test/panel_state_store_test.dart` (new)
- **Effort:** Medium
- **Depends on:** T16
- **Satisfies:** AC5, AC8, AC9, AC18; NFR5
- **Steps:**
    1. Store test: back it with an in-memory fake so no platform channel is touched. Round-trip a written `true` and read it back; a missing key reads `false` (AC9); a wrong-typed value reads `false` without throwing.
    2. Hook test: drive `usePanelState` with `SimpleHookContext(() => usePanelState(preloaded: …, store: fake))`. **No widget tree anywhere in this file** (NFR5).
    3. Default intent is `false` — expanded (AC1/AC9).
    4. `toggleCollapsed` flips the intent and writes exactly once (AC5).
    5. Assert toggling twice writes twice and returns to the original value — the action is a pure flip, not a latch.
    6. Assert **nothing about window width or presentation is written** — the store sees exactly one boolean (FR5).
    7. Call `.dispose()` in `tearDown` so hook effects tear down between tests.
    8. Add a `setProvided<T>` case proving the harness can substitute a dependency mid-test.

### T18: `NavLevel` and `appRouter(repo)`
- **Files:** `lib/models/nav_level.dart` (new), `lib/router/routes.dart`, `lib/router/app_router.dart`
- **Effort:** Medium
- **Depends on:** T6
- **Satisfies:** FR9, FR12, FR13, AC15, AC17
- **Steps:**
    1. Sealed `NavLevel` with `NavLevelList()` and `NavLevelDetail(String notebookId)`, plus `NavLevel navLevelFrom(Uri uri)` as a **plain function, not a hook** — the route stays the source of truth and this is testable with no router.
    2. `GoRouter appRouter(NotebookRepository repo)` — the repository arrives as a **constructor argument**, because a `redirect` callback runs outside any `HookContext` and `useProvided` is unavailable there. This is why `get_it` is not missed.
    3. Three routes inside the single `ShellRoute`: `/`, `/notebook/:notebookId`, `/settings`.
    4. Top-level `redirect` returning `'/'` when `repo.exists(id)` is false (FR13, AC17).
    5. `errorBuilder` → `NotFoundPage`.
    6. `initialLocation: '/'`. **Persist no navigation state** (FR13) — every launch starts at the list.
    7. `/settings` as a sibling route so `pop()` returns to whichever route was underneath (AC15).

### T19: `NotebooksState` and `useNotebooksState`
- **Files:** `lib/state/notebooks_state.dart` (new), `lib/state/use_notebooks_state.dart` (new)
- **Effort:** Medium
- **Depends on:** T5
- **Satisfies:** FR7, FR8, NFR3
- **Steps:**
    1. Immutable `NotebooksState` holding `List<Notebook> notebooks` plus actions, with no hook or Flutter imports.
    2. `useNotebooksState({required NotebookRepository repo})` seeding `useState(repo.listSync)` — the in-memory repository is synchronous today; add async handling only when a real repository needs it.
    3. `create()` returns the **new `Notebook`** so the caller can navigate in one step, making FR7's create-then-open atomic (AC10).
    4. Provide `notebookById(String id)` as a **plain function** on the state. Do **not** store a "currently open" field — that would duplicate the route as a source of truth and reintroduce the drift FR13 forbids.

### T20: `NavPanelBody`, `NavPanelListLevel`, `NavPanelDetailLevel`
- **Files:** `lib/shell/nav_panel_body.dart` (new), `lib/shell/nav_panel_list_level.dart` (new), `lib/shell/nav_panel_detail_level.dart` (new), `lib/models/notebook_section.dart` (new)
- **Effort:** Medium
- **Depends on:** T18, T19
- **Satisfies:** FR7, FR8, FR10, AC10, AC11, AC12
- **Steps:**
    1. `NotebookSection` descriptor (`id`, `label`, `icon`, `enabled`) — the declarative registry FR10 requires. Adding a section must never touch the panel's widget structure.
    2. Provide the registry with **one** section enabled and the rest present but disabled (plan L2). Hiding unimplemented sections instead is a one-line filter.
    3. `NavPanelBody`: a `StatelessWidget` switching exhaustively on the resolved `NavLevel`, passing the collapsed flag down. **No hooks in the switch arms** — route state arrives as a value.
    4. `NavPanelListLevel`: Add Notebook **first**, above the list (FR7, AC1). On activation `await create()` then `context.go('/notebook/${nb.id}')`.
    5. Render the list in repository order with no re-sorting, truncating titles; mark the open notebook with `Semantics(selected: true)`; render an empty-state message when empty (FR8).
    6. Pin Settings at the **bottom**, visually separated from notebooks (FR12).
    7. Give the `ListView` `PageStorageKey('notebook-list')` and leave `keepScrollOffset` at its default — this restores scroll on back (AC13).
    8. `NavPanelDetailLevel`: render a header with the notebook title, then the sections. Render **neither** the notebook list **nor** the Add Notebook button (FR10, AC12). Handle a missing notebook with a not-found body rather than crashing.

### T21: Back control, `PopScope`, and stable route keys
- **Files:** `lib/shell/nav_panel_detail_level.dart`, `lib/pages/notebook_detail_page.dart`, `lib/router/app_router.dart`, `lib/shell/app_shell.dart`
- **Effort:** Medium
- **Depends on:** T20
- **Satisfies:** FR11, FR14, AC13, AC14, AC16
- **Steps:**
    1. On-screen back control calling `context.pop()`, in both the panel and the page header.
    2. `PopScope` at the shell so Android/iOS system back pops go_router's stack natively (AC14).
    3. Point T12's `Escape` shortcut at the same handler, so on-screen, OS, and keyboard share one path (FR11).
    4. Build `/notebook/:notebookId` with a `CustomTransitionPage` keyed on the notebook id, giving each notebook retained route state.
    5. Rely on go_router preserving a popped route's subtree plus `PageStorageKey` from T20. Do not hand-roll a scroll cache (plan R5).
    6. After popping, nothing may be marked selected — no notebook is open at list level (AC13).

### T22: Remaining centre pages
- **Files:** `lib/pages/notebook_detail_page.dart` (new), `lib/pages/settings_page.dart` (new), `lib/pages/not_found_page.dart` (new)
- **Effort:** Small
- **Depends on:** T18, T13
- **Satisfies:** FR12, Non-Goals (no notebook content)
- **Steps:**
    1. `NotebookDetailPage` renders the notebook title plus `PlaceholderBody`. **No sources, notes, or artifacts** — an explicit Non-Goal.
    2. `SettingsPage` renders `PlaceholderBody`. It exists to prove the destination is reachable from both levels (AC15).
    3. `NotFoundPage` for the router's `errorBuilder`, with a control back to `/`.
    4. Wire all three into `app_router.dart`.

### T23: `nav_state_machine_test.dart` and `notebook_flow_test.dart`
- **Files:** `test/nav_state_machine_test.dart` (new), `test/notebook_flow_test.dart` (new)
- **Effort:** Large
- **Depends on:** T21
- **Satisfies:** AC10, AC11, AC12, AC13, AC14, AC15, AC17
- **Steps:**
    1. `/` → `/notebook/x` swaps the panel to detail content in **both** forms — panel and rail (AC12).
    2. Assert the notebook list and Add Notebook button are absent inside a notebook.
    3. Back restores the list, the Add button, and the previous scroll offset. Seed enough notebooks to overflow the viewport, assert a **non-zero** offset before drilling in, then assert restoration after popping — a short list cannot make this pass spuriously (plan R5).
    4. Assert nothing is marked selected after back.
    5. Assert `Escape` and the on-screen control produce the same result (AC14, AC16).
    6. Assert `/settings` opens from both levels and returns to the level it was opened from (AC15).
    7. Assert an unknown notebook id redirects to `/`, and that a fresh app always starts at `/` (AC17).
    8. Add a pure unit test for `navLevelFrom` covering `/`, `/settings`, `/notebook/x`, and unknown shapes — no router required.
    9. Notebook flow: Add creates `Notebook N`, appends at the **end**, and opens it with **no dialog** (AC10); selecting opens and marks active (AC11); Add is the first focusable element (AC1); the seeded three render in stable order; the empty state renders when empty.

### T24: Milestone 4 gate
- **Files:** —
- **Effort:** Small
- **Depends on:** T23
- **Satisfies:** AC8, AC9, AC10–AC17
- **Steps:**
    1. `make test` green.
    2. Manual: collapse, quit, relaunch — collapsed, with **no flash of the expanded panel first** (AC8).
    3. Manual: expanded, quit, relaunch — expanded. The app never recorded a collapse the user did not perform (AC9).
    4. Manual: add a notebook, drill in, back — the new notebook persists in the list for the session, and back restores scroll with nothing marked selected.
    5. Confirm the persisted store contains exactly one boolean and no width or presentation value.

---

## Milestone 5 — Verification, accessibility, polish

### T25: Accessibility audit and assertions
- **Files:** `test/app_shell_widget_test.dart`, plus fixes wherever it surfaces a gap
- **Effort:** Medium
- **Depends on:** T24
- **Satisfies:** NFR6, AC6, AC19
- **Steps:**
    1. Tab through every panel control; assert each is focusable with a non-empty `Semantics(label:)` (AC19).
    2. Assert `FocusTraversalGroup` with explicit `NumericFocusOrder` yields: collapse control → Add Notebook → notebook items → Settings.
    3. Assert every rail icon carries **both** a `Tooltip` and a semantic label (AC6).
    4. Confirm T14's semantic-label assertion is still in place — **it is the guard for plan R2 and must survive refactors.**

### T26: Animation restraint pass
- **Files:** `lib/shell/nav_panel.dart`
- **Effort:** Small
- **Depends on:** T24
- **Satisfies:** NFR2
- **Steps:**
    1. Confirm no animation blocks input or delays the first frame of a new page.
    2. Confirm collapse/expand is ≈180 ms and interruptible.
    3. Confirm no drag-related animation code remains from any earlier draft — with no drag there is nothing to suspend (plan §G).

### T27: Cross-platform build verification and CI
- **Files:** `.github/workflows/ci.yml` (new), `docs/desktop-build.md` (new)
- **Effort:** Large
- **Depends on:** T24
- **Satisfies:** AC20, NFR4; plan R4
- **Steps:**
    1. Verify `flutter build macos` succeeds here and the app launches — the only platform buildable on this host (no MSVC, no `cmake`).
    2. Write `docs/desktop-build.md` with prerequisites and exact commands for all three desktop targets.
    3. Add a CI workflow running `flutter analyze`, `flutter test`, and `flutter build` for **macOS, Windows, and Linux**, so AC20 becomes machine-verified. This is the mitigation for plan R4 — **a local green Windows/Linux build is impossible here and CI is the substitute, not an optional extra.**
    4. Grep the diff for any `Platform.is*` branch other than the single deliberate modifier check, confirming no per-platform layout divergence (NFR4).
    5. Confirm `go_router` still resolves to ≥ 18.0.2 (plan R2).
    6. CI must build with **no** code-generation step installed.

### T28: `docs/shell-conventions.md`
- **Files:** `docs/shell-conventions.md` (new)
- **Effort:** Medium
- **Depends on:** T24
- **Satisfies:** the spec's purpose — conventions later specs plug into
- **Steps:**
    1. Document the two-region layout and the intent-vs-presentation split, including why presentation is never stored.
    2. Document the `PanelGeometry` contract and the derived-breakpoint rule, and that panel state is the **only** persisted value — so notebook data resetting on relaunch is expected, not data loss (plan R8).
    3. Document the route-as-source-of-truth rule: no component keeps a parallel navigation flag.
    4. Document the declarative registries as the extension points for the sources, chat, and studio specs.
    5. Document that window width comes from `LayoutBuilder`'s `constraints.maxWidth` and is **never stored**; note `LayoutBuilder` is relatively expensive in Flutter, so keep it narrow.
    6. Document the positional `HookProviderContainerWidget` map and the rule that `LayoutBuilder`'s callback cannot hold hooks — both non-obvious, both regress silently.
    7. Document the DI model: constructor injection, no service locator, why `appRouter` takes the repository as a parameter, and that `usePersistedState` is right for late-arriving values but wrong for frame-one values.
    8. Record the streamlining decision (no drag, no overlay) and its rationale, so a later spec proposing panel sizing knows the cost it is re-opening.

### T29: Final gate
- **Files:** —
- **Effort:** Medium
- **Depends on:** T25, T26, T27, T28
- **Satisfies:** all
- **Steps:**
    1. `make analyze` reports zero issues.
    2. `make test` green, including the whole AC18 suite.
    3. `pubspec.lock` contains no `riverpod*`, `get_it`, or `build_runner`.
    4. Walk every acceptance criterion AC1–AC20 and record pass/fail against the running app. AC20 is satisfied by CI, not locally.
    5. Confirm no `TODO` markers remain except those explicitly deferred.
    6. Only then report status. Do not claim AC20 locally verified.

---

## Traceability

| AC | Tasks |
|---|---|
| AC1 | T10, T20, T23 |
| AC2, AC3 | T8, T9, T11, T14 |
| AC4 | T14, T15 |
| AC5 | T8, T12, T14, T17 |
| AC6 | T8, T9, T12, T14, T25 |
| AC7 | T9, T11, T14, T15 |
| AC8, AC9 | T4, T16, T17, T24 |
| AC10, AC11 | T5, T19, T20, T23 |
| AC12 | T18, T20, T23 |
| AC13 | T20, T21, T23 |
| AC14 | T18, T21, T23 |
| AC15 | T18, T20, T22, T23 |
| AC16 | T12, T21, T23 |
| AC17 | T5, T18, T23 |
| AC18 | T8, T9, T17 |
| AC19 | T12, T14, T25 |
| AC20 | T27 |

## Deferred to later specs (not tasks here)

- Durable notebook storage and its on-disk format (spec Open Questions).
- Rename, reorder, and delete for notebooks — the list row from T20 must tolerate these hit targets later.
- Panel sizing by the user, if ever needed (spec D13, *Streamlining Record*). Re-opening it means re-introducing the width/breakpoint conflict and the mode system that was removed.
- An overlay / modal drawer menu for phones (spec D1, Open Questions).
- Zero-width panel plus hamburger instead of the rail on phones (plan L1).
- Android and iOS build verification (spec Open Questions).
- `usePersistedState` for settings or drafts in later specs (plan §H).
- **`AGENTS.md`'s Go section** still describes a `backend/` tree that does not exist here. The Flutter section was corrected during the pivot; the Go section was out of scope.