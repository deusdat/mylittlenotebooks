.PHONY: analyze test run_desktop codegen install_objectbox install_model setup

analyze:
	flutter analyze

test:
	flutter test

run_desktop:
	flutter run -d macos

# Regenerates lib/objectbox.g.dart and lib/objectbox-model.json.
# Both are committed (spec NFR3); run this after changing any Ob* entity.
codegen:
	dart run build_runner build

# Required once per machine checkout before `flutter test` can load an
# ObjectBox store. `objectbox_flutter_libs` covers apps, not the Dart VM
# running tests, so without this every test fails at load (spec plan R2).
#
# install.sh is fetched from the tag matching the pinned objectbox version, NOT
# from main. The script on main hardcodes cLibVersion=6.0.0-beta, which pairs a
# newer C library with our 5.3.2 Dart bindings. The script's own header warns
# that a mismatch "won't error on C function signature mismatch, leading to
# obscure memory bugs" — it fails silently, if at all. The version is read from
# pubspec.yaml so this cannot drift.
install_objectbox:
	@version=$$(grep -E '^\s+objectbox:' pubspec.yaml | head -1 \
		| sed -E 's/.*\^?([0-9]+\.[0-9]+\.[0-9]+).*/\1/'); \
	echo "Installing ObjectBox native library $$version"; \
	curl -sL https://raw.githubusercontent.com/objectbox/objectbox-dart/v$$version/install.sh -o install.sh; \
	bash install.sh

# The embedding model is a BUILD ARTIFACT, not source: ~131 MB and reproducible
# from a pinned Hugging Face revision. Fetch it once per checkout before
# building or running the app. `tokenizer.json` is small and committed.
#
# Pinned to a revision + SHA-256 so the fetched bytes are exactly what was
# validated. If the file is present and matches, this is a no-op.
NOMIC_REV = e9b6763023c676ca8431644204f50c2b100d9aab
NOMIC_MODEL_SHA256 = b4342336debaea79de872370664b0aaeb67dea4605513d00ee236ea871a81f27
NOMIC_MODEL = assets/models/nomic_embed_text_v1.5_quantized.onnx

install_model:
	@if [ -f "$(NOMIC_MODEL)" ] && \
		echo "$(NOMIC_MODEL_SHA256)  $(NOMIC_MODEL)" | shasum -a 256 -c - >/dev/null 2>&1; then \
		echo "Model present and verified: $(NOMIC_MODEL)"; exit 0; \
	fi; \
	mkdir -p assets/models; \
	echo "Fetching nomic-embed-text-v1.5 ONNX @ $(NOMIC_REV)"; \
	curl -sL "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5/resolve/$(NOMIC_REV)/onnx/model_quantized.onnx" -o "$(NOMIC_MODEL)"; \
	echo "$(NOMIC_MODEL_SHA256)  $(NOMIC_MODEL)" | shasum -a 256 -c -

# Everything a fresh checkout needs before building or testing.
setup: install_objectbox install_model
