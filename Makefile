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

.PHONY: build test engine-test engine-cross daemon

CLOSED := $(wildcard Closed/Package.swift)
# The Go engine's open module, where it is here (below).
ENGINE := $(wildcard engine/go.mod)
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

test: build $(if $(ENGINE),engine-test engine-cross)
	swift test --skip-build
	$(if $(CLOSED),swift test --skip-build --package-path Closed)
	# Again built optimized, as the App Store build is: some compiler faults show only there.
	swift test -c release -Xswiftc -enable-testing
	$(if $(CLOSED),swift test -c release -Xswiftc -enable-testing --package-path Closed)
	swiftlint lint --strict --quiet
	$(if $(CLOSED),cd Closed && swiftlint lint --strict --quiet)

# The Go engine: the open module engine/ and, where it exists, the closed one, Closed/engine/. The
# engine is published as a repository of its own, so make test runs its tests only where engine/
# is here (ENGINE, above).
ENGINE_CLOSED := $(wildcard Closed/engine/go.mod)

engine-test:
	@test -z "$$(gofmt -l engine $(if $(ENGINE_CLOSED),Closed/engine))" || (gofmt -l engine Closed/engine; echo "gofmt needed"; exit 1)
	cd engine && go test ./...
	$(if $(ENGINE_CLOSED),cd Closed/engine && go test ./...)
	$(if $(ENGINE_CLOSED),cd Closed/engine && go vet -tags e2e ./e2e/...)

# The open module builds for Linux and Windows too, every package with its tests (vet type-checks
# them, which a cross-built test binary cannot run here): there the Mac's own package is empty and
# the daemon says it is not yet supported.
engine-cross:
	cd engine && GOOS=linux CGO_ENABLED=0 go vet ./...
	cd engine && GOOS=windows CGO_ENABLED=0 go vet ./...

# The version the daemon and the CLI are stamped with (outwright --version, outwrightd --version,
# the about command): VERSION when it is set (a release sets it), else dev- and this commit.
ENGINE_VERSION ?= $(or $(VERSION),dev-$(shell git describe --always --dirty --exclude '*' 2>/dev/null || echo local))
VERSION_LDFLAGS = -X github.com/outwright/outwright-engine/compose.Version=$(ENGINE_VERSION) \
	-X github.com/outwright/outwright-engine/client/cli.Version=$(ENGINE_VERSION)

# The daemon and the CLI into .build/engine/: the full build's where Closed/engine exists, else
# the open build's. DAEMON_LDFLAGS carries a build's values (none in the open build); both are
# stamped with ENGINE_VERSION, which the built binaries are checked to answer.
daemon:
	mkdir -p .build/engine
	cd $(if $(ENGINE_CLOSED),Closed/engine,engine) && go build -ldflags '$(DAEMON_LDFLAGS) $(VERSION_LDFLAGS)' -o $(CURDIR)/.build/engine/ ./cmd/outwrightd ./cmd/outwright
	@for bin in outwrightd outwright; do \
		test "$$(.build/engine/$$bin --version)" = "$$bin $(ENGINE_VERSION)" || { echo "$$bin is not stamped $(ENGINE_VERSION)"; exit 1; }; \
	done

-include private.mk
