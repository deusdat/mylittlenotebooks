import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/invalid_embedding_exception.dart';
import 'package:mylittlenotebooks/data/sync/sync_codec.dart';
import 'package:mylittlenotebooks/data/sync/sync_payload.dart';

/// Refuses an internally inconsistent chunk set (spec FR5a-bis).
///
/// **Why a declared count is needed at all.** Measured during planning: a
/// 50-chunk set truncated to 30 **passed** a count-and-contiguity check that did
/// not compare against a declaration. Thirty contiguous chunks are
/// indistinguishable from a legitimately thirty-chunk publication, so the
/// receiver cannot infer truncation on its own.
///
/// **The declaration is a check, never a repair.** On mismatch this refuses the
/// whole payload and the receiver's existing chunk set is left byte-for-byte
/// unchanged. Inferring what *should* exist and pruning toward it is the
/// boundary-marker approach this spec replaced, and it is unsafe: the count and
/// the chunks are two travelling facts that must agree exactly, and a truncated
/// payload is indistinguishable from a complete one at the store.
class ChunkSetRejection implements Exception {
  final String reason;

  const ChunkSetRejection(this.reason);

  @override
  String toString() => 'ChunkSetRejection: $reason';
}

/// Validates an incoming chunk set against the sender's declared count.
///
/// Returns normally when the set is acceptable. Throws [ChunkSetRejection] when
/// the payload must be refused whole.
///
/// **An empty set is legitimate** — a publication whose text yielded no chunks,
/// or one whose vectors the `embeddingModelId` gate refused (FR5b), declares
/// `0` and arrives with nothing. That is a state, not corruption.
void validateChunkSet(PublicationDto publication) {
  final declared = publication.declaredChunkCount;
  final chunks = publication.chunks;

  // An omitted set must look omitted. A payload that says "no set was selected"
  // while listing chunks is internally inconsistent in the same way a truncated
  // one is, and refusing it costs nothing.
  if (!publication.chunksIncluded && (chunks.isNotEmpty || declared != 0)) {
    throw ChunkSetRejection(
      'publication ${publication.uuid} declares no chunk set but carries '
      '${chunks.length} chunk(s) and declares $declared',
    );
  }

  if (chunks.length != declared) {
    throw ChunkSetRejection(
      'publication ${publication.uuid} declares $declared chunk(s) but '
      '${chunks.length} arrived',
    );
  }

  // Indices must be contiguous from 0. Catches a hole (`0,1,3`) and a set that
  // starts at 1, both of which a count check alone would accept.
  final indices = chunks.map((c) => c.chunkIndex).toList()..sort();
  for (var expected = 0; expected < indices.length; expected++) {
    if (indices[expected] != expected) {
      throw ChunkSetRejection(
        'publication ${publication.uuid} chunk indices are not contiguous from '
        '0: expected $expected, found ${indices[expected]}',
      );
    }
  }

  // Every chunk's parent must be this publication. A chunk pointing elsewhere
  // would make scoped search return it for the wrong scope.
  for (final chunk in chunks) {
    if (chunk.publicationUuid != publication.uuid) {
      throw ChunkSetRejection(
        'chunk ${chunk.uuid} claims parent ${chunk.publicationUuid} but '
        'arrived inside publication ${publication.uuid}',
      );
    }
    // The derived identity must match the position, or re-applying the set would
    // not be idempotent (FR2a).
    if (chunk.uuid != chunkUuidFor(publication.uuid, chunk.chunkIndex)) {
      throw ChunkSetRejection(
        'chunk at index ${chunk.chunkIndex} has uuid ${chunk.uuid}, which '
        'does not match its derived identity',
      );
    }
  }

  // Every vector must be storable. Reuses the same boundary that refuses a
  // malformed local write, so a payload cannot smuggle in a vector the store
  // would silently ignore.
  for (final chunk in chunks) {
    _validateVector(chunk.uuid, chunk.embeddingBase64);
  }
}

/// Validates an incoming **note** chunk set against its declaration
/// (spec FR22). The note analogue of [validateChunkSet]; refuses the whole
/// payload on any inconsistency.
void validateNoteChunkSet(NoteDto note) {
  final declared = note.declaredChunkCount;
  final chunks = note.chunks;

  if (!note.chunksIncluded && (chunks.isNotEmpty || declared != 0)) {
    throw ChunkSetRejection(
      'note ${note.uuid} declares no chunk set but carries '
      '${chunks.length} chunk(s) and declares $declared',
    );
  }

  if (chunks.length != declared) {
    throw ChunkSetRejection(
      'note ${note.uuid} declares $declared chunk(s) but ${chunks.length} '
      'arrived',
    );
  }

  final indices = chunks.map((c) => c.chunkIndex).toList()..sort();
  for (var expected = 0; expected < indices.length; expected++) {
    if (indices[expected] != expected) {
      throw ChunkSetRejection(
        'note ${note.uuid} chunk indices are not contiguous from 0: expected '
        '$expected, found ${indices[expected]}',
      );
    }
  }

  for (final chunk in chunks) {
    if (chunk.noteUuid != note.uuid) {
      throw ChunkSetRejection(
        'chunk ${chunk.uuid} claims parent ${chunk.noteUuid} but arrived '
        'inside note ${note.uuid}',
      );
    }
    if (chunk.uuid != noteChunkUuidFor(note.uuid, chunk.chunkIndex)) {
      throw ChunkSetRejection(
        'chunk at index ${chunk.chunkIndex} has uuid ${chunk.uuid}, which does '
        'not match its derived identity',
      );
    }
  }

  for (final chunk in chunks) {
    _validateVector(chunk.uuid, chunk.embeddingBase64);
  }
}

void _validateVector(String uuid, String embeddingBase64) {
  try {
    decodeVector(embeddingBase64);
  } on SyncPayloadException catch (error) {
    throw ChunkSetRejection('chunk $uuid: ${error.reason}');
  } on InvalidEmbeddingException catch (error) {
    throw ChunkSetRejection(
      'chunk $uuid has a ${error.actualLength}-dimension vector, '
      'not ${error.expectedLength}',
    );
  } on FormatException {
    throw ChunkSetRejection('chunk $uuid: vector is not valid base64');
  }
}
