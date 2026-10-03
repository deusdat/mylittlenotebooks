import 'dart:math';

import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_document.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_notebook.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_publication.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_tombstone.dart';
import 'package:mylittlenotebooks/data/sync/sync_codec.dart';
import 'package:mylittlenotebooks/data/sync/sync_payload.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';
import 'package:objectbox/objectbox.dart' show Box, Store;

/// Shared fixtures for the sync tests.
///
/// Seeded vectors and fixed uuids, so a failure is reproducible and a test can
/// assert on exact values.

/// A deterministic unit vector. Seeded so failures are reproducible.
List<double> unitVector(int seed, {int dims = 256}) {
  final random = Random(seed);
  final values = List<double>.filled(dims, 0);
  for (var i = 0; i < dims; i++) {
    values[i] = random.nextDouble() - 0.5;
  }
  final norm = sqrt(values.fold<double>(0, (a, b) => a + b * b));
  return values.map((v) => v / norm).toList();
}

const testModel = 'test-model:int8:256';

VersionDto testVersion([int counter = 1, String device = 'd-peer']) =>
    VersionDto(counter: counter, deviceId: device);

/// A publication row written directly, bypassing the repository.
ObPublication seedPublication(
  Store store, {
  String? uuid,
  String title = 'Seeded',
  String embeddingModel = testModel,
}) {
  final entity = ObPublication(
    uuid: uuid ?? newUuidV7(),
    title: title,
    byteSize: 0,
    importedAt: DateTime.now().toUtc(),
    embeddingModelId: embeddingModel,
  );
  store.box<ObPublication>().put(entity);
  return entity;
}

ChunkDto testChunk(
  String publicationUuid,
  int index, {
  int seed = 0,
  String? uuid,
  List<double>? embedding,
}) =>
    ChunkDto(
      uuid: uuid ?? chunkUuidFor(publicationUuid, index),
      chunkIndex: index,
      content: 'chunk $index',
      tokenCount: 3,
      publicationUuid: publicationUuid,
      embeddingBase64: encodeVector(embedding ?? unitVector(seed)),
      version: testVersion(index + 1),
    );

/// A publication payload with [count] contiguous chunks.
PublicationDto testPublication({
  String? uuid,
  int count = 3,
  int? declared,
  String title = 'Incoming',
  String embeddingModel = testModel,
  List<String>? notebookUuids,
  VersionDto? version,
  VersionDto? chunkSetVersion,
  List<ChunkDto>? chunks,
}) {
  final id = uuid ?? newUuidV7();
  return PublicationDto(
    uuid: id,
    title: title,
    byteSize: 4096,
    embeddingModelId: embeddingModel,
    declaredChunkCount: declared ?? count,
    version: version ?? testVersion(5),
    chunkSetVersion: chunkSetVersion ?? testVersion(5),
    notebookUuids: notebookUuids ?? [newUuidV7()],
    document: DocumentDto(
      uuid: documentUuidFor(id),
      publicationUuid: id,
      markdown: '# heading\n\nbody',
      version: testVersion(1),
    ),
    chunks: chunks ??
        [for (var i = 0; i < count; i++) testChunk(id, i, seed: i)],
  );
}

/// A comparable description of a whole store.
///
/// Used by the convergence and idempotency assertions: two stores converge when
/// this string matches, so it has to cover **everything** that sync moves —
/// including the vectors, which revision 1 of this spec could not claim and which
/// are the practical reason for syncing chunks at all.
///
/// Sorted throughout, because row order is not part of the state. Embeddings are
/// rendered at fixed precision: they survive a float32 round trip, so an exact
/// comparison would be a flakiness source rather than a stronger assertion.
String storeSnapshot(Store store) {
  String describe<T>(Box<T> box, String Function(T) render) {
    final rows = box.getAll().map(render).toList()..sort();
    return rows.join('\n');
  }

  return [
    describe<ObPublication>(
      store.box<ObPublication>(),
      (p) => 'publication ${p.uuid}\n'
          '  title=${p.title}\n'
          '  byteSize=${p.byteSize}\n'
          '  model=${p.embeddingModelId}\n'
          '  chunkCount=${p.chunkCount}\n'
          '  version=${p.versionCounter}\n'
          '  chunkSetVersion=${p.chunkSetVersion}\n'
          '  notebooks=${(p.notebooks.map((n) => n.uuid).toList()..sort()).join(",")}',
    ),
    describe<ObDocument>(
      store.box<ObDocument>(),
      (d) => 'document ${d.uuid} parent=${d.publicationId} '
          'toOne=${d.publication.targetId} version=${d.versionCounter}\n'
          '  ${d.markdown}',
    ),
    describe<ObChunk>(
      store.box<ObChunk>(),
      (c) => 'chunk ${c.uuid}\n'
          '  index=${c.chunkIndex}\n'
          '  content=${c.content}\n'
          '  tokens=${c.tokenCount}\n'
          '  parent=${c.publicationId}\n'
          '  toOne=${c.publication.targetId}\n'
          '  embedding=${c.embedding.map(vectorComponent).join(",")}',
    ),
    describe<ObNotebook>(
      store.box<ObNotebook>(),
      (n) => 'notebook ${n.uuid} title=${n.title} '
          'publications=${(n.publications.map((p) => p.uuid).toList()..sort()).join(",")}',
    ),
    describe<ObTombstone>(
      store.box<ObTombstone>(),
      (t) => 'tombstone ${t.uuid} version=${t.versionCounter}',
    ),
  ].join('\n');
}

String vectorComponent(double value) => value.toStringAsFixed(5);

/// Deterministic vectors for a whole publication, so a seeded corpus is
/// reproducible across runs and a convergence failure can be reproduced exactly.
List<List<double>> corpusVectors(int count, {int seed = 0}) => [
      for (var i = 0; i < count; i++) unitVector(seed + i),
    ];
