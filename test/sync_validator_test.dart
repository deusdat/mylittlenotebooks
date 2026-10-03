import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/sync/sync_payload.dart';
import 'package:mylittlenotebooks/data/sync/sync_validator.dart';

import 'sync_test_fixtures.dart';

void main() {
  group('AC7d — a self-inconsistent payload is refused whole', () {
    test('declared 50, delivered 30', () {
      final uuid = newUuidV7();
      final publication = testPublication(
        uuid: uuid,
        count: 30,
        declared: 50,
      );
      expect(
        () => validateChunkSet(publication),
        throwsA(isA<ChunkSetRejection>()),
        reason: 'declared 50, received 30',
      );
    });

    test('declared 3, delivered indices 0,1,3 — a hole', () {
      final uuid = newUuidV7();
      final publication = testPublication(
        uuid: uuid,
        count: 3,
        declared: 3,
        chunks: [
          testChunk(uuid, 0),
          testChunk(uuid, 1),
          testChunk(uuid, 3), // hole at 2
        ],
      );
      expect(() => validateChunkSet(publication),
          throwsA(isA<ChunkSetRejection>()));
    });

    test('declared 3, delivered indices 1,2,3 — starts at 1', () {
      final uuid = newUuidV7();
      final publication = testPublication(
        uuid: uuid,
        count: 3,
        declared: 3,
        chunks: [
          testChunk(uuid, 1),
          testChunk(uuid, 2),
          testChunk(uuid, 3),
        ],
      );
      expect(() => validateChunkSet(publication),
          throwsA(isA<ChunkSetRejection>()));
    });

    test('a chunk claiming the wrong parent', () {
      final uuid = newUuidV7();
      final other = newUuidV7();
      final publication = testPublication(
        uuid: uuid,
        count: 2,
        chunks: [
          testChunk(uuid, 0),
          testChunk(uuid, 1, uuid: chunkUuidFor(other, 1)),
        ],
      );
      expect(() => validateChunkSet(publication),
          throwsA(isA<ChunkSetRejection>()));
    });

    test('a chunk whose uuid does not match its derived identity', () {
      // If this passes, re-applying a whole set would not be idempotent.
      final uuid = newUuidV7();
      final publication = testPublication(
        uuid: uuid,
        count: 1,
        chunks: [testChunk(uuid, 0, uuid: chunkUuidFor(uuid, 99))],
      );
      expect(() => validateChunkSet(publication),
          throwsA(isA<ChunkSetRejection>()));
    });
  });

  group('an acceptable set', () {
    test('contiguous chunks matching the declaration pass', () {
      expect(() => validateChunkSet(testPublication(count: 5)),
          returnsNormally);
    });

    test('AC7d: an empty set is ACCEPTED, not refused', () {
      // A publication that yielded no chunks, or one whose vectors the model
      // gate refused, legitimately declares zero. That is a state, not
      // corruption.
      expect(() => validateChunkSet(testPublication(count: 0)),
          returnsNormally);
    });

    test('a single chunk passes', () {
      expect(() => validateChunkSet(testPublication(count: 1)),
          returnsNormally);
    });
  });

  group('AC7e — truncation is detected BECAUSE of the declared count', () {
    // This is the check that cannot be made to fail. If the declaration were
    // removed, thirty contiguous chunks would be indistinguishable from a
    // legitimately thirty-chunk publication — which is exactly the bug planning
    // verification found and FR5a-bis exists to prevent.
    test('30 contiguous chunks with a declaration of 50 is refused', () {
      final uuid = newUuidV7();
      final publication = testPublication(uuid: uuid, count: 30, declared: 50);

      expect(
        () => validateChunkSet(publication),
        throwsA(isA<ChunkSetRejection>()),
        reason: 'truncation must be detectable',
      );
    });

    test('the same 30 chunks with a declaration of 30 is accepted', () {
      // Proves the declaration is the *only* thing making it detectable: the
      // chunk list is byte-identical between these two cases.
      final uuid = newUuidV7();
      final accepted = testPublication(uuid: uuid, count: 30, declared: 30);
      expect(() => validateChunkSet(accepted), returnsNormally);
    });
  });

  group('vectors are validated by the same boundary as a local write', () {
    test('a wrongly-sized vector is refused', () {
      final uuid = newUuidV7();
      final publication = testPublication(
        uuid: uuid,
        count: 1,
        chunks: [
          testChunk(uuid, 0, embedding: unitVector(0, dims: 128)),
        ],
      );
      expect(() => validateChunkSet(publication),
          throwsA(isA<ChunkSetRejection>()));
    });

    test('a vector that is not valid base64 is refused', () {
      final uuid = newUuidV7();
      final good = testChunk(uuid, 0);
      final publication = testPublication(
        uuid: uuid,
        count: 1,
        chunks: [
          ChunkDto(
            uuid: good.uuid,
            chunkIndex: good.chunkIndex,
            content: good.content,
            tokenCount: good.tokenCount,
            publicationUuid: good.publicationUuid,
            embeddingBase64: '!!!not base64!!!',
            version: good.version,
          ),
        ],
      );
      expect(() => validateChunkSet(publication),
          throwsA(isA<ChunkSetRejection>()));
    });
  });
}
