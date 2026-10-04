# Feature: Application Shell & Navigation Panel

**Spec directory:** `1790815734133-add-menu`
**Feature name:** `add-menu`
**Revision:** 5 — a narrow window can now open the panel as a temporary overlay on explicit user intent. Revision 4 streamlined (removed drag-to-resize and the overlay drawer; two presentation modes; one persisted boolean). See the "Revision 5 Record" and the "Streamlining Record".

## Context

This app is a Flutter research assistant in the mold of NotebookLM: the user collects sources into *notebooks*, then interacts with that material in a work area. Desktop is the primary target, but the codebase must not assume a wide window, so the shell needs to degrade sensibly on narrow ones.

Today there is no shell at all: no navigation model, no way to move between a list of notebooks and the contents of one notebook. This spec defines the **outer shell and navigation model only** — a navigation panel plus a centre content page, and the transitions between "browsing notebooks" and "inside a notebook". It is the first spec, so it establishes the layout, routing, and state conventions that later features (sources, chat, studio) plug into.

## Goals

- Establish a shell: navigation panel + centre content page, and nothing else.
- Size the panel as a fixed proportion of the window, within sane bounds — no user resizing.
- Collapse the panel to an icon rail on narrow windows, and to a rail on any window when the user asks.
- Restore the user's collapsed/expanded choice on next launch.
- Provide a primary navigation action — **Add Notebook** — at the top of the panel.
- List notebooks in the panel; selecting one drills into that notebook.
- Support drill-down and back navigation: inside a notebook the panel shows that notebook's own navigation, with a back control.
- Pin a Settings destination to the bottom of the panel.
- Build and run on macOS, Windows, and Linux from the same codebase.

## Non-Goals

- **No panel resizing.** The user cannot drag the panel wider or narrower. Panel width is derived from the window.
- **No persistent overlay on wide windows.** When the window is wide enough to dock the panel, it is docked; it never floats over the content. A floating overlay is used **only** on a narrow window, only while the user has explicitly opened it, and it dismisses on the first navigation (FR15).
- **No source ingestion.** No file upload, URL capture, YouTube import, or document parsing.
- **No AI features.** No chat panel, no question answering, no citations, no summarization, no audio or video overviews, mind maps, or reports.
- **No notebook content.** The centre page inside a notebook renders a placeholder body.
- **No notebook data persistence.** Notebook records live behind a repository abstraction backed by seeded in-memory data. Durable storage is deferred.
- **No window management.** No custom title bar, no tray icon, no multi-window support.
- **No theming or localisation.** Material 3 defaults, system brightness.
- **No mobile application.** The shell must not require changes to become one, but no mobile platform is built or verified here.

## Definitions

- **Rail** — the panel collapsed to a fixed 56 px strip of icons. Its persistent presentation on narrow windows.
- **Panel** — the panel expanded to a derived width, showing icons with labels.
- **Overlay panel** — the panel shown **over** the centre page on a narrow window, opened on demand (FR15). It is not docked, does not contribute to layout width, and is transient.
- **Docking breakpoint** — the window width below which the panel is shown as a rail. Derived, not chosen independently: see FR6.
- **User intent** — whether the user collapsed the panel. The single persisted value. It is never changed by the app acting on its own. Distinct from the transient overlay, which is not persisted.

---

## Requirements

### Functional Requirements

- **FR1 — Shell layout.** The shell renders exactly two regions: a navigation panel and a centre content page. There is no third pane, no right-hand panel, no bottom dock, and nothing floats over the content.

- **FR2 — Intent is never automatic.** The panel is expanded unless the user collapsed it. The stored intent is never changed by the app acting on its own — not on navigation, not on content change, not on window resize. Changing the window size may change how the panel is *presented* (FR6), but must never change what the user *chose*.

- **FR3 — Panel width.** In panel form the width is `clamp(180, 20% of window width, 320)` logical pixels, where the 20% term uses the live window width. The panel therefore occupies exactly 20% of the window between 900 and 1600 px, is 180 px at the bottom of that range, and stops growing at 320 px. There is no resize handle and no user-settable width.

- **FR4 — Collapse and expand.** The user can collapse the panel to the rail via an explicit control and a keyboard shortcut, and expand it again. The rail preserves access to every destination through icons with tooltips. Collapsing and expanding never changes the window-derived width.

- **FR5 — Persisted panel state.** Exactly one value is written to disk and restored on next launch: whether the panel is collapsed. Panel width is derived, never stored. Presentation is never persisted — it is recomputed from the window width at startup, so a launch on a narrow window and a launch on a wide one both restore the user's choice correctly.

- **FR6 — Derived docking breakpoint.** The breakpoint is the window width below which a panel of the minimum sane width (180 px) would exceed 20%. It is therefore **derived from FR3 rather than chosen independently**: `breakpoint = 180 ÷ 0.20 = 900 px`.

  - **At or above 900 px**: intent selects the presentation — expanded is a **panel** at the FR3 width; collapsed is the **rail**.
  - **Below 900 px**: the panel is a **rail** by default, regardless of intent. The expanded intent is remembered and takes effect again when the window widens. The user **can still open the panel on demand as a temporary overlay** (FR15).
  
  Because FR3's width rule and FR6's breakpoint derive from the same two numbers, a panel can never violate the 20% proportion: below the breakpoint the panel is not rendered in expanded form as part of the layout at all. The FR15 overlay is not part of the layout — it floats over the centre page — so the proportion still holds for the docked panel.

- **FR7 — Add Notebook action.** The top of the panel contains a single **Add Notebook** button. Activating it creates a notebook, appends it to the end of the list, and opens it in the centre page. The new notebook is named automatically (`Notebook N`) and no naming dialog is shown. The button is reachable in both the panel and the rail.

- **FR8 — Notebook list.** Below the Add Notebook button, the panel lists notebooks in **creation order, oldest first, newest appended last**. The order is stable across the session. The open notebook is visually marked. An empty repository renders an explicit empty-state message.

- **FR9 — Drill-down.** Activating a notebook pushes a route for it onto the navigation stack. This is a real route push, not an in-panel state swap, so platform back affordances work natively.

- **FR10 — Notebook detail navigation.** While inside a notebook, the panel shows that notebook's own detail navigation instead of the notebook list and the Add Notebook button. Detail navigation is generated from a declarative registry: a header identifying the notebook, then sections. Only implemented sections are enabled; the rest render disabled with a "not yet available" tooltip. Adding a section is a change to the registry, not to the panel's widget structure.

- **FR11 — Back navigation.** Inside a notebook, a back control returns to the notebook list, restoring the list and the Add Notebook button. Back works via the on-screen control, the platform back affordance (Android system back, iOS gesture), and an `Escape` keyboard shortcut. Returning restores the notebook list's scroll position and leaves no notebook marked as selected.

- **FR12 — Settings destination.** A Settings destination is pinned to the bottom of the panel in both forms — panel and rail — visually separated from notebooks. It opens in the centre page and is reachable from both the list view and the notebook detail view, returning to whichever it was opened from.

- **FR13 — Deep link and restart safety.** The open route is the single source of truth for what is open; no component keeps a parallel copy of the navigation level. **No navigation state is persisted.** Every launch starts at the notebook list, so there is no half-completed drill-down to restore. A route naming a notebook that is not in the repository redirects to the list.

- **FR14 — Keyboard shortcuts.** Two shortcuts are bound at the shell and must not intercept keys consumed by a focused text field: `Cmd+B` (`Ctrl+B` on Windows) toggles collapse, and `Escape` navigates back.

- **FR15 — A narrow window can open the panel as a temporary overlay.**
  On a window below the docking breakpoint (FR6) the panel is a rail in the
  layout, but activating **Expand panel** opens the full panel **over** the
  centre page rather than being refused. This makes the collapse control do
  something on every window width instead of appearing dead on a narrow one —
  which is what a default-sized window (below 900 px) otherwise looks like.

  The overlay:
  - **Is transient and never persisted.** It is *not* the stored user intent
    (FR2, FR5). Opening it leaves `collapsedByUser` untouched, so the wide-window
    behaviour and the restored preference are unaffected.
  - **Dismisses on any of:** tapping the scrim, `Escape`, the collapse control,
    or activating any destination (which also performs its navigation). It never
    lingers across a route change.
  - **Never appears on a dockable window.** At or above the breakpoint the panel
    is docked exactly as before; there is no overlay toggle and no scrim.
  - **Reuses the panel widget verbatim** — the same destinations, the same
    keyboard order, the same accessibility labels (NFR6) — so a destination
    cannot be reachable in one presentation and not another.
  - **Considers intent on open:** if the window *is* dockable, "Expand panel"
    clears `collapsedByUser` (the docked panel expands in place); if it is not
    dockable, "Expand panel" opens the overlay and leaves intent alone.

  Because the overlay floats rather than docks, it does not consume layout width:
  the centre page keeps its full share and FR3's 20% rule is untouched.

### Non-Functional Requirements

- **NFR1 — Desktop-first.** Layout is designed for a resizable desktop window. Hover tooltips and keyboard navigation work without touch-specific affordances. Every mouse affordance is also available by keyboard.

- **NFR2 — Animation restraint.** Panel collapse/expand and route transitions are animated but short and interruptible. No animation blocks input or delays the first frame of a new page.

- **NFR3 — State conventions.** Navigation state is managed with `utopia_hooks`, following the State → Hook → View → Coordinator pattern, matching `../../AGENTS.md`. Global state is registered in `HookProviderContainerWidget` and consumed with `useProvided`. Dependencies are passed by constructor injection; there is no service locator and no code generation step. Panel presentation is a pure function of window width and intent, never stored.

- **NFR4 — Platform parity.** The same shell builds and runs on macOS, Windows, and Linux, obeying identical layout *rules* with no per-platform layout divergence. Presentation depends on window width, not platform, so the same width yields the same presentation everywhere.

- **NFR5 — Testability.** Panel width resolution, the breakpoint derivation, the collapse decision, persisted-state restore, and the drill-down/back state machine must be unit-testable without launching a window. Width resolution in particular must be a pure function with no Flutter or platform dependency.

- **NFR6 — Accessibility.** Every control in the panel is reachable and activatable by keyboard and exposes an accessible label. Rail (icon-only) controls carry both a tooltip and a semantic label.

---

## Geometry Constants

Single source of truth. Values must not be duplicated as literals anywhere in the implementation.

| Constant | Value | Derivation |
|---|---|---|
| `maxWidthFraction` | `0.20` | The panel's share of the window |
| `minExpandedWidth` | `180` logical px | Narrowest legible panel |
| `maxExpandedWidth` | `320` logical px | Widest useful panel; engaging the clamp at 1600 px |
| `railWidth` | `56` logical px | Standard Material icon-rail width |
| `dockBreakpoint` | `900` logical px | **Derived:** `minExpandedWidth ÷ maxWidthFraction` |

## Acceptance Criteria

- [ ] **AC1:** On first launch at a window width ≥ 900 px, the navigation panel is visible and expanded, with Add Notebook as the first element in it.
- [ ] **AC2:** At a window width ≥ 900 px the panel width equals `clamp(180, 20% of window width, 320)` — exactly 20% between 900 and 1600 px, 180 px at 900, and 320 px at or above 1600. No interaction can produce any other width.
- [ ] **AC3:** Narrowing the window from 1000 px to 700 px switches the panel to the rail; widening back past 900 px restores the panel at its FR3 width.
- [ ] **AC4:** Narrowing the window never changes the stored intent. In the docked case it opens no overlay; the FR15 narrow-window overlay is opened only by explicit user action.
- [ ] **AC5:** The collapse control switches between panel and rail; expanding restores the FR3 width rather than any remembered value.
- [ ] **AC6:** The rail exposes every destination with both a tooltip and a semantic label. The rail is 56 px and never exceeds the window width.
- [ ] **AC7:** The centre page always receives the remaining width, never overflows or clips, and stays usable at every window width from 320 px upward.
- [ ] **AC8:** Quitting with the panel collapsed and relaunching restores it collapsed.
- [ ] **AC9:** Quitting with the panel expanded and relaunching restores it expanded — the app never records a collapse the user did not perform. A launch on a window below 900 px may show the rail, but the stored intent is unchanged.
- [ ] **AC10:** Activating Add Notebook creates a notebook named `Notebook N`, appends it to the end of the list, and opens it in the centre page, with no naming dialog.
- [ ] **AC11:** Activating a notebook opens it in the centre page and marks it as the active item.
- [ ] **AC12:** Inside a notebook, the notebook list and the Add Notebook button are both absent from the panel in both forms, and the notebook's detail navigation is shown instead.
- [ ] **AC13:** The back control returns to the list, restoring the list, the Add Notebook button, and the previous scroll position, with no item left marked as selected.
- [ ] **AC14:** The platform back affordance and `Escape` perform the same navigation as the on-screen back control.
- [ ] **AC15:** Settings, pinned at the bottom in both forms, opens in the centre page from both the list and the notebook detail view, and returns to the view it was opened from.
- [ ] **AC16:** `Cmd+B` (`Ctrl+B` on Windows) toggles collapse; `Escape` navigates back. Neither intercepts a keystroke a focused text field consumes.
- [ ] **AC17:** Every launch starts at the notebook list, and a route naming a nonexistent notebook redirects to the list.
- [ ] **AC18:** Unit tests cover the width formula at and beyond both ends of its range, the derived breakpoint, the collapse decision across both sides of the breakpoint, persisted-state round-trip and corrupt-data recovery, and the list ↔ detail ↔ back transitions.
- [ ] **AC19:** Every panel control is keyboard-reachable and exposes an accessible label.
- [ ] **AC20:** The shell builds and runs on macOS, Windows, and Linux, obeying identical layout rules at identical window widths.
- [ ] **AC21:** On a window below 900 px the panel is a rail, and activating **Expand panel** opens the full panel as an overlay over the centre page; the centre page width is unchanged by the overlay (it floats, it does not dock).
- [ ] **AC22:** The overlay dismisses on scrim tap, `Escape`, the collapse control, and on activating any destination — and activating a destination also performs its navigation.
- [ ] **AC23:** Opening the overlay never writes the persisted intent; after dismissing it and widening past 900 px, the docked panel's state matches the stored preference exactly as before.
- [ ] **AC24:** On a window at or above 900 px there is no overlay and no scrim; **Expand panel** clears the stored collapse and expands the docked panel in place.
- [ ] **AC25:** Every destination reachable in the docked panel is reachable in the overlay with the same keyboard order and accessibility labels.

---

## Streamlining Record

Revision 4 was produced by removing two capabilities that revision 3 had carried a large amount of machinery to support. The record is kept because the removals are requirements changes, and because the reasoning is reusable when a later spec revisits panel sizing.

### What was removed, and why it was affordable

| Removed | What it took with it |
|---|---|
| Drag-to-resize (rev 3 FR4) | The resize handle, drag snapshot accumulation, keyboard resizing, the persisted *width*, clamp-on-restore, and the 20%-ceiling-versus-180px-floor conflict |
| Overlay / modal drawer menu (rev 3 FR15) | The third presentation mode, `showGeneralDialog`, the focus trap, the scrim, and the dual-`Escape`-handler hazard |

**The reason drag was expensive is now gone.** Revision 1 stated two unconditional rules — "at most 20% of window width" and "at least 180 px" — which cannot both hold below a 900 px window. That collision forced the mode system, and the mode system forced the overlay. With no user-settable width there is only **one** width rule, it applies only when the panel is rendered expanded, and the breakpoint falls out of the same two numbers (FR3, FR6). A single rule cannot contradict itself, so the overlay is no longer needed to escape the conflict.

**Cost of the removals:** the user cannot set the panel width. That is the whole trade. A proportional panel with no drag is what VS Code, Xcode, and Finder do, and it is a better default than a remembered pixel value that interacts badly with window resizing.

### Resolved Decisions

| # | Question | Resolution |
|---|---|---|
| D1 | What happens when the window is too narrow for an expanded panel? | The panel is a rail by default; **Expand panel** opens it as a temporary overlay (rev 5, FR15). |
| D2 | Does the narrow-window fallback conflict with "never collapse on its own"? | No. Intent is never changed automatically; only presentation changes. |
| D3 | Route push or in-panel state swap? | A real route push, so platform back works and the route is the single source of truth. |
| D4 | What is a notebook's identity? | An opaque string id owned and generated by the repository. Durable storage is deferred. |
| D5 | Notebook order? | Creation order, oldest first. |
| D6 | Does Add Notebook prompt for a title? | No dialog; auto-named `Notebook N`. Renaming is a later spec. |
| D7 | Does panel state persist per-window or per-app? | Per-app. Multi-window is a Non-Goal. |
| D8 | Minimum and maximum panel width? | 180 px and 320 px logical pixels. |
| D9 | Is the rail resizable independently? | Not applicable — nothing is resizable. |
| D10 | Seeded data for a demonstrable shell? | Yes, three notebooks. |
| D11 | Does the detail navigation need sub-items immediately? | A declarative registry; one section enabled, the rest disabled with tooltips. |
| D12 | Is "collapsed" a boolean or a presentation? | A boolean, and it is the user's intent. Presentation is derived from it and the window width, and is never persisted. |
| D13 | Should the user be able to size the panel? | No. See the Streamlining Record. Revisit if a later spec needs per-project panel sizes. |
| D14 | Is the narrow-window overlay persisted? | No. It is transient presentation, opened on demand, dismissed on first navigation. The persisted surface is still the single collapse boolean (FR5). |

---

## Revision 5 Record — the narrow-window overlay returns

Revision 4 removed the overlay drawer (its D1 read "the panel is a rail; no
overlay"). That reading turns out to make the collapse control look **broken** on
a default-sized window: the macOS window opens at **800×600**, which is below the
900 px breakpoint, so the panel is a forced rail and **Expand panel** does
nothing — the user sees a control that can never succeed until they widen the
window by hand.

Revision 5 restores an overlay, but **narrowly**: it is the *only* way to expand
on a sub-breakpoint window, it floats over the centre page rather than docking, it
is never persisted, and it dismisses on the first navigation. The docked
behaviour at or above the breakpoint is unchanged, and revision 4's other removal
(panel resizing) stands.

### Why this does not reintroduce the old cost

The reason revision 4 could remove the overlay was that a single width rule no
longer contradicts itself, so the overlay was not needed to escape a
mode conflict. That is still true — the overlay here is not a third *presentation*
of the docked panel and does not participate in width resolution at all. It is a
transient surface that reuses the panel widget verbatim, so the geometry model,
the persisted surface, and the 20% invariant are untouched. The cost that returns
is only the one revision 4 named as inherent to an overlay — a scrim and an
`Escape`-dismiss path — and that cost is accepted here because the alternative is
a control that appears dead on the app's default window.

## Open Questions

Only questions that genuinely cannot be settled without a later spec or an external decision:

- **Notebook durability.** Where notebooks are stored, and in what format. The repository interface is the seam.
- **Renaming, reordering, and deleting notebooks.** Out of scope. The list row must tolerate these hit targets later, which constrains the row layout chosen here.
- **What the centre page shows inside a notebook.** Placeholder for now. The eventual layout (sources, notes, chat) determines whether the FR10 registry needs more sections.
- **Whether a 56 px rail is right on phones.** A phone may be better served by a zero-width panel plus a hamburger control in the centre page. This is a mobile-only refinement and does not affect the width formula.
- **Mobile platform verification.** macOS, Windows, and Linux are in scope; Android and iOS builds are not verified by this spec.
