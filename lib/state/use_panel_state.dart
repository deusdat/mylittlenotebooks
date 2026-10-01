import 'dart:async';

import 'package:mylittlenotebooks/data/panel_state_store.dart';
import 'package:mylittlenotebooks/state/panel_state.dart';
import 'package:utopia_hooks/utopia_hooks.dart';

/// Builds [PanelState] from a value preloaded before `runApp`.
///
/// `preloaded` is read in `main()` and handed down as a constructor argument,
/// then seeded into `useState` **synchronously**. That is deliberate: the
/// package's own `usePersistedState` takes a `Future<T?> get()` whose value
/// flows through `ComputedStateValueInProgress` on the first build, and an
/// already-completed future still yields. A restored-collapsed panel would
/// therefore render one frame expanded before snapping to the rail (spec
/// AC8/AC9). Loading outside the hook tree makes that flicker impossible.
///
/// There is deliberately no `dragTo` and no width state here: panel width is
/// derived from the window (spec FR3, D13).
PanelState usePanelState({
  required bool preloaded,
  required PanelStateStore store,
}) {
  // No `keys`: keys would reset the value whenever they change, which is
  // exactly wrong for a stored user preference.
  final collapsed = useState(preloaded);

  void toggleCollapsed() {
    final next = !collapsed.value;
    if (!collapsed.setIfMounted(next)) return;
    unawaited(store.writeCollapsed(next));
  }

  return PanelState(
    collapsedByUser: collapsed.value,
    toggleCollapsed: toggleCollapsed,
  );
}