SHELL := /bin/bash
.DEFAULT_GOAL := build

ROOT_DIR := $(CURDIR)
ARTIFACT_DIR := $(ROOT_DIR)/.artifacts
BIN_DIR := $(ARTIFACT_DIR)/bin
APP_BUNDLE := $(ARTIFACT_DIR)/AgentNest.app
SWIFT_CONFIGURATION ?= release
LICENSE_SERVER_URL ?=
LICENSE_PUBLIC_KEY ?=

.PHONY: build build-client build-server test test-client test-server e2e check clean

build: build-client build-server

build-client:
	swift build -c $(SWIFT_CONFIGURATION) --product AgentNestApp
	swift build -c $(SWIFT_CONFIGURATION) --product agentnest-cli
	/bin/rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	cp "$(ROOT_DIR)/Resources/Info.plist" "$(APP_BUNDLE)/Contents/Info.plist"
	if [[ -n "$(LICENSE_SERVER_URL)" ]]; then plutil -replace AgentNestLicenseServerURL -string "$(LICENSE_SERVER_URL)" "$(APP_BUNDLE)/Contents/Info.plist"; fi
	if [[ -n "$(LICENSE_PUBLIC_KEY)" ]]; then plutil -replace AgentNestLicensePublicKey -string "$(LICENSE_PUBLIC_KEY)" "$(APP_BUNDLE)/Contents/Info.plist"; fi
	cp "$(ROOT_DIR)/.build/$(SWIFT_CONFIGURATION)/AgentNestApp" "$(APP_BUNDLE)/Contents/MacOS/AgentNestApp"
	cp -R "$(ROOT_DIR)/.build/$(SWIFT_CONFIGURATION)/AgentNest_AgentNestCore.bundle" "$(APP_BUNDLE)/Contents/Resources/"
	cp -R "$(ROOT_DIR)/Resources/en.lproj" "$(APP_BUNDLE)/Contents/Resources/"
	cp -R "$(ROOT_DIR)/Resources/zh-Hans.lproj" "$(APP_BUNDLE)/Contents/Resources/"
	plutil -lint "$(APP_BUNDLE)/Contents/Info.plist"

build-server:
	mkdir -p "$(BIN_DIR)"
	cd server && go build -trimpath -o "$(BIN_DIR)/agentnest-license-server" ./cmd/agentnest-license-server

test: test-client test-server

test-client:
	swift run agentnest-core-tests

test-server:
	cd server && go test ./...

e2e: build
	bash e2e/run.sh "$(ROOT_DIR)/.build/$(SWIFT_CONFIGURATION)/agentnest-cli" "$(BIN_DIR)/agentnest-license-server"

check: build test e2e

clean:
	swift package clean
	rm -rf "$(ARTIFACT_DIR)"
