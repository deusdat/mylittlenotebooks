---
description: 'Spec-Driven Development workflow and Flutter/utopia_hooks code standards for the Local Music Player app'
---

# Spec-Driven Development (SDD) Workflow

This project uses the same three-phase spec-driven loop as our other stacks:
**Specify → Plan → Implement**, with a memory-reconciling **Refresh** tail step.
Each phase produces an artifact under `specs/<feature-name>/`, where
`<feature-name>` is a **kebab-case** identifier.

## Triggering Phases

| Command | Phase | Artifact |
|---|---|---|
| `specify <description>` | Specify | `specs/<name>/spec.md` |
| `plan <name>` | Plan | `specs/<name>/plan.md` |
| `break down <name>` | Task breakdown | `specs/<name>/tasks.md` |
| `implement <name>` | Implement | Code changes |
| `verify <name>` | Verify | Test run report; gates `refresh` |
| `refresh <name>` | Refresh | reconciled `specs/_context/project-memory.md` + `agent-memories/`, and an advanced `next-steps.md` (marks the feature ✅ and points the human at the next command) |

`specify` reads `specs/_context/project-memory.md` **and**
`specs/_context/domain-language.md` first, so the spec reuses durable
vocabulary (Track, Playlist, Playlist Entry, Repetition, Queue, Now Playing
Session, Save Sheet — see Section "Domain Language" below) instead of
re-deriving it. `verify` is a hard gate between `implement` and `refresh`:
nothing is reconciled into memory until the Verifier persona confirms the
required tests exist and pass. `refresh` is otherwise a loop-**tail** step,
also invokable on demand to recover from out-of-band drift.

## Phase Flow & Error Escalation

```
spec.md ──► plan.md ──► tasks.md ──► implementation ──► verify (gate) ──► refresh
   ▲            ▲             ▲                              │
   └──── escalate ──────── to root cause ─────────────────────┘
```

If an issue is found at any stage, trace back to the **root cause** — the
earliest artifact where the error originated. Fix it there and regenerate
all downstream artifacts, including any tests already written against the
wrong contract.

- **Issue at verify** → check tasks.md; if the task was sound but
  incomplete, add the missing test and re-run. If the task itself was
  wrong, escalate to plan.md.
- **Issue in tasks.md** → check plan.md; if unsound, check spec.md. Fix at
  root. Regenerate downstream.
- **Issue in plan.md** → check spec.md. Fix at root. Regenerate plan.md
  (and tasks.md if it existed).
- **Issue in spec.md** → fix spec.md. Regenerate plan.md, tasks.md,
  implementation, and tests.

## Agent Personas

Persona instructions live in one canonical place — `.github/agents/`. The
other harnesses reach the same files through a git-tracked directory symlink:
`.opencode/agents` → `../.github/agents`. Edit only the canonical files in
`.github/agents/` — the symlink makes that one edit visible to every harness
that reads `.opencode/agents/`. `.claude/agents/` does not exist, so Claude
Code has no native `@`-persona discovery; it reaches the personas through
`AGENTS.md` and the internal skills under `.claude/skills/`. See
"Cross-Harness Setup" below for why.

| Persona | Canonical file | When Invoked | Memory Maintenance |
|---|---|---|---|
| **Specifier** | `.github/agents/specifier.md` | `specify <description>` | Reads `specs/_context/project-memory.md` and `specs/_context/domain-language.md` first; appends new durable facts/decisions and flips supersessions there. |
| **Planner** | `.github/agents/planner.md` | `plan <name>` | Refreshes `agent-memories/architecture-overview.md` when the feature adds a new Screen, a new piece of global state, or a new data-layer service. |
| **Task Builder** | `.github/agents/task-builder.md` | `break down <name>` | Maps each task to the `agent-memories/feature-checklist.md` step it fulfills, and to the specific test(s) required by that step. |
| **Implementer** | `.github/agents/implementer.md` | `implement <name>` | Reads relevant `agent-memories/` files **and** consults the `utopia_hooks` documentation (see below) before writing a single line of hook code. Updates memory files after shipping. |
| **Verifier** | `.github/agents/verifier.md` | `verify <name>` (auto-invoked at the end of `implement`) | Never edits memory. Only reads `agent-memories/testing-patterns.md`, runs the gate in "Completion Criteria," and either passes control to Refresher or bounces the task back to Implementer with a specific failure. |
| **Refresher** | `.github/agents/refresher.md` | `refresh <name>` or on demand | Re-walks the repo and rewrites `project-memory.md` + affected `agent-memories/` files to match what shipped; no fabrication. Also advances `next-steps.md` so the human always has a "next command to run" after checking in the code. Only runs after Verifier has passed. |

The **Verifier** is the safeguard this project adds on top of the standard
loop: no feature reaches `refresh` — and therefore no feature is considered
"done" — without a passing unit-test run for its hooks and a passing
widget/UI-test run for its screens. See "Completion Criteria."

## Cross-Harness Setup

This project is worked on from OpenCode, VS Code (GitHub Copilot), and
occasionally Claude Code. Those three harnesses each discover "custom
agents" from a different path with a different file shape, so no single
path can serve all three. Skills don't have this problem —
`.claude/skills/<name>/SKILL.md` happens to already be read natively by all
three — but agent personas do. This repo keeps **one set of real persona
files** and lets the harnesses that support it reach them by symlink:

```
.github/agents/<name>.md          # canonical — edit these files
.opencode/agents                  # git-tracked symlink → ../.github/agents
```

- **OpenCode** reads `AGENTS.md` at the repo root automatically — no
  setting required — and separately discovers subagents from
  `.opencode/agents/*.md`, which resolve through the symlink to the
  canonical files.
- **VS Code / GitHub Copilot** also reads `AGENTS.md`, but it's gated
  behind a setting that isn't on by default in every VS Code version:
  set `chat.useAgentsMdFile` to `true`. It discovers custom agents from
  `.github/agents/*.md`, invoked with `@<name>` in Copilot Chat.
- **Claude Code** discovers subagents from `.claude/agents/*.md`, which
  does not exist in this repo — Claude Code has no native `@`-persona
  subagents here. It reaches the personas through `AGENTS.md` and the
  internal `.claude/skills/`.

Because there is a single canonical directory, there is nothing to keep in
sync beyond the symlink itself (one `ln -s`, already committed): the actual
process, rules, and escalation logic for a persona are written once, in
`.github/agents/<name>.md`, and read from there regardless of which harness
is driving.

## Skills

Skills are reusable instruction sets an agent loads before doing a specific
kind of work — same idea as `agent-memories/`, but packaged so they can be
installed, versioned, and shared. One is external (published by the
`utopia_hooks` maintainers); the rest are authored for this repo and live
under `.claude/skills/<name>/SKILL.md`.

| Skill | Source | Invoked by | Purpose |
|---|---|---|---|
| `utopia-hooks` | External — `Utopia-USS/utopia-flutter-skills` marketplace | Planner, Implementer | Teaches the Screen/State/View pattern and the full hook catalog up front so hook code is idiomatic on the first try instead of guessed. Its checks run through `utopia_cli`. |
| `spec-writer` | `.claude/skills/spec-writer/SKILL.md` | Specifier | Encodes the `spec.md` template below and the rule to read `project-memory.md` and `domain-language.md` before writing. |
| `plan-architect` | `.claude/skills/plan-architect/SKILL.md` | Planner | Encodes the decision tree for local hook state vs. global state, and when a feature needs a new data-layer service vs. reusing an existing one. |
| `task-decomposer` | `.claude/skills/task-decomposer/SKILL.md` | Task Builder | Encodes the mapping from `feature-checklist.md` steps to concrete tasks, and ensures every task touching a hook or a screen has a paired test task. |
| `hook-test-writer` | `.claude/skills/hook-test-writer/SKILL.md` | Implementer, Verifier | Encodes the pattern for testing a hook as a plain Dart function — no widget tree required. See "Testing Hooks" below. |
| `widget-test-writer` | `.claude/skills/widget-test-writer/SKILL.md` | Implementer, Verifier | Encodes the pattern for testing a Screen's rendered output and interactions with `flutter_test`. See "Testing Views" below. |
| `memory-refresher` | `.claude/skills/memory-refresher/SKILL.md` | Refresher | Encodes how to diff shipped code against `agent-memories/` and rewrite only what changed, without inventing facts. |

Install the external skill once per machine/CI runner:

```bash
dart pub global activate utopia_cli
# In Claude Code:
/plugin marketplace add Utopia-USS/utopia-flutter-skills
/plugin install utopia-hooks@utopia-flutter-skills
```

## Artifact Templates

### `specs/<name>/spec.md`

```markdown
# Feature: <Title>

**Feature name:** `<kebab-name>`

## Context
What problem does this feature solve? Which existing Use Case(s) from
`specs/_context/use-cases.md` does it implement or extend, if any?

## Goals
- Bullet list of what this feature aims to achieve.

## Non-Goals
- Bullet list of what is explicitly out of scope.

## References
- `specs/_context/project-memory.md` — durable facts about the project.
- `specs/_context/domain-language.md` — Track, Playlist, Playlist Entry,
  Repetition, Queue, Now Playing Session, Save Sheet, etc.
- `agent-memories/architecture-overview.md` — current Screen list, global
  state list, data-layer services.
- Prior specs whose decisions this feature reuses or supersedes, with a
  one-line reason each.

## Requirements

### Functional Requirements
- FR1: ...
- FR2: ...

### Non-Functional Requirements
- NFR1: Performance, accessibility, offline behavior, etc.

## Acceptance Criteria
- [ ] AC1: ...
- [ ] AC2: ...

## Open Questions
- What needs further investigation?
```

### `specs/<name>/plan.md`

```markdown
# Plan: <Title>

## Approach
High-level strategy. Is this a new Screen, or an extension of an existing
one? Does it introduce a new piece of shared/global state, or is it purely
local to one hook?

## Architecture & Design Decisions
- Screen(s) touched or added (Screen / State / View triple).
- New hooks required? Local `useState`/`useEffect` composition, or a new
  Global State object?
- New or changed data-layer service (repository interface) required?
- Does this feature change the Domain Model (Section "Domain Language")?
  If it adds/changes a Playlist Entry, Queue, or Repetition rule, say so
  explicitly — that's a root-cause-sensitive area.

## Milestones
1. **Milestone 1** — What is delivered, estimated effort.
2. **Milestone 2** ...

## Dependencies
- What data-layer services or fixtures must exist before this work can
  start?
- Which other Screens or global state does this touch?

## Risks & Mitigations
- Risk → Mitigation
```

### `specs/<name>/tasks.md`

```markdown
# Tasks: <Title>

## Prerequisites
- Links to spec.md, plan.md.
- Checklist step mapping: each task corresponds to a step in
  `agent-memories/feature-checklist.md`.

## Task List

### T1: <Short description>
- **Files:** `lib/features/<feature>/...`
- **Effort:** Small / Medium / Large
- **Depends on:** (none or T0)
- **Checklist step:** State / View / Data Service / etc.
- **Paired test task:** T1a (hook unit test) and/or T1b (widget test) —
  every task that adds or changes a hook or a Screen MUST have at least
  one paired test task. A task with no paired test task is a plan defect;
  escalate to Task Builder, not a shortcut Implementer takes silently.
- **Steps:**
  1. Detailed step
  2. Detailed step
```

---

# Flutter Development Instructions

These instructions govern all code written in this repository. When in
doubt, read the relevant memory file or the `utopia_hooks` documentation —
they are the authoritative sources, not this file's paraphrase of them.

## Memory-First Protocol (REQUIRED)

**Before writing any code**, read the relevant `agent-memories/` files, and
for anything hook-related, also consult the `utopia_hooks` docs (below):

| Task | Read |
|------|------|
| Domain vocabulary (Track, Playlist, Repetition, etc.) | `specs/_context/domain-language.md` |
| Writing a hook / State object | `agent-memories/hook-pattern.md` + `utopia_hooks` docs |
| Writing a View (pure render widget) | `agent-memories/view-pattern.md` |
| Writing or changing Global State | `agent-memories/global-state-pattern.md` |
| Writing a data-layer service | `agent-memories/data-service-pattern.md` |
| Writing tests | `agent-memories/testing-patterns.md` |
| Overall structure | `agent-memories/architecture-overview.md` |
| End-to-end feature guide | `agent-memories/feature-checklist.md` |

**After shipping**, the Implementer updates the affected memory file(s)
with any new patterns, gotchas, or corrections discovered; the Refresher
reconciles everything else after Verifier passes.

## Project Overview

**Local Music Player** is a Flutter mobile app for browsing a locally
indexed audio library, composing Playlists — including intentionally
repeated entries — and playing them back.

- **Framework:** Flutter (latest stable), Dart 3.x
- **State management:** [`utopia_hooks`](https://hooks.utopiasoft.io/) —
  a hooks-based architecture, not `flutter_hooks`; do not confuse the two
  packages or their APIs
- **Pattern:** Screen / State / View (see below)
- **Testing:** `package:test` for hook unit tests, `flutter_test` for
  widget/UI tests
- **Domain source of truth:** `specs/_context/domain-language.md` and
  `specs/_context/use-cases.md` (UC-1 through UC-19 as of this writing —
  Library indexing, Standalone Playback, Search, Playlist Management,
  Playlist Composition including Repetition, the Save Sheet, Now
  Playing/Transport, and Concurrent Playback (Sibling Track))

## Documentation & MCP Access for `utopia_hooks`

Do not guess at `utopia_hooks` API surface from general React-hooks
knowledge — it is inspired by React Hooks but has its own hook catalog,
its own Global State model, and its own testing harness. The external
`utopia-hooks` skill is **not installed in this environment**; the
`utopia_cli` MCP server (`utopia mcp`) is **not registered**. Two
resources exist instead, and agents should not improvise past them:

1. **The `ragdocs` MCP server** (registered in the opencode MCP config as
   `ragdocs`) — the `utopia-flutter` monorepo (the source of `utopia_hooks`)
   is indexed there, so `ragdocs_search_documentation` returns the
   authoritative hook catalog, signatures, and usage straight from the code
   that defines them.
2. **The `utopia` CLI** at `~/.pub-cache/bin/utopia` (not on `$PATH`) —
   `describe` (project structure: screens, routes, states, services, deps as
   JSON), `doctor`, and `hooks analyze --all`. Before writing or modifying
   any hook, run `describe` to see the project's current structure rather
   than inferring it from a partial file listing, and run
   `hooks analyze --all` to check for existing violations before adding more
   surface area to a file that already has some.

If a hook pattern is still unclear after consulting both, that is a
signal to stop and ask, not to improvise — improvised hook usage is the
single most common source of untestable state in this architecture.

## The Screen / State / View Pattern

Every feature screen is split into three files so business logic stays
provable in plain Dart, independent of the widget tree:

| File | Purpose |
|------|---------|
| `<feature>_screen.dart` | Thin `HookWidget` wiring: calls the State hook, passes the result to the View. No business logic. |
| `<feature>_state.dart` | A hook function (e.g. `usePlaylistDetailState(...)`) composed of `useState`, `useEffect`, and any Global State reads, returning a typed, immutable state object. All business logic lives here. |
| `<feature>_view.dart` | A pure widget that takes the state object as a constructor argument and renders it. Contains no hooks and no direct calls to data services. |

```dart
// playlist_detail_screen.dart
class PlaylistDetailScreen extends HookWidget {
  const PlaylistDetailScreen({required this.playlistId, super.key});
  final String playlistId;

  @override
  Widget build(BuildContext context) {
    final state = usePlaylistDetailState(playlistId: playlistId);
    return PlaylistDetailView(state: state);
  }
}
```

```dart
// playlist_detail_state.dart
PlaylistDetailState usePlaylistDetailState({required String playlistId}) {
  final playlists = usePlaylistsGlobalState();
  final playlist = playlists.value.firstWhere((p) => p.id == playlistId);

  void moveEntry(String entryId, int direction) {
    playlists.moveEntry(playlistId, entryId, direction);
  }

  void removeEntry(String entryId) {
    playlists.removeEntry(playlistId, entryId);
  }

  return PlaylistDetailState(
    playlist: playlist,
    onMoveEntry: moveEntry,
    onRemoveEntry: removeEntry,
  );
}
```

Because the hook function above imports nothing from `dart:ui` or
`package:flutter/widgets.dart` beyond what `utopia_hooks` itself needs, it
can be unit-tested exactly like any other Dart function — see "Testing
Hooks."

## Global State and Repetition

The **Playlist Entry** model (see domain language) is enforced at the
Global State layer, not in any individual Screen:

- A Global State object owns the canonical, in-memory list of Playlists.
- Adding a Track to a Playlist always appends a new Entry with a fresh
  entry identity. **No code path checks for an existing Entry referencing
  the same Track before adding one.** If you find yourself writing that
  check, stop — it contradicts the domain rule captured in UC-10 and
  UC-14, and the Verifier's test gate will fail deliberately-written
  regression tests that assert Repetition is possible.
- Removing or reordering one Entry must never mutate a sibling Entry that
  references the same Track. Cover this explicitly in the hook's unit
  test, not just the happy path.

## Testing Requirements (REQUIRED — enforced by the Verifier persona)

A task is not complete until **both** of the following exist and pass for
every hook and every Screen it touches. This is a hard gate, not a
suggestion: the Verifier persona blocks `refresh` until both are green.

### Testing Hooks

Hooks are plain Dart functions once decoupled from the widget tree — test
them with `package:test`, no `WidgetTester`, no pump cycles, no mocking
the framework itself. Use the `utopia_hooks` testing harness (consult the
`utopia-hooks` skill / MCP for the exact current API rather than
hand-rolling a harness) to invoke the hook function directly:

```dart
// playlist_detail_state_test.dart
void main() {
  test('adding the same track twice produces two independent entries', () {
    final harness = HookTestHarness(); // exact API: see utopia_hooks docs
    final state = harness.run(() => usePlaylistDetailState(playlistId: 'p1'));

    state.onAddTrack('t1');
    state.onAddTrack('t1');

    expect(state.playlist.entries.length, 2);
    expect(state.playlist.entries[0].entryId,
        isNot(equals(state.playlist.entries[1].entryId)));
  });

  test('removing one entry leaves its repeated sibling untouched', () {
    // Arrange a playlist with two entries referencing the same track,
    // remove one by entryId, assert exactly one Entry remains and its
    // entryId is the sibling's — not the removed one's.
  });
}
```

### Testing Views

Every Screen gets a widget test asserting it renders correctly given a
state object, and that user interactions call the expected state
callbacks — this is the UI-level counterpart to the hook unit test, and
it is what catches the class of bug hook tests structurally cannot: wrong
widget wired to wrong callback, a button that doesn't exist where the
design says it should, text that doesn't update on rebuild.

```dart
// playlist_detail_view_test.dart
void main() {
  testWidgets('tapping remove calls onRemoveEntry with the tapped entry id',
      (tester) async {
    String? removedId;
    final state = PlaylistDetailState(
      playlist: fakePlaylistWithTwoEntries(),
      onMoveEntry: (_, __) {},
      onRemoveEntry: (id) => removedId = id,
    );

    await tester.pumpWidget(MaterialApp(
      home: PlaylistDetailView(state: state),
    ));

    await tester.tap(find.byKey(const Key('remove-entry-e1')));
    await tester.pump();

    expect(removedId, 'e1');
  });
}
```

Screens with non-trivial visual layout (Now Playing, Save Sheet) should
also get a golden test where practical — check
`agent-memories/testing-patterns.md` for the current golden-test
conventions before adding a new one.

## Naming Conventions

| Element | Convention | Example |
|---------|-----------|---------|
| Feature directory | `lib/features/<feature>/` | `lib/features/playlist_detail/` |
| Screen file | `<feature>_screen.dart` | `playlist_detail_screen.dart` |
| State/hook file | `<feature>_state.dart` | `playlist_detail_state.dart` |
| View file | `<feature>_view.dart` | `playlist_detail_view.dart` |
| Global state file | `lib/state/<domain>_global_state.dart` | `playlists_global_state.dart` |
| Data service interface | `lib/services/<domain>_service.dart` | `library_service.dart` |
| Hook unit test | `<feature>_state_test.dart` | `playlist_detail_state_test.dart` |
| Widget/UI test | `<feature>_view_test.dart` | `playlist_detail_view_test.dart` |
| State class | PascalCase, `<Feature>State` | `PlaylistDetailState` |

## Completion Criteria

A task is **not complete** until **all** of the following pass, and the
Verifier persona has confirmed it — Implementer does not self-certify:

1. **Compiles**: `flutter analyze` (zero issues)
2. **Formatted**: `dart format --set-exit-if-changed .`
3. **Hook unit tests pass**: `flutter test test/unit` — every hook added
   or changed in this task has a corresponding test, including at least
   one test asserting Repetition behaves correctly if the hook touches
   Playlist Entries.
4. **Widget/UI tests pass**: `flutter test test/widget` — every Screen
   added or changed in this task has a corresponding widget test. No
   tests are skipped or deleted to make this pass.
5. **Project doctor clean**: `~/.pub-cache/bin/utopia doctor` — structural/
   lint checks via the `utopia` CLI (not on `$PATH`).
6. **Hook audit clean**: `~/.pub-cache/bin/utopia hooks analyze --all`
   reports no new violations introduced by this task.

If any of 3–6 fails, the Verifier bounces the task back to the Implementer
with the specific failing check — it does not attempt to fix the code
itself, and it does not relax the gate to let a task through.

## General Dart/Flutter Standards

- Write simple, idiomatic Dart. Clarity over cleverness.
- Keep the happy path left-aligned; return/guard early.
- Hooks return immutable state objects; do not mutate a returned state
  object's fields from a View — call the provided callback instead.
- Views never call a data service or Global State directly — only through
  the callbacks the State hook provides.
- Prefer composing existing hooks (`useState`, `useEffect`, `useProvided`,
  etc.) over writing a new low-level hook from scratch; check the
  `utopia_hooks` hook catalog via the `ragdocs` MCP server
  (`ragdocs_search_documentation`) first.
- A Screen, State, or View file that grows large enough to need internal
  sub-sections is a signal to split the feature directory further, not to
  keep scrolling.
