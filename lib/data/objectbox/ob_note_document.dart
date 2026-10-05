import 'package:objectbox/objectbox.dart';

import 'package:mylittlenotebooks/data/objectbox/ob_note.dart';

/// The body text of a note, in its own row (spec FR2).
///
/// Split out from [ObNote] for the same reason `ObDocument` is split from
/// `ObPublication`: ObjectBox loads whole objects, so a body stored on the note
/// row would be read by every note **list**. List paths return a summary with no
/// body field instead (spec NFR4).
@Entity()
class ObNoteDocument {
  @Id()
  int id = 0;

  /// Derived identity: `noteDocumentUuidFor(noteUuid)` (spec FR25).
  @Unique()
  String uuid;

  /// Denormalised from [ObNote] so the body can be read by note id without
  /// traversing the relation.
  @Index()
  int noteId;

  /// The body's own sync axis, tracked separately from the note's metadata
  /// version (spec FR19).
  @Index()
  int versionCounter;

  String markdown;

  /// The rename is mandatory: a `ToOne` named `note` would auto-generate a
  /// `noteId` property, colliding with the denormalised column above.
  @TargetIdProperty('noteOwnerId')
  final note = ToOne<ObNote>();

  ObNoteDocument({
    required this.uuid,
    required this.noteId,
    required this.markdown,
    this.versionCounter = 0,
  });
}
