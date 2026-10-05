/// One indexed slice of a note's body (spec FR4, FR5).
///
/// A pure domain value: no `package:flutter`, no `package:objectbox` (spec
/// NFR1). Carries the **note's uuid**, not its int id (spec FR5).
class NoteChunk {
  final String noteUuid;

  /// 0-based and contiguous within a note (spec FR6).
  final int chunkIndex;

  final String content;
  final int tokenCount;

  /// Exactly 256 dimensions (spec FR4, D15).
  final List<double> embedding;

  const NoteChunk({
    required this.noteUuid,
    required this.chunkIndex,
    required this.content,
    required this.tokenCount,
    required this.embedding,
  });

  /// Deliberately excludes [embedding]: comparing 256-element lists is
  /// expensive and no caller needs value equality on a vector.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NoteChunk &&
          other.noteUuid == noteUuid &&
          other.chunkIndex == chunkIndex &&
          other.content == content &&
          other.tokenCount == tokenCount;

  @override
  int get hashCode => Object.hash(noteUuid, chunkIndex, content, tokenCount);

  @override
  String toString() => 'NoteChunk($noteUuid#$chunkIndex, $tokenCount tokens)';
}
