import 'package:objectbox/objectbox.dart';

import 'package:mylittlenotebooks/data/objectbox/ob_publication.dart';

/// Storage entity for a notebook (spec FR2).
///
/// The application-level identity is [uuid], not [id]. The int id is an
/// ObjectBox storage detail and must not leak into routes, UI state, or
/// cross-store references (spec FR5, plan D14).
@Entity()
class ObNotebook {
  @Id()
  int id = 0;

  /// Generated once, never reassigned. `@Unique` rather than `@Index`: a
  /// non-unique index permits duplicates, and a lookup by a duplicated uuid
  /// then returns an arbitrary one of them.
  @Unique()
  String uuid;

  String title;

  /// Half of this record's last-write-wins version (peer-sync FR9, FR10); the
  /// `deviceId` half lives once per store.
  ///
  /// Notebooks are synced as records in their own right — see `NotebookDto`. They
  /// have to be: a notebook referenced only by uuid arrives on the receiving
  /// device as an untitled row, which then renders in the sidebar as an empty
  /// label the user cannot tell from a bug.
  @Index()
  int versionCounter;

  @Property(type: PropertyType.dateUtc)
  DateTime createdAt;

  /// The many-to-many edge to publications (spec FR2, D1).
  ///
  /// Deliberately many-to-many: a publication may be attached to any number of
  /// notebooks and vice versa. Nothing in the schema encodes a cardinality of
  /// one — the initial UI's one-publication-per-notebook limit is a UI
  /// constraint, and enforcing it here would force a re-ingest of the user's
  /// whole library the day multi-select ships (spec D2).
  final publications = ToMany<ObPublication>();

  ObNotebook({
    required this.uuid,
    required this.title,
    required this.createdAt,
    this.versionCounter = 0,
  });
}
