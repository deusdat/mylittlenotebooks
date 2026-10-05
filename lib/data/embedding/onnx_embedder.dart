import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mylittlenotebooks/data/embedding/embedder.dart';
import 'package:mylittlenotebooks/data/embedding/text_chunker.dart';
import 'package:mylittlenotebooks/data/embedding_validation.dart';
import 'package:onnxruntime/onnxruntime.dart';

/// The ONNX-backed [Embedder] (spec FR8).
///
/// Pipeline, in order: prefix → tokenize → infer → masked mean-pool →
/// Matryoshka-truncate to 256 → L2-normalise → release tensors. The session is
/// supplied already loaded and is opened once by the caller.
///
/// Inference runs through `OrtSession.runAsync`, which the package implements on
/// a background isolate, so the UI isolate never blocks (spec NFR7). The model
/// is loaded once per session; there is no per-call reload.
class OnnxEmbedder implements Embedder {
  OnnxEmbedder({
    required this.session,
    required this.tokenizer,
    required this.modelId,
    this.nativeDimensions = 768,
  });

  /// The mandatory nomic task prefixes, applied here and never by the caller
  /// (spec FR7, D18).
  static const String documentPrefix = 'search_document: ';
  static const String queryPrefix = 'search_query: ';

  final OrtSession session;
  final Tokenizer tokenizer;

  @override
  final String modelId;

  /// The model's native embedding width, before MRL truncation.
  final int nativeDimensions;

  @override
  Future<List<List<double>>> embedDocuments(List<String> texts) async =>
      [for (final text in texts) await _embed(documentPrefix + text)];

  @override
  Future<List<double>> embedQuery(String text) =>
      _embed(queryPrefix + text);

  Future<List<double>> _embed(String prefixed) async {
    final encoded = tokenizer.encode(prefixed);
    final shape = [1, encoded.inputIds.length];

    final ids = OrtValueTensor.createTensorWithDataList(
      Int64List.fromList(encoded.inputIds),
      shape,
    );
    final mask = OrtValueTensor.createTensorWithDataList(
      Int64List.fromList(encoded.attentionMask),
      shape,
    );
    // BERT requires `token_type_ids`; for a single sequence it is all zeros.
    final types = OrtValueTensor.createTensorWithDataList(
      Int64List(encoded.inputIds.length),
      shape,
    );

    try {
      final inputs = <String, OrtValue>{
        'input_ids': ids,
        'attention_mask': mask,
        'token_type_ids': types,
      };

      final future = session.runAsync(OrtRunOptions(), inputs);
      final outputs = await (future ?? Future.value(<OrtValue?>[]));
      try {
        final raw = _tokenVectors(outputs);
        final pooled = meanPool(raw, encoded.attentionMask);
        final truncated =
            truncateToDimensions(pooled, VectorGeometry.dimensions);
        final normalized = l2Normalize(truncated);
        // Defence in depth: the same rule the store boundary enforces.
        validateEmbedding(normalized);
        return normalized;
      } finally {
        for (final output in outputs) {
          output?.release();
        }
      }
    } finally {
      ids.release();
      mask.release();
      types.release();
    }
  }

  /// The first output as `seq × native` token vectors (batch dimension 1).
  List<List<double>> _tokenVectors(List<OrtValue?> outputs) {
    final tensor = outputs.isNotEmpty ? outputs.first : null;
    if (tensor is! OrtValueTensor) {
      throw StateError('OnnxEmbedder: expected a tensor output');
    }
    final value = tensor.value;
    if (value is! List || value.isEmpty) {
      throw StateError('OnnxEmbedder: empty output');
    }
    final sequence = value.first;
    if (sequence is! List) {
      throw StateError('OnnxEmbedder: unexpected output rank');
    }
    return [
      for (final row in sequence)
        [for (final v in (row as List)) (v as num).toDouble()],
    ];
  }

  /// Releases the session. The environment is owned by whoever initialised it.
  void dispose() => session.release();
}

/// Mean-pools [tokenEmbeddings] across the sequence, weighting by [mask] so
/// padding does not contribute (spec FR8 step 4).
List<double> meanPool(List<List<double>> tokenEmbeddings, List<int> mask) {
  if (tokenEmbeddings.isEmpty) return const [];
  final dim = tokenEmbeddings.first.length;
  final result = List<double>.filled(dim, 0.0);
  var count = 0;

  for (var i = 0; i < tokenEmbeddings.length; i++) {
    if (i < mask.length && mask[i] == 0) continue;
    count++;
    final row = tokenEmbeddings[i];
    for (var j = 0; j < dim; j++) {
      result[j] += row[j];
    }
  }

  if (count > 0) {
    for (var j = 0; j < dim; j++) {
      result[j] /= count;
    }
  }
  return result;
}

/// Matryoshka-truncates [vector] to its first [dimensions] components
/// (spec FR8 step 5).
List<double> truncateToDimensions(List<double> vector, int dimensions) =>
    vector.length <= dimensions ? vector : vector.sublist(0, dimensions);

/// L2-normalises [vector] (spec FR8 step 6). A zero vector is returned as-is so
/// it does not become NaN.
List<double> l2Normalize(List<double> vector) {
  var sumOfSquares = 0.0;
  for (final v in vector) {
    sumOfSquares += v * v;
  }
  final norm = math.sqrt(sumOfSquares);
  if (norm == 0) return vector;
  return [for (final v in vector) v / norm];
}
