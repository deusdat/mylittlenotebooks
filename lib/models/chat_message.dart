/// Who authored a chat message (spec FR34).
///
/// A plain enum with no sync vocabulary (spec NFR2). Stored as a string so no
/// ordinal is ever persisted.
enum ChatMessageRole { user, assistant }

/// A minimal, **local-only** chat message attached to a note (spec FR34).
///
/// A pure domain value: no `package:flutter`, no `package:objectbox` (spec
/// NFR1). It is not in `SyncPayload` and not a reference site (spec D31).
class ChatMessage {
  final String uuid;

  /// The note this message belongs to, by application-level uuid.
  final String noteUuid;

  final ChatMessageRole role;
  final String text;
  final DateTime createdAt;

  const ChatMessage({
    required this.uuid,
    required this.noteUuid,
    required this.role,
    required this.text,
    required this.createdAt,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatMessage &&
          other.uuid == uuid &&
          other.noteUuid == noteUuid &&
          other.role == role &&
          other.text == text &&
          other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(uuid, noteUuid, role, text, createdAt);

  @override
  String toString() => 'ChatMessage($uuid, ${role.name})';
}
