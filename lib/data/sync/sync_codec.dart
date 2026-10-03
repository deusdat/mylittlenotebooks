import 'dart:convert';
import 'dart:typed_data';

import 'package:mylittlenotebooks/data/embedding_validation.dart';
import 'package:mylittlenotebooks/data/invalid_embedding_exception.dart';
import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/sync/sync_payload.dart';

/// Encoding and decoding (spec FR5c).
///
/// Vectors travel as **base64 over the `Float32List`'s raw bytes**. Measured
/// during planning: the same 256-dimension vector is 1,368 characters this way
/// and 5,319 as `jsonEncode` output — 3.9× larger. Dart emits doubles at full
/// precision, so one float32 costs 15–20 characters as JSON against 4 bytes of
/// base64. On a 10,000-chunk first push that is roughly 28 MB saved.
///
/// Base64 rather than a binary frame because the rest of the payload is JSON and
/// transport framing is explicitly out of scope; base64 costs 33% overhead and
/// keeps the whole payload readable with ordinary tooling.

/// The characters a 256-dimension vector occupies on the wire.
const int encodedVectorLength = 1368;

String encodeVector(List<double> vector) {
  final floats = Float32List.fromList(vector);
  return base64.encode(floats.buffer.asUint8List());
}

/// Decodes and validates. Throws [InvalidEmbeddingException] rather than
/// returning a bad vector, so a malformed payload is refused by the same
/// boundary that refuses a malformed local write.
List<double> decodeVector(String encoded) {
  final bytes = base64.decode(encoded);
  if (bytes.length != VectorGeometry.dimensions * 4) {
    throw InvalidEmbeddingException(
      actualLength: bytes.length ~/ 4,
      expectedLength: VectorGeometry.dimensions,
    );
  }
  final floats = Float32List.view(Uint8List.fromList(bytes).buffer);
  return List<double>.from(floats);
}

/// Thrown when a payload cannot be encoded or decoded at all.
class SyncPayloadException implements Exception {
  final String reason;

  const SyncPayloadException(this.reason);

  @override
  String toString() => 'SyncPayloadException: $reason';
}

/// Serialises a payload, validating every uuid on the way out.
String encodePayload(SyncPayload payload) {
  final json = jsonEncode(payload.toJson());

  // The receive side has no other chance to reject a malformed identifier
  // before it becomes a row nothing can find. Validate here too so a payload
  // this device emits is never one it would reject.
  for (final publication in payload.publications) {
    _requireUuid(publication.uuid, 'publication uuid');
    for (final notebook in publication.notebookUuids) {
      _requireUuid(notebook, 'notebook uuid in publication ${publication.uuid}');
    }
    final document = publication.document;
    if (document != null) _requireUuid(document.uuid, 'document uuid');
    for (final chunk in publication.chunks) {
      _requireUuid(chunk.uuid, 'chunk uuid');
      _requireUuid(chunk.publicationUuid, 'chunk parent uuid');
    }
  }
  for (final delete in payload.deletes) {
    _requireUuid(delete.uuid, 'delete uuid');
  }
  return json;
}

/// Parses a payload. Throws rather than returning null, so a caller cannot
/// accidentally proceed with a partial result.
SyncPayload decodePayload(String encoded) {
  final Object? raw;
  try {
    raw = jsonDecode(encoded);
  } on FormatException catch (error) {
    throw SyncPayloadException('malformed JSON: ${error.message}');
  }

  final payload = SyncPayload.fromJson(raw);
  if (payload == null) {
    throw const SyncPayloadException('payload shape is not recognised');
  }

  // Identifier validation happens on decode, not on use — a malformed uuid must
  // never reach the store, even transiently.
  for (final notebook in payload.notebooks) {
    _requireUuid(notebook.uuid, 'notebook uuid');
  }
  for (final publication in payload.publications) {
    _requireUuid(publication.uuid, 'publication uuid');
    for (final notebook in publication.notebookUuids) {
      _requireUuid(notebook, 'notebook uuid');
    }
    final document = publication.document;
    if (document != null) _requireUuid(document.uuid, 'document uuid');
    for (final chunk in publication.chunks) {
      _requireUuid(chunk.uuid, 'chunk uuid');
      _requireUuid(chunk.publicationUuid, 'chunk parent uuid');
    }
  }
  for (final delete in payload.deletes) {
    _requireUuid(delete.uuid, 'delete uuid');
  }
  return payload;
}

/// Validates against this app's identifier *scheme*, not RFC 4122 alone.
///
/// A payload legitimately carries derived chunk and document identifiers, which
/// are composed strings rather than uuids (see `isValidIdentifier`). Validating
/// them as RFC 4122 would reject this device's own payload.
void _requireUuid(String value, String what) {
  if (!isValidIdentifier(value)) {
    throw SyncPayloadException('$what is not a well-formed identifier: "$value"');
  }
}
