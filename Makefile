# SPDX-FileCopyrightText: Outwright contributors
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Every build and test runs through make (AGENTS.md), with two targets:
#
#   make build   the Swift package, and the iOS app with its extension for the simulator
#   make test    make build, then every unit test and SwiftLint
#
# The maintainer's own targets (the end-to-end tests, the phone, releases) live in private.mk,
# which is not published; where it exists, both targets also cover the closed package (Closed/)
# and build the full app (App/full.yml) beside the open one (App/open.yml).

.PHONY: build test

CLOSED := $(wildcard Closed/Package.swift)
# The app's builds: the open one, then the full one where its spec exists, so the Xcode project
# left behind (App/Outwright.xcodeproj) is the full build's.
BUILDS := open $(if $(wildcard App/full.yml),full)

build:
	swift build --build-tests
	$(if $(CLOSED),swift build --build-tests --package-path Closed)
	@for build in $(BUILDS); do \
		echo "[build] the iOS app, $$build build"; \
		xcodegen generate --spec App/$$build.yml --quiet || exit 1; \
		xcodebuild build -project App/Outwright.xcodeproj -scheme Outwright \
			-destination 'generic/platform=iOS Simulator' -derivedDataPath .build/xcode-$$build \
			CODE_SIGNING_ALLOWED=NO ARCHS=arm64 -quiet || exit 1; \
	done

test: build
	swift test --skip-build
	$(if $(CLOSED),swift test --skip-build --package-path Closed)
	swiftlint lint --strict --quiet
	$(if $(CLOSED),cd Closed && swiftlint lint --strict --quiet)

-include private.mk
