import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/models/chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_device_meta.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_document.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_notebook.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_peer_watermark.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_publication.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_tombstone.dart';
import 'package:mylittlenotebooks/data/objectbox_library_repository.dart';
import 'package:mylittlenotebooks/data/sync/push_sender.dart';
import 'package:mylittlenotebooks/data/sync/sync_apply.dart';
import 'package:mylittlenotebooks/data/sync/sync_tombstones.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

import 'sync_test_fixtures.dart';

/// OR1 — children are always separate entities with their own identity.
///
/// **An over rule, not a sync detail.** It governs the schema unconditionally, in
/// every context, whether or not sync exists. What follows is what makes it
/// enforceable rather than folklore: a schema scan that fails the moment a
/// parent grows a column holding its children, and a behavioural test of the
/// failure it prevents.
void main() {
  group('OR1 — no entity embeds its children (AC12)', () {
    late Map<String, dynamic> model;

    setUpAll(() {
      model = jsonDecode(File('lib/objectbox-model.json').readAsStringSync())
          as Map<String, dynamic>;
    });

    /// Property types that could physically hold a serialized collection.
    const blobTypes = <int>{9, 23, 26, 28};

    /// A name that says "this column holds a set".
    ///
    /// Plural, `…Ids`, or an explicit serialization marker. Deliberately narrow:
    /// a column called `content` or `markdown` is text, and flagging every string
    /// in the schema would flag every title and fail on contact with the real
    /// model — which is the same mistake as scanning reflectively and trusting it.
    final collectionName = RegExp(
      r'(Ids|Uuids|List|Json|Csv|Serialized|Embedded|Refs|Links)$|s$',
      caseSensitive: false,
    );

    /// One identifier: a uuid, or one of this app's derived forms.
    final identifierLike = RegExp(
      r'^(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
      r'|[cd]-[0-9a-f-]+)$',
    );

    /// Whether a column is holding a serialized child collection.
    ///
    /// Two independent signals, because either alone has a hole:
    ///
    /// * **By name** — catches a column that is empty, or that happens to hold
    ///   something unparseable. A blob holding arbitrary bytes has no shape to
    ///   recognise.
    /// * **By value** — catches a column with an innocent name. `json` and
    ///   `serialized` are not the only ways this gets done; `cardIds` holding
    ///   `"a,b,c"` is the same violation.
    bool holdsChildCollection(String name, String? value) {
      if (collectionName.hasMatch(name)) return true;
      if (value == null) return false;

      final trimmed = value.trim();
      if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is List || decoded is Map) return true;
        } on FormatException {
          // Not JSON after all — fall through to the delimited check.
        }
      }

      // Two or more identifier-shaped tokens in one delimited string.
      final parts = trimmed
          .split(RegExp(r'[,;|\n]'))
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toList();
      return parts.length >= 2 && parts.every(identifierLike.hasMatch);
    }

    test('every entity is in the scan, so the scan cannot quietly skip one', () {
      // A scan that silently misses an entity is the same failure mode as the
      // seven-site list: it passes while the thing it exists to catch is there.
      final scanned = (model['entities'] as List)
          .map((e) => (e as Map<String, dynamic>)['name'] as String)
          .toList();

      expect(scanned, containsAll(<String>[
        'ObNotebook',
        'ObPublication',
        'ObDocument',
        'ObChunk',
      ]));
      expect(scanned, hasLength((model['entities'] as List).length));
    });

    test('AC12: no entity holds a serialized child collection', () {
      final offenders = <String>[];

      for (final raw in model['entities'] as List) {
        final entity = raw as Map<String, dynamic>;
        final name = entity['name'] as String;

        for (final rawProperty in entity['properties'] as List) {
          final property = rawProperty as Map<String, dynamic>;
          final propertyName = property['name'] as String;
          final type = property['type'] as int;
          if (!blobTypes.contains(type)) continue;

          // The one legitimate byte-array column: a 256-dimension float vector,
          // which holds no entity. Named explicitly, so a *second* array column
          // cannot slip through under this exemption.
          if (name == 'ObChunk' && propertyName == 'embedding') continue;

          if (collectionName.hasMatch(propertyName)) {
            offenders.add('$name.$propertyName');
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: 'OR1: a parent must never hold its children — not as JSON, not '
            'as a blob, not as a delimited string. Each child needs its own row '
            'and its own uuid, because last-write-wins can only keep both edits '
            'when the two records are independent. A column named "chunkUuids", '
            '"tags", "cardsJson" or "cardIds" is the shape this rule forbids. '
            'Offenders: $offenders',
      );
    });

    test('every string column has a reader, so the value scan cannot skip one',
        () {
      // The guard on the hand-written reader list. Without it, adding a
      // `cardsJson` column and forgetting to read it would make the value scan
      // pass vacuously — which is the failure mode this whole exercise exists to
      // prevent.
      final store = openTestStore('or1-completeness');
      addTearDown(store.close);
      final readers = storedStringValues(store).keys.toSet();

      final expected = <String>{};
      for (final raw in model['entities'] as List) {
        final entity = raw as Map<String, dynamic>;
        final name = entity['name'] as String;
        for (final rawProperty in entity['properties'] as List) {
          final property = rawProperty as Map<String, dynamic>;
          if (property['type'] != 9) continue;
          expected.add('$name.${property['name']}');
        }
      }

      expect(
        expected.difference(readers),
        isEmpty,
        reason: 'these string columns exist in the schema but no reader covers '
            'them, so the OR1 value scan cannot see them. Add a reader or argue '
            'why the column cannot hold a collection.',
      );
    });

    test('AC12: no stored value is a serialized child collection', () {
      // The half of the check an innocent column name cannot defeat. Every value
      // of every string column is inspected, so a violation has to hold an actual
      // JSON array or a delimited run of identifiers to be caught.
      final store = openTestStore('or1-scan');
      addTearDown(store.close);

      final library = ObjectBoxLibraryRepository(store);
      final publication = library.create(
          title: 'Scan me',
          sourceMarkdown: 'body',
          embeddingModelId: testModel);
      library.replaceChunks(publication.uuid, [
        ChunkDraft(
          chunkIndex: 0,
          content: 'chunk',
          tokenCount: 1,
          embedding: unitVector(0),
        ),
      ]);

      final offenders = <String>[];
      for (final entry in storedStringValues(store).entries) {
        for (final value in entry.value) {
          if (holdsChildCollection(entry.key.split('.').last, value)) {
            offenders.add('${entry.key} = ${_abbreviate(value)}');
          }
        }
      }

      expect(offenders, isEmpty,
          reason: 'a stored value that is a JSON array or a delimited run of '
              'identifiers is an embedded child collection (OR1): $offenders');
    });

    test('the detector flags the shapes OR1 forbids', () {
      // A guard that cannot fail is not a guard. Run the predicate over the
      // shapes it exists to catch, including ones with innocent names.
      expect(holdsChildCollection('chunkUuids', null), isTrue,
          reason: 'by name, even when empty');
      expect(holdsChildCollection('cardsJson', '["a","b"]'), isTrue);
      expect(holdsChildCollection('title', '["a","b"]'), isTrue,
          reason: 'by value — an innocent name does not launder a JSON array');
      expect(holdsChildCollection('notes', 'x,y'), isTrue, reason: 'by name');
      expect(
        holdsChildCollection(
            'cardRefs', '${newUuidV7()},${newUuidV7()}'),
        isTrue,
        reason: 'a delimited run of identifiers is a child list however it is spelt',
      );

      // And it must not fire on the columns the schema legitimately has.
      expect(holdsChildCollection('title', 'My title'), isFalse);
      expect(holdsChildCollection('markdown', '# Heading\n\nbody'), isFalse);
      expect(holdsChildCollection('content', 'chunk 0'), isFalse);
      expect(holdsChildCollection('uuid', newUuidV7()), isFalse);
      expect(holdsChildCollection('embeddingModelId', testModel), isFalse);
    });

    test('every entity carries a globally-unique identity', () {
      // OR1's other half: "its own identity". Two devices cannot merge a row
      // whose id is not globally unique, so a row without one is not an
      // independent record in the sense the rule means.
      //
      // A bookkeeping entity is exempt by design: it holds no user data and is
      // keyed by its own primary key.
      const bookkeeping = {'ObDeviceMeta', 'ObPeerWatermark'};

      final offenders = <String>[];
      for (final raw in model['entities'] as List) {
        final entity = raw as Map<String, dynamic>;
        final name = entity['name'] as String;
        if (bookkeeping.contains(name)) continue;

        final uniqueStrings = (entity['properties'] as List)
            .cast<Map<String, dynamic>>()
            .where((p) =>
                p['type'] == 9 && (((p['flags'] as int?) ?? 0) & 0x800) != 0)
            .map((p) => p['name'] as String)
            .toList();

        if (!uniqueStrings.contains('uuid')) {
          offenders.add('$name has no @Unique uuid (has: $uniqueStrings)');
        }
      }

      expect(offenders, isEmpty,
          reason: 'OR1 requires each child to have its own globally-unique '
              'identity: $offenders');
    });
  });

  group('OR1 — why it is an over rule', () {
    // The motivating failure, in this app's vocabulary: a peer re-indexes a
    // publication (five new chunks) while this device renames it. With children as
    // independent rows, both survive. With the chunks embedded in the
    // publication's row, the re-index would be "an edit to the publication", LWW
    // would pick a winner, and the loser's change would vanish — with no error, no
    // failing test, and nothing in the UI to show for it.
    late Device laptop;
    late Device phone;

    setUp(() {
      laptop = Device('or1-laptop', 'd-laptop');
      phone = Device('or1-phone', 'd-phone');
    });

    tearDown(() {
      laptop.dispose();
      phone.dispose();
    });

    test('a title edited here and chunks added there both survive', () async {
      final uuid = laptop.createPublication(
          title: 'Original', body: 'the body', chunkCount: 2);
      await laptop.pushTo(phone);

      // The peer re-indexes; the local device renames. Neither sees the other.
      laptop.reindex(uuid, 5);
      laptop.rename(uuid, 'My title');

      await converge(laptop, phone);

      expect(laptop.read(uuid).title, 'My title',
          reason: 'a local title edit is not collateral damage from a re-index');
      expect(phone.read(uuid).title, 'My title');
      expect(laptop.chunksOf(uuid), hasLength(5));
      expect(phone.chunksOf(uuid), hasLength(5),
          reason: 'and all five chunks arrived, each with its own identity');
      expect(
        phone.chunksOf(uuid).map((c) => c.uuid).toList()..sort(),
        [for (var i = 0; i < 5; i++) chunkUuidFor(uuid, i)]..sort(),
      );
    });

    test('a shrinking set does not lose the title', () async {
      final uuid = laptop.createPublication(
          title: 'Original', body: 'the body', chunkCount: 20);
      await laptop.pushTo(phone);

      laptop.reindex(uuid, 3);
      laptop.rename(uuid, 'My title');
      await converge(laptop, phone);

      expect(phone.read(uuid).title, 'My title');
      expect(phone.chunksOf(uuid), hasLength(3));
      expect(phone.read(uuid).chunkCount, 3);
    });

    test('chunks are independent rows with their own identity', () {
      final uuid = laptop.createPublication(
          title: 'X', body: 'body', chunkCount: 3);

      // Each chunk is its own row with a derived, globally-unique uuid — not a
      // field on the publication.
      final chunks = laptop.chunksOf(uuid);
      expect(chunks, hasLength(3));
      expect(
        chunks.map((c) => c.uuid),
        [for (var i = 0; i < 3; i++) chunkUuidFor(uuid, i)],
      );
      expect(laptop.store.box<ObPublication>().getAll(), hasLength(1));
    });
  });
}

/// One device, for the scenarios that need a real store and a real link.
class Device {
  Device(this.tag, this.deviceId, {String model = testModel})
      : store = openTestStore(tag) {
    library = ObjectBoxLibraryRepository(store);
    tombstones = TombstoneStore(store);
    applier = SyncApplier(
      store: store,
      activeEmbeddingModelId: model,
      deviceId: deviceId,
      tombstones: tombstones,
    );
    sender = PushSender(store: store, deviceId: deviceId, tombstones: tombstones);
  }

  final String tag;
  final String deviceId;
  final Store store;

  late final ObjectBoxLibraryRepository library;
  late final TombstoneStore tombstones;
  late final SyncApplier applier;
  late final PushSender sender;

  Future<void> pushTo(Device peer) => sender.push(
      peer.deviceId, (encoded) async => peer.applier.ingestEncoded(encoded));

  String createPublication({
    required String title,
    required String body,
    int chunkCount = 3,
  }) {
    final created = library.create(
        title: title, sourceMarkdown: body, embeddingModelId: testModel);
    library.replaceChunks(created.uuid, [
      for (var i = 0; i < chunkCount; i++)
        ChunkDraft(
          chunkIndex: i,
          content: '$title chunk $i',
          tokenCount: 4,
          embedding: unitVector(i),
        ),
    ]);
    return created.uuid;
  }

  /// Metadata version only — a rename must not touch the chunk-set version.
  void rename(String uuid, String title) {
    final box = store.box<ObPublication>();
    final row = box.query(ObPublication_.uuid.equals(uuid)).build().findFirst()!;
    row.title = title;
    row.versionCounter++;
    box.put(row);
  }

  void reindex(String uuid, int chunkCount) {
    library.replaceChunks(uuid, [
      for (var i = 0; i < chunkCount; i++)
        ChunkDraft(
          chunkIndex: i,
          content: 'reindexed chunk $i',
          tokenCount: 4,
          embedding: unitVector(40 + i),
        ),
    ]);
  }

  ObPublication read(String uuid) => store
      .box<ObPublication>()
      .query(ObPublication_.uuid.equals(uuid))
      .build()
      .findFirst()!;

  List<ObChunk> chunksOf(String uuid) {
    final publication = read(uuid);
    return store
        .box<ObChunk>()
        .query(ObChunk_.publicationId.equals(publication.id))
        .build()
        .find();
  }

  void dispose() => store.close();
}

/// Pushes in both directions until neither device has anything left to say.
Future<void> converge(Device a, Device b) async {
  for (var round = 0; round < 3; round++) {
    await a.pushTo(b);
    await b.pushTo(a);
    if (a.sender.selectDelta(b.deviceId).publications.isEmpty &&
        b.sender.selectDelta(a.deviceId).publications.isEmpty) {
      return;
    }
  }
}

/// Every string-typed column of every row, keyed `"Entity.property"`.
///
/// **Written out rather than reflected.** Dart has no runtime reflection in
/// Flutter, so there is no generic way to enumerate an entity's fields — and a
/// hand-written list is only safe if something checks it is complete. The
/// `every string column has a reader` test does exactly that, against the model
/// json, so a new string column fails until it is either read or argued for.
///
/// This is the same discipline as the seven reference sites, where a reflective
/// implementation would have passed its tests while a site was silently missed.
Map<String, List<String?>> storedStringValues(Store store) {
  final entries = <MapEntry<String, List<String?>>>[];

  entries.add(MapEntry('ObNotebook.uuid', [for (final n in _notebooks(store)) n.uuid]));
  entries.add(MapEntry('ObNotebook.title', [for (final n in _notebooks(store)) n.title]));

  entries.add(MapEntry('ObPublication.uuid',
      [for (final p in _publications(store)) p.uuid]));
  entries.add(MapEntry('ObPublication.title',
      [for (final p in _publications(store)) p.title]));
  entries.add(MapEntry('ObPublication.embeddingModelId',
      [for (final p in _publications(store)) p.embeddingModelId]));

  entries.add(MapEntry('ObDocument.uuid', [for (final d in _documents(store)) d.uuid]));
  entries
      .add(MapEntry('ObDocument.markdown', [for (final d in _documents(store)) d.markdown]));

  entries.add(MapEntry('ObChunk.uuid', [for (final c in _chunks(store)) c.uuid]));
  entries.add(MapEntry('ObChunk.content', [for (final c in _chunks(store)) c.content]));

  entries.add(MapEntry('ObTombstone.uuid',
      [for (final t in store.box<ObTombstone>().getAll()) t.uuid]));

  entries.add(MapEntry('ObDeviceMeta.value',
      [for (final m in store.box<ObDeviceMeta>().getAll()) m.value]));

  entries.add(MapEntry('ObPeerWatermark.peerDeviceId',
      [for (final w in store.box<ObPeerWatermark>().getAll()) w.peerDeviceId]));
  entries.add(MapEntry('ObPeerWatermark.recordUuid',
      [for (final w in store.box<ObPeerWatermark>().getAll()) w.recordUuid]));
  entries.add(MapEntry('ObPeerWatermark.recordKey',
      [for (final w in store.box<ObPeerWatermark>().getAll()) w.recordKey]));
  return Map.fromEntries(entries);
}

List<ObNotebook> _notebooks(Store store) => store.box<ObNotebook>().getAll();
List<ObPublication> _publications(Store store) =>
    store.box<ObPublication>().getAll();
List<ObDocument> _documents(Store store) => store.box<ObDocument>().getAll();
List<ObChunk> _chunks(Store store) => store.box<ObChunk>().getAll();

String _abbreviate(String? value) {
  if (value == null) return 'null';
  return value.length <= 40 ? value : '${value.substring(0, 37)}...';
}
