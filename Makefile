SHELL := /bin/bash
.DEFAULT_GOAL := build

ROOT_DIR := $(CURDIR)
ARTIFACT_DIR := $(ROOT_DIR)/.artifacts
BIN_DIR := $(ARTIFACT_DIR)/bin
APP_BUNDLE := $(ARTIFACT_DIR)/AgentNest.app
SWIFT_CONFIGURATION ?= release
LICENSE_SERVER_URL ?=
LICENSE_PUBLIC_KEY ?=
APPCAST_URL ?=
SPARKLE_PUBLIC_KEY ?=
DEVELOPER_ID_APPLICATION ?=
NOTARY_PROFILE ?=
UNIVERSAL_ARM64_DIR := $(ROOT_DIR)/.build/universal-arm64
UNIVERSAL_X86_64_DIR := $(ROOT_DIR)/.build/universal-x86_64

.PHONY: build build-client build-universal build-server test test-client test-server e2e check check-format sign notarize verify-release release clean

build: build-client build-server

build-client:
	swift build -c $(SWIFT_CONFIGURATION) --product AgentNestApp
	swift build -c $(SWIFT_CONFIGURATION) --product agentnest-cli
	/bin/rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources" "$(APP_BUNDLE)/Contents/Frameworks"
	cp "$(ROOT_DIR)/Resources/Info.plist" "$(APP_BUNDLE)/Contents/Info.plist"
	if [[ -n "$(LICENSE_SERVER_URL)" ]]; then plutil -replace AgentNestLicenseServerURL -string "$(LICENSE_SERVER_URL)" "$(APP_BUNDLE)/Contents/Info.plist"; fi
	if [[ -n "$(LICENSE_PUBLIC_KEY)" ]]; then plutil -replace AgentNestLicensePublicKey -string "$(LICENSE_PUBLIC_KEY)" "$(APP_BUNDLE)/Contents/Info.plist"; fi
	if [[ -n "$(APPCAST_URL)" ]]; then [[ "$(APPCAST_URL)" == https://* ]] || { echo "APPCAST_URL must use HTTPS" >&2; exit 1; }; plutil -replace SUFeedURL -string "$(APPCAST_URL)" "$(APP_BUNDLE)/Contents/Info.plist"; fi
	if [[ -n "$(SPARKLE_PUBLIC_KEY)" ]]; then plutil -replace SUPublicEDKey -string "$(SPARKLE_PUBLIC_KEY)" "$(APP_BUNDLE)/Contents/Info.plist"; fi
	cp "$(ROOT_DIR)/.build/$(SWIFT_CONFIGURATION)/AgentNestApp" "$(APP_BUNDLE)/Contents/MacOS/AgentNestApp"
	cp -R "$(ROOT_DIR)/.build/$(SWIFT_CONFIGURATION)/AgentNest_AgentNestCore.bundle" "$(APP_BUNDLE)/Contents/Resources/"
	cp -R "$(ROOT_DIR)/.build/$(SWIFT_CONFIGURATION)/Sparkle.framework" "$(APP_BUNDLE)/Contents/Frameworks/"
	cp -R "$(ROOT_DIR)/Resources/en.lproj" "$(APP_BUNDLE)/Contents/Resources/"
	cp -R "$(ROOT_DIR)/Resources/zh-Hans.lproj" "$(APP_BUNDLE)/Contents/Resources/"
	plutil -lint "$(APP_BUNDLE)/Contents/Info.plist"
	test -d "$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework"
	otool -l "$(APP_BUNDLE)/Contents/MacOS/AgentNestApp" | grep -q '@executable_path/../Frameworks'

build-server:
	mkdir -p "$(BIN_DIR)"
	cd server && go build -trimpath -o "$(BIN_DIR)/agentnest-license-server" ./cmd/agentnest-license-server

build-universal: build-client
	swift build --scratch-path "$(UNIVERSAL_ARM64_DIR)" --triple arm64-apple-macosx14.0 -c release --product AgentNestApp
	swift build --scratch-path "$(UNIVERSAL_X86_64_DIR)" --triple x86_64-apple-macosx14.0 -c release --product AgentNestApp
	swift build --scratch-path "$(UNIVERSAL_ARM64_DIR)" --triple arm64-apple-macosx14.0 -c release --product agentnest-cli
	swift build --scratch-path "$(UNIVERSAL_X86_64_DIR)" --triple x86_64-apple-macosx14.0 -c release --product agentnest-cli
	lipo -create "$(UNIVERSAL_ARM64_DIR)/arm64-apple-macosx/release/AgentNestApp" "$(UNIVERSAL_X86_64_DIR)/x86_64-apple-macosx/release/AgentNestApp" -output "$(APP_BUNDLE)/Contents/MacOS/AgentNestApp"
	lipo -create "$(UNIVERSAL_ARM64_DIR)/arm64-apple-macosx/release/agentnest-cli" "$(UNIVERSAL_X86_64_DIR)/x86_64-apple-macosx/release/agentnest-cli" -output "$(BIN_DIR)/agentnest-cli"
	test "$$(lipo -archs "$(APP_BUNDLE)/Contents/MacOS/AgentNestApp")" = "x86_64 arm64" -o "$$(lipo -archs "$(APP_BUNDLE)/Contents/MacOS/AgentNestApp")" = "arm64 x86_64"
	test "$$(lipo -archs "$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle")" = "x86_64 arm64" -o "$$(lipo -archs "$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle")" = "arm64 x86_64"

test: test-client test-server

test-client:
	swift run agentnest-core-tests

test-server:
	cd server && go test -race ./...

e2e: build
	bash e2e/run.sh "$(ROOT_DIR)/.build/$(SWIFT_CONFIGURATION)/agentnest-cli" "$(BIN_DIR)/agentnest-license-server"

check-format:
	test -z "$$(gofmt -l server)"
	bash -n e2e/run.sh
	swift package dump-package >/dev/null
	plutil -lint "$(ROOT_DIR)/Resources/Info.plist"
	plutil -lint "$(ROOT_DIR)/Resources/en.lproj/Localizable.strings" "$(ROOT_DIR)/Resources/zh-Hans.lproj/Localizable.strings"

check: check-format build test e2e

sign:
	[[ -n "$(DEVELOPER_ID_APPLICATION)" ]] || { echo "DEVELOPER_ID_APPLICATION is required" >&2; exit 1; }
	/usr/bin/codesign --force --deep --options runtime --timestamp --sign "$(DEVELOPER_ID_APPLICATION)" "$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework"
	/usr/bin/codesign --force --options runtime --timestamp --sign "$(DEVELOPER_ID_APPLICATION)" "$(APP_BUNDLE)/Contents/MacOS/AgentNestApp"
	/usr/bin/codesign --force --options runtime --timestamp --sign "$(DEVELOPER_ID_APPLICATION)" "$(APP_BUNDLE)"
	/usr/bin/codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"

notarize:
	[[ -n "$(NOTARY_PROFILE)" ]] || { echo "NOTARY_PROFILE is required" >&2; exit 1; }
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$(ARTIFACT_DIR)/AgentNest-notarization.zip"
	xcrun notarytool submit "$(ARTIFACT_DIR)/AgentNest-notarization.zip" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(APP_BUNDLE)"
	xcrun stapler validate "$(APP_BUNDLE)"

verify-release:
	/usr/bin/codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"
	/usr/sbin/spctl --assess --type execute --verbose=2 "$(APP_BUNDLE)"
	xcrun stapler validate "$(APP_BUNDLE)"

release: build-universal sign notarize verify-release

clean:
	swift package clean
	rm -rf "$(ARTIFACT_DIR)"
