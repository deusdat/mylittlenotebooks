import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// Resolves the bundled ONNX model and tokenizer to filesystem paths
/// (spec FR8a, plan §J).
///
/// Flutter bundles assets read-only, but the ONNX runtime needs a file path, so
/// each asset is **copied once** into the application-support directory and the
/// path is handed to the runtime. A file's own existence is the marker, so a
/// restart does not re-copy.
///
/// The `.onnx` is a **build artifact**, fetched by `make install_model` (spec
/// D38) — it is too large to track and reproducible from a pinned revision.
/// `tokenizer.json` is small and committed.
abstract final class ModelAssets {
  static const String modelAsset =
      'assets/models/nomic_embed_text_v1.5_quantized.onnx';
  static const String tokenizerAsset = 'assets/tokenizers/tokenizer.json';

  static const String modelModelId = 'nomic-embed-text-v1.5:onnx:int8:256';

  /// Copies [assetKey] to the support directory (once) and returns the file.
  ///
  /// Throws if the asset is not bundled — callers treat that as "the native
  /// stack is not available" and fall back.
  static Future<File> copyOnce(String assetKey, String fileName) async {
    final dir = await getApplicationSupportDirectory();
    final target = File('${dir.path}/mln_models/$fileName');
    if (await target.exists()) return target;

    final data = await rootBundle.load(assetKey);
    await target.parent.create(recursive: true);

    // Write to a temp path and rename it into place. `rename` is atomic on one
    // filesystem, so an interrupted extraction can never leave a **truncated**
    // file at [target] — which the `exists()` check above would otherwise accept
    // forever, permanently breaking the real embedder.
    final temp = File('${target.path}.part');
    if (await temp.exists()) await temp.delete();
    await temp.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    return temp.rename(target.path);
  }

  static Future<File> modelFile() =>
      copyOnce(modelAsset, 'nomic_embed_text_v1.5_quantized.onnx');

  static Future<File> tokenizerFile() =>
      copyOnce(tokenizerAsset, 'tokenizer.json');
}
