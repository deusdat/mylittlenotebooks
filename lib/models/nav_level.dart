/// Which navigation level the shell is showing.
///
/// Derived from the open route and never stored — no component keeps a parallel
/// copy that could drift out of sync with the rendered page (spec FR13).
sealed class NavLevel {
  const NavLevel();
}

final class NavLevelList extends NavLevel {
  const NavLevelList();
}

final class NavLevelDetail extends NavLevel {
  final String notebookId;

  const NavLevelDetail(this.notebookId);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NavLevelDetail && other.notebookId == notebookId;

  @override
  int get hashCode => notebookId.hashCode;
}

/// Reads the navigation level off a [Uri].
///
/// A plain function rather than a hook, so it is testable with no router at all.
NavLevel navLevelFrom(Uri uri) {
  final segments = uri.pathSegments;
  if (segments.length >= 2 && segments.first == 'notebook') {
    return NavLevelDetail(segments[1]);
  }
  return const NavLevelList();
}