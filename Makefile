.PHONY: analyze test run_desktop

analyze:
	flutter analyze

test:
	flutter test

run_desktop:
	flutter run -d macos