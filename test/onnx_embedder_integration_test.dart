import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/embedding/model_assets.dart';
import 'package:mylittlenotebooks/data/embedding/onnx_embedder.dart';
import 'package:mylittlenotebooks/data/embedding/wordpiece_tokenizer.dart';
import 'package:onnxruntime/onnxruntime.dart';

/// End-to-end ONNX inference against the bundled model (spec FR8).
///
/// Skipped where the host Dart VM cannot load the native runtime — the app
/// itself always can, because the plugin ships its libraries into the bundle.
void main() {
  test('embeds a query to a 256-dim unit vector', () async {
    final model = File(ModelAssets.modelAsset);
    final tokenizerJson = File(ModelAssets.tokenizerAsset);
    if (!model.existsSync() || !tokenizerJson.existsSync()) {
      markTestSkipped('model/tokenizer asset not present (make install_model)');
      return;
    }

    OrtSession? session;
    try {
      // Fails (and skips) here on the host VM, which has no native runtime.
      OrtEnv.instance.init();

      final options = OrtSessionOptions();
      session = OrtSession.fromFile(model, options);
      options.release();

      final tokenizer = WordPieceTokenizer.fromJson(
        jsonDecode(tokenizerJson.readAsStringSync()) as Map<String, dynamic>,
      );
      final embedder = OnnxEmbedder(
        session: session,
        tokenizer: tokenizer,
        modelId: ModelAssets.modelModelId,
      );

      final vector = await embedder.embedQuery('a feline rests on a rug');
      expect(vector.length, 256);
      final norm =
          sqrt(vector.fold<double>(0, (a, b) => a + b * b));
      expect(norm, closeTo(1.0, 1e-3));
      expect(vector.every((v) => v.isFinite), isTrue);
    } catch (error) {
      // The native library is not on the host test's library path.
      markTestSkipped('host onnxruntime unavailable: $error');
    } finally {
      session?.release();
    }
  });
}
