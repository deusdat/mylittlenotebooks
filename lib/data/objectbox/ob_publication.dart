import 'package:objectbox/objectbox.dart';

import 'package:mylittlenotebooks/data/objectbox/ob_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_document.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_notebook.dart';

/// Storage entity for an imported source document (spec FR2).
///
/// There is deliberately **no** `filePath`. On iOS a picked file's path is not
/// durably readable, and on Android a content URI's permission grant does not
/// survive a relaunch (spec FR3). The database is the record of truth:
/// [sourceMarkdown] is complete, so re-chunking, preview, and citation all work
/// with no file access at all (spec FR4).
@Entity()
class ObPublication {
  @Id()
  int id = 0;

  /// `@Unique` rather than `@Index` — see the note on `ObNotebook.uuid`.
  @Unique()
  String uuid;

  String title;

  /// Byte length of the document text, **not** a file on disk (spec D8).
  ///
  /// The text itself lives in [ObDocument] rather than here. ObjectBox loads
  /// whole objects, so keeping a multi-hundred-kilobyte document on this row
  /// would mean every publication *list* read every document — which spec NFR6
  /// forbids and which no amount of query tuning avoids (spec correction 3).
  int byteSize;

  @Property(type: PropertyType.dateUtc)
  DateTime importedAt;

  /// Names the model *and configuration* that produced this publication's
  /// vectors (e.g. `nomic-embed-text-v1.5:int8:256`).
  ///
  /// Two vectors are only comparable if these match. Swapping embedding models
  /// without noticing silently mixes vector spaces and returns confident
  /// nonsense, and nothing in the data would reveal it — so the mismatch is
  /// prevented structurally rather than by convention (spec FR6).
  String embeddingModelId;

  /// Denormalised count, written only by the transactional chunk write
  /// (spec FR9, plan R8). Exists so a publication list renders without loading
  /// every chunk.
  int chunkCount;

  /// Half of this record's last-write-wins version: the edit counter (FR9,
  /// FR10). The other half, `deviceId`, lives once on the store rather than on
  /// every row — see [SyncApplier] for why that reconstruction is sound under
  /// this protocol's topology, and what it would cost to stop relying on it.
  ///
  /// Covers the metadata **and** the notebook association edges, because the
  /// edges travel in the metadata record and plan §G bumps this version for an
  /// attach. [chunkSetVersion] is the separate counter for the chunk set.
  @Index()
  int versionCounter;

  /// Version of the chunk set, tracked **independently** of the publication's own
  /// sync version (peer-sync FR5a).
  ///
  /// Without the split, retitling a publication would drag its entire chunk set
  /// across to a peer: renaming something would cost a full corpus transfer.
  /// Only a re-index — an import, a chunker change, or a model change — advances
  /// this and sends the set.
  int chunkSetVersion;

  /// The many-to-many edge back to notebooks (spec FR2).
  ///
  /// `[notebooks]` names the `ToMany` on [ObNotebook] that this reverses.
  @Backlink('publications')
  final notebooks = ToMany<ObNotebook>();

  /// The chunk set, reversed from [ObChunk.publication].
  ///
  /// **The `@Backlink` is load-bearing, and its absence was silent.** Without it
  /// ObjectBox has no way to pair this `ToMany` with [ObChunk.publication] —
  /// a `ToMany` is resolved through the *other* side's `ToOne` target id, and
  /// the two relation names have to agree. They do not (`chunks` against
  /// `publication`), so the collection resolved to empty and nothing threw:
  /// `replaceChunks` wrote the chunks, `chunkCount` said 3, and
  /// `publication.chunks` said none existed.
  ///
  /// This is peer-sync reference site 7. With the backlink it is maintained by
  /// [ObChunk.publication] alone, so it cannot drift from the chunk rows the way
  /// the denormalised `publicationId` column could.
  @Backlink('publication')
  final chunks = ToMany<ObChunk>();

  final document = ToOne<ObDocument>();

  ObPublication({
    required this.uuid,
    required this.title,
    required this.byteSize,
    required this.importedAt,
    required this.embeddingModelId,
    this.chunkCount = 0,
    this.chunkSetVersion = 0,
    this.versionCounter = 0,
  });
}
