/// Persistence for the panel's single stored value.
///
/// Exactly one boolean (spec FR5). Panel width and presentation are derived
/// from the window and are never stored, which is why there is no versioned
/// document and no clamp-on-restore: there is no width to clamp.
abstract interface class PanelStateStore {
  /// Whether the panel is collapsed. `false` when nothing is stored, matching
  /// the expanded default (spec AC9).
  Future<bool> readCollapsed();

  Future<void> writeCollapsed(bool collapsed);
}

/// A [PanelStateStore] for tests.
class InMemoryPanelStateStore implements PanelStateStore {
  bool? _collapsed;
  int writeCount = 0;

  InMemoryPanelStateStore({bool? initialCollapsed})
    : _collapsed = initialCollapsed;

  /// The most recently written value, for assertions in tests.
  bool? get lastWritten => _collapsed;

  @override
  Future<bool> readCollapsed() async => _collapsed ?? false;

  @override
  Future<void> writeCollapsed(bool collapsed) async {
    _collapsed = collapsed;
    writeCount++;
  }
}