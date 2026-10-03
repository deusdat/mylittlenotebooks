import 'package:objectbox/objectbox.dart';

/// How much of one record one peer has acknowledged (FR11).
///
/// **Per record and per axis, not one scalar per peer.** This shape is not
/// incidental — a scalar watermark is *lossy*, and the loss is silent.
///
/// The problem: `versionCounter` and `chunkSetVersion` are independent counters
/// on the same publication, and a scalar has to be compared against both. Take a
/// freshly imported publication, which ends up with `versionCounter == 2` and
/// `chunkSetVersion == 1`. Push it; the watermark becomes 2. Now re-index it: the
/// set version moves 1 → 2, and `2 > 2` is false, so **the re-index is never
/// selected again**. That is not an exotic interleaving — it is what happens to
/// every single re-index after the first push, and nothing throws.
///
/// Two repairs were considered and both were rejected:
///
/// * **A device-level clock** for version counters. Sound, but it reintroduces
///   exactly what `nextVersion`'s per-record counters exist to prevent: a device
///   that imports ten thousand publications once would outrank a quiet device on
///   every record forever, discarding the quiet device's genuinely later edits.
/// * **Comparing with `>=`.** Sound for loss, fatal for the delta: in a corpus
///   imported in one batch every record shares the same counter, so the
///   highest-versioned record would be re-sent on every push, forever.
///
/// Per-record counters cost one row per record per peer and are exact: a
/// comparison is only ever between two numbers this device produced.
///
/// **Only counters are stored.** The `deviceId` half of each version is
/// reconstructed from this install, exactly as it is for stored records (plan I2).
@Entity()
class ObPeerWatermark {
  @Id()
  int id = 0;

  /// `(peerDeviceId, recordUuid)` as one key, and the row's uniqueness.
  ///
  /// **A composite key column rather than two `@Unique()` properties**, because
  /// ObjectBox Dart treats two of those as two *independent* unique constraints —
  /// so every peer would be limited to one row. Measured, not assumed: the first
  /// codegen produced exactly that and the second peer's watermark failed with a
  /// unique-constraint violation.
  ///
  /// Uniqueness has to be structural here. A duplicate row would not throw
  /// anywhere; it would make the same record appear twice in every subsequent
  /// delta selection.
  @Unique()
  String recordKey;

  /// The peer's `deviceId`. Travels in payloads; means nothing outside this
  /// library. Indexed rather than unique so a peer's rows can be swept in one
  /// query.
  @Index()
  String peerDeviceId;

  /// The record this row is about — a publication uuid, or the uuid of something
  /// that has since been deleted.
  @Index()
  String recordUuid;

  /// Highest `versionCounter` sent for this record's metadata and edges.
  int metadataCounter;

  /// Highest `chunkSetVersion` sent for this record's chunk set.
  int chunkSetCounter;

  /// Highest document-text version sent.
  ///
  /// Separate because the source text is its own row with its own edits: a
  /// re-import can replace the text without touching the title.
  int documentCounter;

  /// Builds the composite key. One place, so no two call sites can disagree
  /// about the separator.
  ///
  /// **`|` and not a control character.** A `\u0000` separator looks tidier and is
  /// measurably broken: ObjectBox compares string conditions in C, where NUL
  /// terminates, so a key built with one is compared as its first segment and the
  /// lookup silently matches nothing. Every device id is `d-<base36>…` and every
  /// identifier is hex and dashes, so `|` cannot occur in either half.
  static String keyFor(String peerDeviceId, String recordUuid) =>
      '$peerDeviceId|$recordUuid';

  ObPeerWatermark({
    required this.peerDeviceId,
    required this.recordUuid,
    this.metadataCounter = 0,
    this.chunkSetCounter = 0,
    this.documentCounter = 0,
  }) : recordKey = keyFor(peerDeviceId, recordUuid);

  /// The axes a delete uses. A deleted record has one version, and reusing the
  /// metadata column keeps a single key shape rather than a second table for one
  /// counter.
  static const int deleteAxis = 0;
}
