import 'package:objectbox/objectbox.dart';

import 'package:mylittlenotebooks/data/objectbox/ob_note.dart';

/// A minimal, **local-only** chat message attached to a note (spec FR34).
///
/// It is not part of `SyncPayload` and is not a sync reference site (spec D31):
/// nothing composes or sends a message in this feature, so there is nothing to
/// converge. It exists so the chat panel renders a real record rather than an
/// empty placeholder.
@Entity()
class ObChatMessage {
  @Id()
  int id = 0;

  @Unique()
  String uuid;

  @Index()
  int noteId;

  /// `'user'` or `'assistant'`. Stored as a string so the entity has no sync
  /// vocabulary and no enum-ordinal coupling.
  String role;

  String text;

  @Property(type: PropertyType.dateUtc)
  DateTime createdAt;

  /// The rename is mandatory, as for the note's other children: a `ToOne` named
  /// `note` would generate `noteId`, colliding with the denormalised column.
  @TargetIdProperty('messageOwnerId')
  final note = ToOne<ObNote>();

  ObChatMessage({
    required this.uuid,
    required this.noteId,
    required this.role,
    required this.text,
    required this.createdAt,
  });
}
