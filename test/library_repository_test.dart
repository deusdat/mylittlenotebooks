import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/library_repository.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_document.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_publication.dart';
import 'package:mylittlenotebooks/domain_mapping.dart';
import 'package:mylittlenotebooks/data/objectbox_library_repository.dart';
import 'package:mylittlenotebooks/data/objectbox_notebook_repository.dart';
import 'package:mylittlenotebooks/data/objectbox_publication_repository.dart';
import 'package:mylittlenotebooks/data/search_repository.dart';
import 'package:mylittlenotebooks/models/chunk.dart';
import 'package:mylittlenotebooks/models/publication.dart';
import 'package:objectbox/objectbox.dart';

const model = 'test-model:int8:256';

/// A deterministic unit vector. Seeded so a failure is reproducible.
List<double> unitVector(int seed, {int dims = 256}) {
  final random = Random(seed);
  final values = List<double>.filled(dims, 0);
  for (var i = 0; i < dims; i++) {
    values[i] = random.nextDouble() - 0.5;
  }
  final norm = sqrt(values.fold<double>(0, (a, b) => a + b * b));
  return values.map((v) => v / norm).toList();
}

ChunkDraft draft(int index, {int seed = 0, String? content}) => ChunkDraft(
      chunkIndex: index,
      content: content ?? 'chunk $index',
      tokenCount: 3,
      embedding: unitVector(seed),
    );

void main() {
  late Store store;
  late ObjectBoxNotebookRepository notebooks;
  late ObjectBoxLibraryRepository library;
  late ObjectBoxPublicationRepository publications;
  late ObjectBoxSearchRepository search;

  setUp(() {
    store = openTestStore('library');
    notebooks = ObjectBoxNotebookRepository(store);
    library = ObjectBoxLibraryRepository(store);
    publications = ObjectBoxPublicationRepository(store);
    search = ObjectBoxSearchRepository(store);
  });

  tearDown(() => store.close());

  group('AC2 — many-to-many association, both directions', () {
    test('one publication attached to two notebooks is visible from both', () {
      final a = notebooks.create();
      final b = notebooks.create();
      final publication = library.create(
        title: 'Shared',
        sourceMarkdown: '# shared',
        embeddingModelId: model,
      );

      library.attach(publication.uuid, a.id);
      library.attach(publication.uuid, b.id);

      // Direction 1: from each notebook's ToMany.
      expect(
        publications.listForNotebook(a.id).map((p) => p.uuid),
        [publication.uuid],
      );
      expect(
        publications.listForNotebook(b.id).map((p) => p.uuid),
        [publication.uuid],
      );

      // Direction 2: from the publication's @Backlink. Reading only one side
      // would pass against a broken relation, so both are asserted.
      expect(
        publications.attachments(publication.uuid).toSet(),
        {a.id, b.id},
      );
    });

    test('one notebook holds many publications', () {
      final notebook = notebooks.create();
      final first = library.create(
        title: 'First',
        sourceMarkdown: 'first',
        embeddingModelId: model,
      );
      final second = library.create(
        title: 'Second',
        sourceMarkdown: 'second',
        embeddingModelId: model,
      );

      library.attach(first.uuid, notebook.id);
      library.attach(second.uuid, notebook.id);

      expect(
        publications.listForNotebook(notebook.id).map((p) => p.uuid).toSet(),
        {first.uuid, second.uuid},
      );
      expect(publications.attachments(first.uuid), [notebook.id]);
      expect(publications.attachments(second.uuid), [notebook.id]);
    });

    test('an unattached notebook lists nothing and does not error', () {
      final empty = notebooks.create();
      library.create(
        title: 'Orphan',
        sourceMarkdown: 'orphan',
        embeddingModelId: model,
      );
      expect(publications.listForNotebook(empty.id), isEmpty);
      expect(
        publications.listForNotebook('no-such-notebook'),
        isEmpty,
      );
    });
  });

  group('AC3 — attach and detach are idempotent', () {
    test('attaching three times leaves exactly one association', () {
      final notebook = notebooks.create();
      final publication = library.create(
        title: 'Once',
        sourceMarkdown: 'once',
        embeddingModelId: model,
      );

      library
        ..attach(publication.uuid, notebook.id)
        ..attach(publication.uuid, notebook.id)
        ..attach(publication.uuid, notebook.id);

      // The **count**, not merely that the call returned — a duplicate
      // association is invisible otherwise.
      expect(publications.attachments(publication.uuid), hasLength(1));
      expect(publications.listForNotebook(notebook.id), hasLength(1));
    });

    test('detaching twice is a no-op', () {
      final notebook = notebooks.create();
      final publication = library.create(
        title: 'Twice',
        sourceMarkdown: 'twice',
        embeddingModelId: model,
      );
      library.attach(publication.uuid, notebook.id);

      library
        ..detach(publication.uuid, notebook.id)
        ..detach(publication.uuid, notebook.id);

      expect(publications.attachments(publication.uuid), isEmpty);
      expect(publications.byUuid(publication.uuid), isNotNull);
    });

    test('detach leaves the publication in place', () {
      final notebook = notebooks.create();
      final publication = library.create(
        title: 'Kept',
        sourceMarkdown: 'kept',
        embeddingModelId: model,
      );
      library
        ..attach(publication.uuid, notebook.id)
        ..detach(publication.uuid, notebook.id);

      expect(publications.byUuid(publication.uuid), isNotNull);
    });
  });

  group('AC4 — round-trip of the source document', () {
    test('markdown, title, byteSize and importedAt survive a round trip', () {
      // Non-ASCII on purpose: `String.length` counts UTF-16 code units and
      // would disagree with the stored byte count for any of these.
      const markdown = '# Título — naïve café 😀\n\nbody';
      final created = library.create(
        title: 'Unicode',
        sourceMarkdown: markdown,
        embeddingModelId: model,
      );
      library.replaceChunks(created.uuid, [draft(0)]);

      final read = publications.byUuid(created.uuid)!;
      expect(read.sourceMarkdown, markdown);
      expect(read.title, 'Unicode');
      expect(read.byteSize, greaterThan(markdown.length));
      expect(read.importedAt, created.importedAt);
      expect(read.embeddingModelId, model);
      expect(read.chunkCount, 1);
    });

    test('byteSize is the UTF-8 length, not the UTF-16 length', () {
      final ascii = library.create(
        title: 'ascii',
        sourceMarkdown: 'abcde',
        embeddingModelId: model,
      );
      final accented = library.create(
        title: 'accented',
        sourceMarkdown: 'ééé',
        embeddingModelId: model,
      );

      expect(publications.byUuid(ascii.uuid)!.byteSize, 5);
      // 3 characters, 6 UTF-8 bytes.
      expect(publications.byUuid(accented.uuid)!.byteSize, 6);
    });
  });

  group('AC5 — empty source is rejected', () {
    test('empty and whitespace-only markdown are both refused', () {
      for (final source in ['', '   ', '\n\t  \n']) {
        expect(
          () => library.create(
            title: 'Empty',
            sourceMarkdown: source,
            embeddingModelId: model,
          ),
          throwsA(isA<EmptySourceException>()),
          reason: 'source ${jsonish(source)} must be rejected',
        );
      }
    });

    test('nothing is persisted when the source is rejected', () {
      final before = publications.listAll().length;
      expect(
        () => library.create(
          title: 'Empty',
          sourceMarkdown: '  ',
          embeddingModelId: model,
        ),
        throwsA(isA<EmptySourceException>()),
      );
      expect(publications.listAll(), hasLength(before));
    });
  });

  group('AC7 — the source document is the record of truth', () {
    test('a publication survives deletion of the file it came from', () {
      final directory = Directory.systemTemp.createTempSync('ac7');
      final file = File('${directory.path}/source.md')
        ..writeAsStringSync('# from disk\n\ncontent');

      // Imported exactly as an importer would: read the bytes, store the text.
      final publication = library.create(
        title: 'From disk',
        sourceMarkdown: file.readAsStringSync(),
        embeddingModelId: model,
      );
      library.replaceChunks(publication.uuid, [draft(0, content: 'chunk')]);

      file.deleteSync();
      directory.deleteSync();

      final read = publications.byUuid(publication.uuid);
      expect(read, isNotNull);
      expect(read!.sourceMarkdown, '# from disk\n\ncontent');

      // And it is still findable, which is the point of storing the text.
      final hits = search.search(
        queryVector: unitVector(0),
        publicationIds: search.resolvePublicationIds([publication.uuid]),
        limit: 10,
      );
      expect(hits, hasLength(1));
    });
  });

  group('FR6 — embedding model identity', () {
    test('every publication exposes its model and they are enumerable', () {
      final a = library.create(
        title: 'A',
        sourceMarkdown: 'a',
        embeddingModelId: 'model-a:256',
      );
      final b = library.create(
        title: 'B',
        sourceMarkdown: 'b',
        embeddingModelId: 'model-b:384',
      );

      expect(publications.embeddingModelIds(), ['model-a:256', 'model-b:384']);
      expect(
        publications.byEmbeddingModel('model-b:384').map((p) => p.uuid),
        [b.uuid],
      );
      expect(publications.byUuid(a.uuid)!.embeddingModelId, 'model-a:256');
    });

    test('a single model yields a single id', () {
      library.create(
        title: 'A',
        sourceMarkdown: 'a',
        embeddingModelId: model,
      );
      library.create(
        title: 'B',
        sourceMarkdown: 'b',
        embeddingModelId: model,
      );
      expect(publications.embeddingModelIds(), [model]);
    });
  });

  group('AC12 — deleting a publication', () {
    test('removes its chunks and leaves every notebook intact', () {
      final notebook = notebooks.create();
      final publication = library.create(
        title: 'Doomed',
        sourceMarkdown: 'doomed',
        embeddingModelId: model,
      );
      library
        ..attach(publication.uuid, notebook.id)
        ..replaceChunks(publication.uuid, [draft(0), draft(1, seed: 1)]);

      expect(search.search(
        queryVector: unitVector(0),
        publicationIds: search.resolvePublicationIds([publication.uuid]),
        limit: 10,
      ), hasLength(2));

      library.deletePublication(publication.uuid);

      // Gone, with its vectors.
      expect(publications.byUuid(publication.uuid), isNull);
      expect(
        search.search(
          queryVector: unitVector(0),
          publicationIds: null,
          limit: 10,
        ),
        isEmpty,
        reason: 'chunks must not outlive their publication',
      );

      // The notebook survives, holding one fewer publication (FR12).
      expect(notebooks.exists(notebook.id), isTrue);
      expect(publications.listForNotebook(notebook.id), isEmpty);
    });
  });

  group('AC13 — deleting a notebook never over-deletes', () {
    test('a shared publication and its chunks survive', () {
      final keep = notebooks.create();
      final drop = notebooks.create();
      final publication = library.create(
        title: 'Shared',
        sourceMarkdown: 'shared',
        embeddingModelId: model,
      );
      library
        ..attach(publication.uuid, keep.id)
        ..attach(publication.uuid, drop.id)
        ..replaceChunks(publication.uuid, [draft(0), draft(1, seed: 1)]);

      library.deleteNotebook(drop.id);

      expect(notebooks.exists(drop.id), isFalse);
      expect(notebooks.exists(keep.id), isTrue);

      // The publication itself is untouched...
      expect(publications.byUuid(publication.uuid), isNotNull);
      expect(publications.attachments(publication.uuid), [keep.id]);
      expect(
        publications.listForNotebook(keep.id).map((p) => p.uuid),
        [publication.uuid],
      );

      // ...and it is still searchable, which is the real assertion. A test
      // that only checked survival would pass against a cascade that had
      // quietly removed the vectors.
      final hits = search.search(
        queryVector: unitVector(0),
        publicationIds: search.resolvePublicationIds([publication.uuid]),
        limit: 10,
      );
      expect(hits, hasLength(2));
    });

    test('an exclusive publication survives its only notebook', () {
      final only = notebooks.create();
      final publication = library.create(
        title: 'Exclusive',
        sourceMarkdown: 'exclusive',
        embeddingModelId: model,
      );
      library
        ..attach(publication.uuid, only.id)
        ..replaceChunks(publication.uuid, [draft(0)]);

      library.deleteNotebook(only.id);

      expect(publications.byUuid(publication.uuid), isNotNull);
      expect(
        search.search(
          queryVector: unitVector(0),
          publicationIds: search.resolvePublicationIds([publication.uuid]),
          limit: 10,
        ),
        hasLength(1),
      );
    });
  });

  group('NFR6 — list paths never read the source text', () {
    test('list methods return summaries, which carry no source text', () {
      library.create(
        title: 'Doc',
        sourceMarkdown: 'x' * 5000,
        embeddingModelId: model,
      );
      final notebook = notebooks.create();
      library.attach(publications.listAll().single.uuid, notebook.id);

      // Compile-time guarantee: a `PublicationSummary` has no
      // `sourceMarkdown` field at all, so a list caller *cannot* accidentally
      // read the document. This is what makes NFR6 true rather than
      // aspirational (spec correction 3).
      final PublicationSummary summary =
          publications.listForNotebook(notebook.id).single;
      expect(summary.title, 'Doc');
      expect(summary.byteSize, 5000);

      final all = publications.listAll();
      expect(all, isA<List<PublicationSummary>>());
      expect(all.single, isA<PublicationSummary>());
    });

    test('the document lives in its own row, not on the publication', () {
      final created = library.create(
        title: 'Split',
        sourceMarkdown: '# heading\n\nbody text',
        embeddingModelId: model,
      );

      // The publication row is metadata only.
      final row = store.box<ObPublication>().getAll().single;
      expect(row.byteSize, created.byteSize);
      expect(row.toSummary().byteSize, created.byteSize);

      // The text is a separate row, so ObjectBox's whole-object load on a list
      // query cannot pull it in.
      final documents = store.box<ObDocument>().getAll();
      expect(documents, hasLength(1));
      expect(documents.single.markdown, '# heading\n\nbody text');
      expect(documents.single.publicationId, row.id);
    });

    test('byUuid is the only read that returns the text', () {
      library.create(
        title: 'Readable',
        sourceMarkdown: 'the actual text',
        embeddingModelId: model,
      );
      expect(
        publications.byUuid(publications.listAll().single.uuid)!.sourceMarkdown,
        'the actual text',
      );
    });

    test('deleting a publication removes its document row', () {
      final created = library.create(
        title: 'Doomed doc',
        sourceMarkdown: 'text that must not leak',
        embeddingModelId: model,
      );
      expect(store.box<ObDocument>().count(), 1);

      library.deletePublication(created.uuid);

      expect(
        store.box<ObDocument>().count(),
        0,
        reason: 'orphaned document text would grow without bound and could '
            'resurface under a re-used uuid',
      );
    });
  });

  group('unknown identifiers', () {
    test('mutating a missing publication or notebook throws', () {
      expect(
        () => library.attach('nope', 'also-nope'),
        throwsA(isA<StateError>()),
      );
      expect(
        () => library.deletePublication('nope'),
        throwsA(isA<StateError>()),
      );
      expect(
        () => library.deleteNotebook('nope'),
        throwsA(isA<StateError>()),
      );
    });
  });
}

String jsonish(String s) => '"${s.replaceAll('\n', r'\n').replaceAll('\t', r'\t')}"';
