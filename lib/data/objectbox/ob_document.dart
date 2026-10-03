import 'package:objectbox/objectbox.dart';

import 'package:mylittlenotebooks/data/objectbox/ob_publication.dart';

/// The source text of a publication, in its own row.
///
/// **Split out from [ObPublication] deliberately.** ObjectBox loads whole
/// objects, so a document stored on the publication row is read by every
/// publication *list* — turning "render 50 titles" into "read 50 documents".
/// Spec NFR6 requires that list and search paths never touch the source text,
/// and separating the rows is the only way to make that true rather than
/// aspirational (spec correction 3).
///
/// The text is still the record of truth (spec FR4): nothing here points at a
/// file, and re-chunking, preview, and citation all read from here.
@Entity()
class ObDocument {
  @Id()
  int id = 0;

  /// Globally-unique identity, shared with peer devices. `@Unique` rather than
  /// `@Index` — see the note on `ObNotebook.uuid`.
  @Unique()
  String uuid;

  /// The publication this text belongs to.
  @Index()
  int publicationId;

  /// Last-write-wins version of the *text* (FR9, FR10), tracked separately from
  /// the publication's metadata version.
  ///
  /// Separate because the document is its own row with its own edits: a re-import
  /// can replace the source text without touching the title, and a title edit
  /// should not be able to roll the text back.
  @Index()
  int versionCounter;

  String markdown;

  ObDocument({
    required this.uuid,
    required this.publicationId,
    required this.markdown,
    this.versionCounter = 0,
  });

  /// The relation is declared so ObjectBox cleans the row up with its
  /// publication; the text is read by id, never by traversing this.
  @TargetIdProperty('documentOwnerId')
  final publication = ToOne<ObPublication>();
}
