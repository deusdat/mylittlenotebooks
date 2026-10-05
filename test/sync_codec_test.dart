import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/embedding_validation.dart';
import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/invalid_embedding_exception.dart';
import 'package:mylittlenotebooks/data/sync/sync_codec.dart';
import 'package:mylittlenotebooks/data/sync/sync_payload.dart';

List<double> vector({int seed = 1, int dims = 256}) {
  final random = Random(seed);
  final values = List<double>.filled(dims, 0);
  for (var i = 0; i < dims; i++) {
    values[i] = random.nextDouble() - 0.5;
  }
  final norm = sqrt(values.fold<double>(0, (a, b) => a + b * b));
  return values.map((v) => v / norm).toList();
}

VersionDto version(int counter, [String device = 'd-peer']) =>
    VersionDto(counter: counter, deviceId: device);

void main() {
  late String publicationUuid;
  late String notebookUuid;

  setUp(() {
    publicationUuid = newUuidV7();
    notebookUuid = newUuidV7();
  });

  ChunkDto chunk(int index, {int seed = 0}) => ChunkDto(
        uuid: chunkUuidFor(publicationUuid, index),
        chunkIndex: index,
        content: 'chunk $index',
        tokenCount: 3,
        publicationUuid: publicationUuid,
        embeddingBase64: encodeVector(vector(seed: seed)),
        version: version(index + 1),
      );

  PublicationDto publication({
    int declared = 3,
    List<ChunkDto>? chunks,
    VersionDto? own,
    VersionDto? chunkSet,
  }) =>
      PublicationDto(
        uuid: publicationUuid,
        title: 'A publication',
        byteSize: 4096,
        embeddingModelId: 'test-model:int8:256',
        declaredChunkCount: declared,
        version: own ?? version(5),
        chunkSetVersion: chunkSet ?? version(5),
        notebookUuids: [notebookUuid],
        document: DocumentDto(
          uuid: documentUuidFor(publicationUuid),
          publicationUuid: publicationUuid,
          markdown: '# heading\n\nbody',
          version: version(1),
        ),
        chunks: chunks ?? [chunk(0), chunk(1, seed: 1), chunk(2, seed: 2)],
      );

  group('FR5c — the vector wire form', () {
    test('a 256-dimension vector is exactly 1368 base64 characters', () {
      expect(encodeVector(vector()).length, encodedVectorLength);
      expect(encodedVectorLength, 1368);
    });

    test('round-trips every component within float32 precision', () {
      final original = vector(seed: 7);
      final decoded = decodeVector(encodeVector(original));

      expect(decoded.length, VectorGeometry.dimensions);
      for (var i = 0; i < original.length; i++) {
        expect(decoded[i], closeTo(original[i], 1e-7), reason: 'at index $i');
      }
    });

    test('AC3b: JSON would be dramatically larger', () {
      // Without this assertion a regression to jsonEncode would inflate every
      // push silently rather than failing.
      final original = vector(seed: 7);
      final base64Length = encodeVector(original).length;
      final jsonLength = jsonEncode(original).length;

      // ignore: avoid_print
      print('base64=$base64Length chars, json=$jsonLength chars');
      expect(base64Length, lessThan(jsonLength));
      expect(jsonLength, greaterThan(5000),
          reason: 'measured at 5,319 for a real vector; a smaller figure means '
              'the measurement drifted and FR5c should be re-verified');
      expect(jsonLength / base64Length, greaterThan(3.0));
    });

    test('a wrongly-sized vector is rejected on decode', () {
      final short = base64.encode(Float32List.fromList(
              List<double>.filled(128, 0.1))
          .buffer
          .asUint8List());
      expect(() => decodeVector(short),
          throwsA(isA<InvalidEmbeddingException>()));
    });
  });

  group('FR1 — no int storage id in a payload', () {
    // AC3's real work: prove that adding an int storage id to a DTO breaks a
    // test. A weaker assertion — checking that one key it happens to know about
    // is a String — passes happily while a new `publicationLocalId` field sits
    // in the wire format, which is exactly the mistake this guards.
    //
    // Key-set equality is the strong version: the wire format is frozen, so any
    // added or removed field is a protocol change and must fail here.
    test('AC3: the wire format has exactly the expected keys', () {
      final encoded = encodePayload(SyncPayload(
        publications: [publication()],
        deletes: const [],
      ));
      final top = jsonDecode(encoded) as Map<String, dynamic>;

      expect(top.keys.toSet(),
          {'notebooks', 'publications', 'deletes', 'aiConfigs', 'notes'});

      final pub = (top['publications'] as List).single as Map<String, dynamic>;
      expect(
        pub.keys.toSet(),
        {
          'uuid',
          'title',
          'size',
          'model',
          'declaredChunks',
          'chunksIncluded',
          'v',
          'csv',
          'notebooks',
          'document',
          'chunks',
        },
        reason: 'the wire format is frozen; a new field is a protocol change '
            'and must be deliberate',
      );

      final doc = pub['document'] as Map<String, dynamic>;
      expect(doc.keys.toSet(), {'uuid', 'p', 'm', 'v'});

      final chunk = (pub['chunks'] as List).first as Map<String, dynamic>;
      expect(
        chunk.keys.toSet(),
        {'uuid', 'i', 'c', 't', 'p', 'e', 'v'},
        reason: 'an int storage id added here (e.g. publicationLocalId) must '
            'fail this test — that is the leak AC3 exists to catch',
      );

      final version = chunk['v'] as Map<String, dynamic>;
      expect(version.keys.toSet(), {'c', 'd'});
    });

    test('every identifier-shaped field holds a String', () {
      final encoded = encodePayload(SyncPayload(
        publications: [publication()],
        deletes: const [],
      ));
      final top = jsonDecode(encoded) as Map<String, dynamic>;
      final pub = (top['publications'] as List).single as Map<String, dynamic>;
      final chunk = (pub['chunks'] as List).first as Map<String, dynamic>;

      // `uuid` and `p` are the portable reference fields. `d` inside a version
      // is the device id. Every one must be a String; an int here is a leaked
      // local id.
      expect(chunk['uuid'], isA<String>());
      expect(chunk['p'], isA<String>());
      expect(pub['uuid'], isA<String>());
      expect(pub['notebooks'], everyElement(isA<String>()));
      expect((chunk['v'] as Map)['d'], isA<String>());
    });

    test('the integers that do appear are all legitimate', () {
      // chunkIndex, tokenCount, byteSize, the declared count, and the version
      // counter are real integers and must survive. The rule is about
      // *identifier* fields, not about banning ints from a JSON document.
      final encoded = encodePayload(SyncPayload(
        publications: [publication(declared: 3)],
        deletes: const [],
      ));
      final top = jsonDecode(encoded) as Map<String, dynamic>;
      final pub = (top['publications'] as List).single as Map<String, dynamic>;
      final chunk = (pub['chunks'] as List).first as Map<String, dynamic>;

      expect(pub['declaredChunks'], 3);
      expect(pub['size'], 4096);
      expect(chunk['i'], 0);
      expect(chunk['t'], 3);
    });
  });

  group('FR13 — deletes are records, not flags; tombstones never travel', () {
    test('the payload shape has no tombstone and no isDeleted', () {
      final dto = publication().toJson();
      expect(dto.containsKey('deleted'), isFalse);
      expect(dto.containsKey('tombstone'), isFalse);
      expect(dto.containsKey('isDeleted'), isFalse);
    });

    test('a delete is a uuid plus a version and nothing else', () {
      final encoded = encodePayload(SyncPayload(
        publications: const [],
        deletes: [DeleteDto(uuid: publicationUuid, version: version(9))],
      ));
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      final delete = (decoded['deletes'] as List).first as Map<String, dynamic>;

      expect(delete.keys.toSet(), {'uuid', 'v'});
    });
  });

  group('FR5a — the declared count travels outside the chunk list', () {
    test('it is a field distinct from the list', () {
      final json = publication(declared: 3, chunks: [chunk(0), chunk(1)])
          .toJson();
      expect(json['declaredChunks'], 3);
      expect((json['chunks'] as List), hasLength(2));
    });

    test('FR5a: version and chunkSetVersion are separate', () {
      final dto = publication(own: version(9), chunkSet: version(2));
      expect(dto.version.counter, 9);
      expect(dto.chunkSetVersion.counter, 2);
      expect(dto.toJson()['v'], isNot(dto.toJson()['csv']));
    });
  });

  group('decoding is total', () {
    test('a full round trip preserves everything', () {
      final original = SyncPayload(
        publications: [publication()],
        deletes: [DeleteDto(uuid: newUuidV7(), version: version(3))],
      );

      final decoded = decodePayload(encodePayload(original));
      expect(decoded.publications, hasLength(1));
      expect(decoded.deletes, hasLength(1));

      final pub = decoded.publications.single;
      expect(pub.uuid, publicationUuid);
      expect(pub.title, 'A publication');
      expect(pub.declaredChunkCount, 3);
      expect(pub.chunks, hasLength(3));
      expect(pub.document!.markdown, '# heading\n\nbody');
      expect(pub.chunks.map((c) => c.chunkIndex).toSet(), {0, 1, 2});
    });

    test('malformed JSON is refused', () {
      expect(() => decodePayload('{not json'),
          throwsA(isA<SyncPayloadException>()));
    });

    test('an unrecognised shape is refused rather than half-populated', () {
      expect(() => decodePayload('[]'),
          throwsA(isA<SyncPayloadException>()));
      expect(() => decodePayload('{"publications": 5}'),
          throwsA(isA<SyncPayloadException>()));
    });

    test('one malformed chunk refuses the whole payload', () {
      final encoded = jsonEncode({
        'publications': [
          {
            'uuid': publicationUuid,
            'title': 't',
            'size': 1,
            'model': 'm',
            'declaredChunks': 2,
            'v': version(1).toJson(),
            'csv': version(1).toJson(),
            'notebooks': <String>[],
            'chunks': [
              {
                'uuid': chunkUuidFor(publicationUuid, 0),
                'i': 0,
                'c': 'ok',
                't': 1,
                'p': publicationUuid,
                'e': encodeVector(vector()),
                'v': version(1).toJson(),
              },
              // Missing `content` — one bad record must not yield a partial set.
              {'uuid': 'broken'},
            ],
          }
        ],
        'deletes': <Object>[],
      });

      expect(() => decodePayload(encoded), throwsA(isA<SyncPayloadException>()));
    });
  });

  group('the receive-side uuid guard', () {
    test('a malformed uuid is refused on decode, before any write', () {
      final encoded = jsonEncode({
        'publications': [
          {
            'uuid': 'not-a-uuid',
            'title': 't',
            'size': 1,
            'model': 'm',
            'declaredChunks': 0,
            'v': version(1).toJson(),
            'csv': version(1).toJson(),
            'notebooks': <String>[],
            'chunks': <Object>[],
          }
        ],
        'deletes': <Object>[],
      });

      expect(() => decodePayload(encoded),
          throwsA(isA<SyncPayloadException>()));
    });

    test('a malformed uuid is refused on encode too', () {
      // A payload this device emits should never be one it would reject.
      final bad = PublicationDto(
        uuid: 'nope',
        title: 't',
        byteSize: 1,
        embeddingModelId: 'm',
        declaredChunkCount: 0,
        version: version(1),
        chunkSetVersion: version(1),
        notebookUuids: const [],
      );
      expect(
        () => encodePayload(SyncPayload(publications: [bad], deletes: const [])),
        throwsA(isA<SyncPayloadException>()),
      );
    });
  });
}
