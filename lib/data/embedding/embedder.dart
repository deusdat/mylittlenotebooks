import 'dart:math' as math;

/// The two sides of a retrieval embedder (spec FR7).
///
/// The task prefix (`search_document:` / `search_query:`) is applied **inside**
/// the implementation, never by the caller, because forgetting it degrades
/// quality silently.
abstract interface class Embedder {
  /// The model *and configuration* that produced every vector (spec FR8),
  /// e.g. `nomic-embed-text-v1.5:onnx:int8:256`.
  String get modelId;

  /// Ingestion side. One vector per input, in order. Each is exactly 256 finite
  /// values, L2-normalised.
  Future<List<List<double>>> embedDocuments(List<String> texts);

  /// Retrieval side. Unused by this feature's UI, used by the note search path.
  Future<List<double>> embedQuery(String text);
}

/// A deterministic [Embedder] for tests and the pre-M6 default (spec FR6, FR7).
///
/// Records the exact strings it received — **prefixed** — so a test can assert
/// the mandatory task prefixes (AC30). The vector is derived from the prefixed
/// text, so equal input yields equal output and it is L2-normalised (AC31).
class DeterministicEmbedder implements Embedder {
  DeterministicEmbedder({this.modelId = 'deterministic:int8:256'});

  @override
  final String modelId;

  /// Every prefixed string passed to [embedDocuments] or [embedQuery], in order.
  final List<String> received = [];

  @override
  Future<List<List<double>>> embedDocuments(List<String> texts) async =>
      [for (final text in texts) _vector('search_document: $text')];

  @override
  Future<List<double>> embedQuery(String text) async =>
      _vector('search_query: $text');

  List<double> _vector(String prefixed) {
    received.add(prefixed);
    final random = math.Random(prefixed.hashCode);
    final values = List<double>.generate(256, (_) => random.nextDouble() - 0.5);
    final norm = math.sqrt(values.fold<double>(0, (a, b) => a + b * b));
    return [for (final v in values) v / norm];
  }
}
