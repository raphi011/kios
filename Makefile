.PHONY: test test-core test-ios build-ios archive xcodegen clean sync-i18n check-i18n

# `swift test` defaults to parallel execution, which races against the static
# `MockURLProtocol.handler` shared by HTTPClient and KOSyncClient suites.
# Each suite is `.serialized` internally, but Swift Testing parallelizes
# across suites. Until MockURLProtocol is rewritten with closure-scoped
# locking, run Core tests sequentially. iOS tests are unaffected because
# xcodebuild doesn't share that static state across processes.

CORE_TEST  := cd Core && swift test --no-parallel
SWIFT_BUILD := cd Core && swift build -Xswiftc -warnings-as-errors
IOS_DEST   := platform=iOS Simulator,name=iPhone 17 Pro
# `-skipMacroValidation` accepts the Swift macros vendored by mlx-swift-lm
# (`MLXHuggingFaceMacros`) without an interactive trust prompt. Required for
# headless builds; Xcode itself prompts the developer on first open.
IOS_TEST   := xcodebuild test -project Kios.xcodeproj -scheme Kios -destination '$(IOS_DEST)' -skipMacroValidation
IOS_BUILD  := xcodebuild build -project Kios.xcodeproj -scheme Kios -destination '$(IOS_DEST)' -skipMacroValidation

test: test-core test-ios check-i18n

test-core:
	$(CORE_TEST)

test-ios: xcodegen
	$(IOS_TEST)

build-ios: xcodegen
	$(IOS_BUILD)

# Re-extract translatable strings from the latest build's .stringsdata and merge
# them into the source catalogs. Run this after adding/changing user-facing
# strings in code, then commit the catalog updates.
sync-i18n: build-ios
	@DD=$$(ls -dt ~/Library/Developer/Xcode/DerivedData/Kios-*/ 2>/dev/null | head -1); \
	if [ -z "$$DD" ]; then \
		echo "✗ no DerivedData found for Kios — build first"; \
		exit 1; \
	fi; \
	STRINGSDATA=$$(find "$$DD/Build/Intermediates.noindex" -name "*.stringsdata" 2>/dev/null); \
	if [ -z "$$STRINGSDATA" ]; then \
		echo "✗ no .stringsdata found — run a clean build first"; \
		exit 1; \
	fi; \
	xcrun xcstringstool sync Kios/Resources/Localizable.xcstrings --stringsdata $$STRINGSDATA; \
	xcrun xcstringstool sync KiosControls/Localizable.xcstrings --stringsdata $$STRINGSDATA; \
	echo "✓ catalogs synced — review with: git diff -- '*.xcstrings'"

# Fail if any catalog has untranslated or stale entries for the required locales.
# Does NOT build or sync; assumes catalogs are up to date with the source code
# (run `make sync-i18n` after changing strings).
check-i18n:
	./scripts/check-xcstrings-translations.sh

# Archive for distribution (TestFlight). Bypasses the Xcode UI macro-trust
# prompt that otherwise blocks `MLXHuggingFaceMacros` from compiling.
# Output: build/Kios.xcarchive.
archive: xcodegen
	xcodebuild archive \
		-project Kios.xcodeproj \
		-scheme Kios \
		-configuration Release \
		-destination 'generic/platform=iOS' \
		-archivePath build/Kios.xcarchive \
		-skipMacroValidation

xcodegen:
	xcodegen generate

clean:
	swift package --package-path Core clean
	rm -rf ~/Library/Developer/Xcode/DerivedData/Kios-*
