/// One indexed slice of a publication (spec FR2).
///
/// A pure domain value: no `package:flutter`, no `package:objectbox` (spec
/// NFR5).
///
/// Carries the **publication's uuid**, not its int id. The int id is a storage
/// detail and must not leak into the domain (spec FR5) — the repository
/// resolves between the two at its own boundary.
class Chunk {
  final String publicationUuid;

  /// 0-based and contiguous within a publication — a contract the chunker must
  /// honour (spec FR2).
  final int chunkIndex;

  final String content;

  final int tokenCount;

  /// The embedding vector. Exactly 256 dimensions (spec FR7, D11).
  final List<double> embedding;

  const Chunk({
    required this.publicationUuid,
    required this.chunkIndex,
    required this.content,
    required this.tokenCount,
    required this.embedding,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Chunk &&
          other.publicationUuid == publicationUuid &&
          other.chunkIndex == chunkIndex &&
          other.content == content &&
          other.tokenCount == tokenCount;

  /// Deliberately excludes [embedding]. Comparing 256-element lists makes
  /// `==` expensive and near-useless, and no caller needs value equality on a
  /// vector — the store is the authority on vector contents.
  @override
  int get hashCode =>
      Object.hash(publicationUuid, chunkIndex, content, tokenCount);

  @override
  String toString() => 'Chunk($publicationUuid#$chunkIndex, $tokenCount tokens)';
}

/// A chunk proposed for persistence, before it has an identity.
///
/// The write path takes this rather than [Chunk] so that no storage type
/// appears in a repository signature and so "not yet persisted" is
/// representable (spec plan §H, T15).
class ChunkDraft {
  final int chunkIndex;
  final String content;
  final int tokenCount;
  final List<double> embedding;

  const ChunkDraft({
    required this.chunkIndex,
    required this.content,
    required this.tokenCount,
    required this.embedding,
  });
}
