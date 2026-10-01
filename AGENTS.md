---
description: 'Spec-Driven Development workflow and Backend/UI code standards for this project'
---

# Spec-Driven Development (SDD) Workflow

This project uses a simple three-phase spec-driven loop: **Specify → Plan → Implement**. Each phase produces an artifact under `specs/<timestamp>-<feature-name>/`, where:

- `<timestamp>` is the **creation time in milliseconds since epoch** (13 digits, e.g. `1759250400000`), so directories sort naturally by creation order.
- `<feature-name>` is a **kebab-case** identifier (e.g. `user-auth-oauth`).

## Triggering Phases

| Command | Phase | Artifact |
|---|---|---|
| `specify <description>` | Specify | `specs/<timestamp>-<name>/spec.md` |
| `plan <name>` | Plan | `specs/<timestamp>-<name>/plan.md` |
| `break down <name>` | Task breakdown | `specs/<timestamp>-<name>/tasks.md` |
| `implement <name>` | Implement | Code changes |

When you say `specify <description>`, the agent MUST:
1. Ask for a short description if none is provided
2. Derive a **kebab-case** `<name>` from it (e.g., "user auth with OAuth" → `user-auth-oauth`)
3. Get the current time in milliseconds since epoch and prefix it (e.g. `1759250400000-user-auth-oauth`)
4. Create `specs/<timestamp>-<name>/spec.md`
5. **Tell you the full directory name** (timestamp + kebab-case) so you can use it in downstream commands

All subsequent commands (`plan`, `break down`, `implement`) require the **full directory name** — `<timestamp>-<kebab-name>` — as the argument. Resolve a bare kebab-case name to its unique matching directory under `specs/`; if more than one match exists, ask which one.

## Phase Flow & Error Escalation

```
spec.md  ──►  plan.md  ──►  tasks.md  ──►  implementation
   ▲            ▲             ▲
   └──── escalate ──────── to ──── root cause ────┘
```

If you find an issue at any stage, the system traces back to the **root cause** — the earliest artifact where the error originated. That artifact is fixed, and all downstream artifacts are regenerated.

- **Issue in tasks.md** → check if plan.md is sound; if not, check spec.md. Fix at the source. Regenerate downstream.
- **Issue in plan.md** → check if spec.md is sound. Fix at the source. Regenerate plan.md (and tasks.md if it existed).
- **Issue in spec.md** → fix spec.md. Regenerate plan.md (and tasks.md, implementation).

## Agent Personas

This workflow uses four agent personas. Each has its own instruction file under `.agents/`:

| Persona | File | When invoked |
|---|---|---|
| **Specifier** | `.agents/specifier/instruction.md` | `specify <description>` |
| **Planner** | `.agents/planner/instruction.md` | `plan <name>` |
| **Task Builder** | `.agents/task-builder/instruction.md` | `break down <name>` |
| **Implementer** | `.agents/implementer/instruction.md` | `implement <name>` |

Each agent MUST reference the "Go Development Instructions" section for backend and "Flutter/Dart Development Instructions" for frontend language-specific standards.

> **Note:** the `.agents/` directory does not exist in this repository, so these four instruction files are currently absent. Until they are created, each phase runs from the templates above plus the language-specific sections of this file.

## Artifact Templates

### spec.md (`specs/<timestamp>-<name>/spec.md`)

```markdown
# Feature: <Title>

**Spec directory:** `<timestamp>-<kebab-name>`
**Feature name:** `<kebab-name>`

## Context
What problem does this feature solve? Why is it needed?

## Goals
- Bullet list of what this feature aims to achieve.

## Non-Goals
- Bullet list of what is explicitly out of scope.

## Requirements

### Functional Requirements
- FR1: ...
- FR2: ...

### Non-Functional Requirements
- NFR1: Performance, security, etc.

## Acceptance Criteria
- [ ] AC1: ...
- [ ] AC2: ...

## Open Questions
- What needs further investigation?
```

### plan.md (`specs/<timestamp>-<name>/plan.md`)

```markdown
# Plan: <Title>

## Approach
High-level strategy for implementing this feature.

## Architecture & Design Decisions
Key structural choices, patterns, and rationale.

## Milestones
1. **Milestone 1** — What is delivered, estimated effort.
2. **Milestone 2** ...

## Dependencies
- What must exist before this work can start.

## Risks & Mitigations
- Risk → Mitigation
```

### tasks.md (`specs/<timestamp>-<name>/tasks.md`)

```markdown
# Tasks: <Title>

## Prerequisites
- Links to spec.md, plan.md, any required setup.

## Task List

### T1: <Short description>
- **Files:** `path/to/file.<ext>`
- **Effort:** Small / Medium / Large
- **Depends on:** T0
- **Steps:**
    1. Detailed step
    2. Detailed step

### T2: <Short description>
...
```

# Go Development Instructions

Follow idiomatic Go practices and community standards when writing Go code.

## Agent Directives

1.  **Test-Driven Development (TDD):** Implement tests first where possible, all changes must be verified.
2.  **Architecture:** The agent must use a clean-architecture pattern with the following layers:
    - **Domain** (`backend/domain`): Business logic, Generic UseCases (`github.com/deusdat/cleango`), domain models (`model_*.go`), and interfaces. Zero incoming dependencies from outer layers like routers or databases.
    - **Delivery** (`backend/api`): Chi application routers (`github.com/go-chi/chi/v5`). Features subpackages like `presenters` and `factory`. Handlers only return JSON data via injected Presenters parsing OpenAPI generated models (`apimodels`).
    - **Dependency Injection**: No automated compile-time DI like Wire. We use a factory pattern `Factory(ctx)` residing in `backend/api/factory` which supplies handlers with initialized configurations, database connections, and use-cases.
3.  **UI Technology:** (Moved to Dart/Flutter specific instructions below). Frontend handles its own UI using generated models. Handlers only return JSON data via injected Presenters parsing OpenAPI models.
4.  **Logging:** `slog` library is used through the Request-Scoped Factory (`fac.Logger(...)`). Use cases should log entry, exit, and errors dynamically.

## Naming Conventions
- Database Objects: Rambler migrations. Table names `_t`, views `_v`, functions `_f` (e.g. `1742512345678_create_channel_t.sql`). Do NOT mutate DB except via migrations.

## Architecture and Project Structure

### Use Case Pattern
All business logic resides in `use_case_xxx.go` files executing via `github.com/deusdat/cleango`.

```go
type MyUseCase struct {
logger *slog.Logger
// dependencies
}

func (u *MyUseCase) Execute(input MyInput, p cleango.Presenter[MyOutput]) {
// Logging start
if err != nil {
p.Present(cleango.Output[MyOutput]{ Err: cleango.ToDomainError("MyUseCase...", err) })
return
}
p.Present(cleango.Output[MyOutput]{ Answer: MyOutput{...} })
}
```

### Handler and Command Pattern
Routing happens strictly with `github.com/go-chi/chi/v5`.
```go
func MyHandler(w http.ResponseWriter, r *http.Request) {
ctx := r.Context()
fac := f(ctx) // factory injection
l := fac.Logger("get /myroute")

uc := fac.MyUseCase(l)
presenter := fac.MyPresenter(l, w)

uc.Execute(domain.MyInput{...}, presenter)
}
```

# Flutter / Dart Development Instructions

The app is a Flutter desktop-first application using hook-based state management. The Flutter project lives at the **repository root** (`lib/`, `test/`, `pubspec.yaml`) — there is no `frontend/` subdirectory.

## Agent Directives

1.  **State Management**: Use `utopia_hooks` exclusively. Riverpod, `get_it`, and `StatefulWidget`-based state management are all prohibited in app code. Follow the **State → Hook → View → Coordinator** pattern:
    - **State**: an immutable class holding values plus the actions that change them.
    - **Hook**: a `use…`-prefixed function that owns the logic and returns a State.
    - **View**: a `StatelessWidget` that renders a State and nothing else.
    - **Coordinator**: a `HookWidget` that binds the Hook and View together and performs navigation.
2.  **Global state**: register in `HookProviderContainerWidget` wrapping `MaterialApp`; consume with `useProvided<T>()`. Global state registered there lives for the whole app session — this is the analogue of `keepAlive`.
3.  **Local state**: `useState<T>(initial)`. Side effects and teardown: `useEffect(() { …; return dispose; }, [keys])`. Derived values: `useMemoized`, `usePrevious`, `useDebounced`. Never store a value that is merely derived from another value.
4.  **Hook rules** (breaking these breaks the framework): hooks may only be called directly inside `HookWidget.build` or inside another hook — never in a callback, never inside an `if`, loop, or try/catch. Use `useIf`, `useIfNotNull`, `useLet`, or `useMemoizedIf` when a branch must contain a hook. Always pass explicit `keys` to `useEffect`.
5.  **Dependency injection**: constructor injection. Repositories and stores are plain objects passed as parameters or captured by closures. There is no service locator.
6.  **Pre-`runApp` bootstrap**: anything the first frame depends on must be `await`ed in `main()` before `runApp` and handed to the root widget as a constructor argument. Never make the UI wait on an asynchronous hook for a value needed on frame one.
7.  **Testing**: hooks are unit-testable without a widget tree via `SimpleHookContext(() => useMyHook(), provided: {…})` — exposing `.value`, `.rebuild()`, `.waitUntil(predicate)`. Pure logic must stay free of `package:flutter` imports so it can be tested with a plain `test()`.
8.  **Client-Server Contracts**: Exclusively use `package:backend` which is auto-generated by OpenAPI generator based off the `code_gen/api.yaml`. Treat the API yaml as the source of truth for structures. Start by updating `api.yaml`, run `generate.sh` in `code_gen/`, and then hook to the resulting client code.
9.  **Architectural Layout**:
    - `lib/models/`: immutable domain representations and pure logic, with no Flutter imports.
    - `lib/data/`: repository and storage interfaces plus their implementations.
    - `lib/state/`: global-state hooks — one State class plus one hook per stateful concern.
    - `lib/shell/`: app chrome, navigation panel, and layout.
    - `lib/pages/`: one file per routed destination.
    - `lib/widgets/`: cohesive shared visual components.
    - `lib/router/`: route table and navigation guards.
    - `lib/services/`: bridges hooks and UI to generated backend client functions.

## Reference: `utopia_hooks`

`utopia_hooks` is a **published pub.dev package** consumed as an ordinary dependency. There is **no local clone**: the `only-ai/utopia-flutter/` path referenced by earlier revisions of this file does not exist in this repository. Read package source via `Read`/`Grep`, or extract the archive from pub.dev.

| Package | Constraint | Purpose |
|---|---|---|
| `utopia_hooks` | `^0.4.26+1` | Core: `HookWidget`, `useState`, `useEffect`, `useMemoized`, `useProvided`, `HookProviderContainerWidget`, `SimpleHookContext` |
| `utopia_widgets` | `^0.1.2+1` | Shared widget components |
| `utopia_utils` | `^0.3.3` | Supporting utilities (transitive) |
| `utopia_collections` | `^0.1.2` | Collection helpers (transitive) |
| `utopia_validation` | `^0.1.0+4` | Form validation (transitive) |

Upstream guide site: <https://hooks.utopiasoft.io> · Source: <https://github.com/Utopia-USS/utopia-flutter>

### Traps

- **The pub.dev README is stale.** It shows `HookProviderContainerWidget(providers: {…})`. The real constructor takes the map **positionally**: `HookProviderContainerWidget({…}, child: …)`. Trust the package source over the README.
- **`usePersistedState` is asynchronous by design.** Its `value` stays `null` until the `get()` future resolves, and it exposes `isInitialized` / `isSynchronized`. It is the right tool for settings and drafts, and the **wrong** tool for anything that must be correct on the first frame — preload in `main()` per Directive 6 instead.
- **`useState` asserts on unmounted writes.** Assigning `.value` after unmount throws in debug; use `setIfMounted` (via `StateHookStateX`) when the write may race teardown.
- The `ragdocs` MCP index holds scraped GitHub HTML pages rather than code chunks — prefer reading the extracted package source.
