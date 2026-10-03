.PHONY: analyze test run_desktop codegen install_objectbox

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
