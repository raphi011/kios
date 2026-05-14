.PHONY: test test-core test-ios build-ios archive xcodegen clean

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

test: test-core test-ios

test-core:
	$(CORE_TEST)

test-ios: xcodegen
	$(IOS_TEST)

build-ios: xcodegen
	$(IOS_BUILD)

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
