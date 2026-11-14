SHELL := bash -o pipefail
.DEFAULT_GOAL := help
.DELETE_ON_ERROR:
.SUFFIXES:
MAKEFLAGS += --warn-undefined-variables

# Everything the build writes stays under the repo, so a sandboxed shell can run it.

# Xcode build output, including the .app bundle.
DERIVED_DATA ?= .build/DerivedData
# Where SwiftPM keeps checkouts for the Xcode build.
SOURCE_PACKAGES ?= .build/SourcePackages
# Where `swift build` and `swift test` keep the package build.
SWIFTPM_SCRATCH ?= .build/swiftpm
# Xcode build configuration.
CONFIGURATION ?= Debug
# Where `make fuzz` keeps its address-sanitized package build, apart from the ordinary one.
FUZZ_SCRATCH ?= .build/swiftpm-fuzz
# How many mutated inputs each fuzz test of `make fuzz` tries. `make test-package` runs the same
# fuzzers at a small count.
FUZZ_ITERATIONS ?= 5000
# Space-separated Swift paths, relative to the repo root, for fmt-select. Empty formats nothing.
FILES ?=
# Set to 1 to have clean-test-processes list what it would end, without ending it.
DRY_RUN ?=

PACKAGE_DIR := Packages/UnitermKit
SWIFT_DIRS := App Helpers UITests $(PACKAGE_DIR)/Sources $(PACKAGE_DIR)/Tests $(PACKAGE_DIR)/Package.swift
XCODEBUILD := xcodebuild -project uniterm.xcodeproj -scheme uniterm \
	-configuration $(CONFIGURATION) \
	-derivedDataPath $(DERIVED_DATA) \
	-clonedSourcePackagesDirPath $(SOURCE_PACKAGES)

##@ Build

.PHONY: help
help: ## Show this help
	@awk 'BEGIN { FS = ":.*## " } \
		/^##@ / { printf "\n%s\n", substr($$0, 5) } \
		/^[a-zA-Z0-9_.\/-]+:([^=]|$$).*## / { printf "  %-24s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: ghostty
ghostty: ## Build the pinned GhosttyKit and link it into the package (needs Zig, only on a cold cache)
	scripts/build-ghostty.sh

.PHONY: build
build: check-ghosttykit-imports ghostty ## Build uniterm.app
	$(XCODEBUILD) build

# Runs the binary in the foreground, not through `open`, so the shell owns the process and sees its logs
# and any crash. The app uses the real settings and saves its layout to Application Support.
.PHONY: run
run: build ## Build, then run uniterm.app in the foreground
	$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/uniterm.app/Contents/MacOS/uniterm

.PHONY: clean
clean: ## Remove Xcode and SwiftPM build output. Keeps the Ghostty cache
	rm -rf .build/DerivedData .build/SourcePackages .build/swiftpm

# A hung package test outlives a cancelled `swift test`, and only this checkout's orphans are ended.
.PHONY: clean-test-processes
clean-test-processes: ## End xctest processes orphaned by a hung or cancelled test run, e.g. make clean-test-processes DRY_RUN=1
	scripts/clean-test-processes.sh $(if $(DRY_RUN),--dry-run) "$(abspath $(SWIFTPM_SCRATCH))" "$(abspath $(FUZZ_SCRATCH))"

##@ Test

.PHONY: test-ci
test-ci: ## Verify CI change detection and result gating with temporary Git history
	bash scripts/test-ci.sh

.PHONY: test
test: test-ci test-package test-helper-sandbox test-app ## Run CI gating, package tests, helper sandbox tests, and app UI tests

.PHONY: test-package
test-package: ghostty ## Run the package tests with swift test
	cd $(PACKAGE_DIR) && swift test --scratch-path ../../$(SWIFTPM_SCRATCH)

# A helper's sandbox cannot be proved from a package build. This runs the probe and the samples
# against each helper inside the built app, and it fails when a helper is missing, so a lost copy
# phase cannot pass quietly. Run it outside an agent sandbox, where the helpers can start.
.PHONY: test-helper-sandbox
test-helper-sandbox: build ## Run each helper's sandbox probe and samples against the helper in the built app
	test -x "$(abspath $(DERIVED_DATA))/Build/Products/$(CONFIGURATION)/uniterm.app/Contents/Helpers/ImageDecoder"
	test -x "$(abspath $(DERIVED_DATA))/Build/Products/$(CONFIGURATION)/uniterm.app/Contents/Helpers/DocumentDecoder"
	cd $(PACKAGE_DIR) && \
		UNITERM_IMAGE_HELPER="$(abspath $(DERIVED_DATA))/Build/Products/$(CONFIGURATION)/uniterm.app/Contents/Helpers/ImageDecoder" \
		UNITERM_DOCUMENT_HELPER="$(abspath $(DERIVED_DATA))/Build/Products/$(CONFIGURATION)/uniterm.app/Contents/Helpers/DocumentDecoder" \
		swift test --scratch-path ../../$(SWIFTPM_SCRATCH) --filter HelperSandboxTests

.PHONY: fuzz
fuzz: ghostty ## Fuzz the table, GeoJSON, wire, and PDF readers under ASan. Slow, so make ci skips it
	cd $(PACKAGE_DIR) && UNITERM_FUZZ_ITERATIONS=$(FUZZ_ITERATIONS) \
		swift test --sanitize=address --scratch-path ../../$(FUZZ_SCRATCH) \
		--filter TableFuzzTests --filter GeoJSONFuzzTests --filter ImageWireFuzzTests \
		--filter DocumentWireFuzzTests --filter PDFFuzzTests

.PHONY: test-app
test-app: ghostty ## Run the UI tests with xcodebuild. They need a GUI session and Accessibility permission
	scripts/run-ui-tests.sh $(XCODEBUILD) -test-timeouts-enabled YES \
		-default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 120 test

.PHONY: ghostty-offline-check
ghostty-offline-check: ## Rebuild the pinned Ghostty with the network off, from the kept caches
	scripts/ghostty-offline-check.sh

.PHONY: swiftpm-offline-check
swiftpm-offline-check: ## Resolve and build the Swift packages with the network off, from the committed pins
	scripts/swiftpm-offline-check.sh

##@ Lint

.PHONY: fmt
fmt: ## Format Swift sources in place
	swift format --configuration .swift-format --in-place --recursive $(SWIFT_DIRS)

.PHONY: fmt-check
fmt-check: ## Verify Swift formatting without changing files
	swift format lint --strict --configuration .swift-format --recursive $(SWIFT_DIRS)

.PHONY: fmt-select
fmt-select: ## Format only the named files, e.g. make fmt-select FILES='App/AppDelegate.swift'
	$(if $(filter %.swift,$(FILES)),swift format --configuration .swift-format --in-place $(filter %.swift,$(FILES)))

.PHONY: lint
lint: fmt-check ## Lint Swift sources and check the scripts parse
	for script in scripts/*.sh; do bash -n "$$script" || exit 1; done
	sh -n Support/ghostty-bin/ghostty

.PHONY: check
check: check-ghosttykit-imports ## Check the Swift language mode, the GhosttyKit boundary, and that the sandbox is off
	scripts/check-swift-mode.sh
	scripts/check-sandbox-off.sh

.PHONY: check-ghosttykit-imports
check-ghosttykit-imports: ## Fail when any module but TerminalSurface can reach GhosttyKit
	scripts/check-ghosttykit-imports.sh

.PHONY: licenses
licenses: ## Collect the license notices for Ghostty, its libraries, the Swift packages, and the web assets into Licenses/
	scripts/collect-licenses.sh

.PHONY: web-assets
web-assets: ## Fetch the pinned Markdown parser and sanitizer, verify them, and copy them in. Needs the network
	scripts/fetch-web-assets.sh

# CI runs ci-package, ci-app, and ghostty-offline-check as three jobs side by side, and skips the
# offline rebuild once an earlier run proved the same Ghostty inputs on the same runner image. The
# job targets let a failed job be rerun locally on its own.
.PHONY: ci
ci: ci-package ci-app ghostty-offline-check ## Run every CI job. Includes the 4-minute offline Ghostty rebuild

.PHONY: ci-package
ci-package: fmt-check lint check test-ci test-package swiftpm-offline-check ## Run CI's package job: checks, package tests, and the SwiftPM offline check

.PHONY: ci-app
ci-app: test-helper-sandbox test-app ## Run CI's app job: the app build, the helper sandbox tests, and the UI tests

.PHONY: ci-changes
ci-changes:
	bash scripts/ci-changes.sh

.PHONY: ci-result
ci-result:
	bash scripts/ci-result.sh
