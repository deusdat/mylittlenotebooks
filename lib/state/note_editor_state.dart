/// The note editor's values and actions (spec FR27–FR29, FR36).
///
/// Imports neither hooks nor Flutter, so it is constructible in a plain test.
class NoteEditorState {
  /// The title field's current text ('' when untitled).
  final String title;

  /// The body field's current text.
  final String body;

  /// True when the title or body differs from the last saved values.
  final bool dirty;

  /// True while a save is in flight.
  final bool saving;

  /// True when the note is not currently searchable (spec FR36): it has a
  /// non-empty body but no chunks, or its vectors belong to another model.
  final bool isUnindexed;

  /// The last save error, or null.
  final String? error;

  final void Function(String value) setTitle;
  final void Function(String value) setBody;
  final Future<void> Function() save;
  final void Function() cancel;

  const NoteEditorState({
    required this.title,
    required this.body,
    required this.dirty,
    required this.saving,
    required this.isUnindexed,
    required this.error,
    required this.setTitle,
    required this.setBody,
    required this.save,
    required this.cancel,
  });
}
