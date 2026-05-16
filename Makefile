.PHONY: test test-core test-ios build-ios archive testflight xcodegen clean

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
# `-allowProvisioningUpdates` lets xcodebuild mint/refresh the distribution
# profile from App Store Connect when needed (uses the API key already
# registered in Xcode → Settings → Accounts).
# Output: build/Kios.xcarchive.
archive: xcodegen
	xcodebuild archive \
		-project Kios.xcodeproj \
		-scheme Kios \
		-configuration Release \
		-destination 'generic/platform=iOS' \
		-archivePath build/Kios.xcarchive \
		-allowProvisioningUpdates \
		-skipMacroValidation

# Archive + upload to TestFlight. `ExportOptions.plist` sets
# `destination: upload`, so the export step posts the IPA to App Store
# Connect directly — no separate altool/Transporter call. Credentials
# come from Xcode's Keychain (Apple ID + registered API key), so no
# explicit auth flags are needed on this machine.
#
# Remember to bump `CURRENT_PROJECT_VERSION` in project.yml before
# running — App Store Connect rejects duplicate version+build pairs.
testflight: archive
	xcodebuild -exportArchive \
		-archivePath build/Kios.xcarchive \
		-exportOptionsPlist ExportOptions.plist \
		-exportPath build/ipa \
		-allowProvisioningUpdates

xcodegen:
	xcodegen generate

clean:
	swift package --package-path Core clean
	rm -rf ~/Library/Developer/Xcode/DerivedData/Kios-*
