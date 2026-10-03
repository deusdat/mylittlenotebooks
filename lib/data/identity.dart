import 'package:uuid/data.dart';
import 'package:uuid/uuid.dart';

/// Identity generation and validation — the seam between this app and
/// `package:uuid`.
///
/// Three one-line functions, deliberately behind a seam. It keeps
/// `package:uuid` out of the repositories, gives one place to record *why* v7,
/// and gives tests an injection point for a fixed timestamp.
///
/// **Why v7 and not v4.** v7 carries a 48-bit millisecond timestamp in its high
/// bits, so identifiers sort by creation time across devices. That matters for a
/// payload a human may read while debugging a peer disagreement.
///
/// **Ordering caveat.** v7 orders by time at *millisecond* granularity only —
/// two identifiers minted inside the same millisecond order by their random
/// bits, not by creation. Nothing in this app orders by identifier: every
/// ordering comes from an explicit `createdAt` or version column. Recorded here
/// so nobody later "fixes" it by sorting on a uuid.
///
/// **Why not hand-rolled.** Version nibble, variant bits, and byte ordering must
/// be exactly right, and a mistake yields identifiers that look plausible and
/// violate the spec — a poor trade in the component holding a user's private
/// documents. The library also provides the parse/validate half, which the
/// receive side needs and which would otherwise be a parser we wrote ourselves.
const Uuid _uuid = Uuid();

/// A fresh RFC 9562 v7 identifier.
String newUuidV7() => _uuid.v7();

/// Deterministic chunk identity.
///
/// Globally unique *because* the publication uuid is, so no hashing and no
/// coordination between devices are required: both sides compute the same value
/// from the same `(publicationUuid, chunkIndex)` independently.
///
/// Derivation is what makes re-applying a whole chunk set idempotent — which
/// matters because ingest replaces chunk sets wholesale rather than merging
/// them. Two devices whose chunkers disagree about where chunk 7 ends still
/// agree on chunk 7's identity, so last-write-wins resolves the content
/// instead of producing two competing chunks.
///
/// Kept as a composed string rather than a UUIDv5 so it stays **inspectable**:
/// a malformed uuid read out of a payload log should be legible.
String chunkUuidFor(String publicationUuid, int chunkIndex) =>
    'c-$publicationUuid-$chunkIndex';

/// Deterministic document identity.
///
/// A publication has at most one document, so this is derived from the
/// publication uuid alone. Symmetric with [chunkUuidFor]: no coordination, and
/// re-importing the same publication reuses the same document identity instead
/// of forking a second one.
String documentUuidFor(String publicationUuid) => 'd-$publicationUuid';

/// Whether [value] is a well-formed 128-bit uuid.
///
/// The **strict RFC 4122/9562** check. This applies to the uuids that are
/// genuinely RFC-shaped: notebooks and publications.
///
/// It deliberately does **not** accept the derived forms below, because a
/// composed identifier is not a uuid by that definition. Use
/// [isValidIdentifier] when validating anything arriving from a peer — a
/// payload legitimately carries chunk and document ids that this rejects.
bool isValidUuid(String value) => Uuid.isValidUUIDFormat(fromString: value);

/// A derived chunk index. Captured so the scheme is stated once.
final _chunkIdPattern = RegExp(r'^c-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-'
    r'[0-9a-f]{4}-[0-9a-f]{12}-\d+$');

final _documentIdPattern =
    RegExp(r'^d-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// Whether [value] is a well-formed identifier **in this app's scheme**.
///
/// Three forms exist, and every one of them legitimately crosses the wire:
///
/// | Form | Produced by | Used for |
/// |---|---|---|
/// | RFC 4122/9562 uuid | [newUuidV7] | notebooks, publications |
/// | `c-<publicationUuid>-<chunkIndex>` | [chunkUuidFor] | chunks |
/// | `d-<publicationUuid>` | [documentUuidFor] | documents |
///
/// **This is the receive-side guard.** An identifier arriving from a peer must
/// be validated before it is stored or turned into a lookup — a malformed one
/// would otherwise become a row nothing can find.
///
/// Checking RFC 4122 alone would reject this app's own chunks and documents,
/// which is why the scheme is validated here rather than by delegating to
/// [isValidUuid].
bool isValidIdentifier(String value) =>
    isValidUuid(value) ||
    _chunkIdPattern.hasMatch(value) ||
    _documentIdPattern.hasMatch(value);

/// The publication uuid embedded in a derived chunk or document identifier.
///
/// Returns null when [value] is not a derived form — which is also how callers
/// tell a derived identifier apart from a plain uuid.
String? parentPublicationUuidOf(String identifier) {
  final chunk = _chunkIdPattern.firstMatch(identifier);
  if (chunk != null) {
    // Strip the `c-` prefix and the trailing `-<index>`.
    return identifier.substring(2, identifier.lastIndexOf('-'));
  }
  if (_documentIdPattern.hasMatch(identifier)) {
    return identifier.substring(2);
  }
  return null;
}

/// Exposed for tests that need an identifier at a fixed instant.
///
/// v7's low bits are random, so asserting time-ordering by generating uuids and
/// sorting them is flaky at millisecond granularity. Injecting the timestamp
/// makes it deterministic.
String uuidV7At(DateTime instant) =>
    _uuid.v7(config: V7Options(instant.toUtc().millisecondsSinceEpoch, null));
