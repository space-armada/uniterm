SHELL := bash -o pipefail
.DEFAULT_GOAL := help
.DELETE_ON_ERROR:
.SUFFIXES:
MAKEFLAGS += --warn-undefined-variables

# Everything the build writes stays under the repo, so a sandboxed shell can run it.

# Xcode build output, including the .app bundle.
DERIVED_DATA ?= .build/DerivedData
# Xcode build output for the UI tests. A test build signs the helpers with Xcode's test exceptions,
# and a later plain build in the same folder keeps the app's copies of them. So the UI tests build
# here, apart from the app that `make run` launches and the helper sandbox tests probe.
TEST_DERIVED_DATA ?= .build/DerivedData-test
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
# Seconds one package test may run before it is sampled and aborted. It sits above the longest wait
# a failing test makes, so a failing test still reports its own assertion.
TEST_TIME_LIMIT ?= 120
# Space-separated UI test classes or Class/testMethod names, for test-app-select.
UI_TESTS ?=
# Expected test count for test-app-select. When set, the target fails if the bundle's started-test
# count differs. When empty, only zero tests fail.
EXPECTED_TESTS ?=
# 0-based shard index for test-app-shard. Valid range: 0 to SHARDS-1.
SHARD ?=
# Total number of shards for test-app-shard. Must be at least 1.
SHARDS ?=
# Space-separated swift test filters, for test-package-select.
PACKAGE_TESTS ?=

PACKAGE_DIR := Packages/UnitermKit
SWIFT_DIRS := App Helpers UITests $(PACKAGE_DIR)/Sources $(PACKAGE_DIR)/Tests $(PACKAGE_DIR)/Package.swift
xcodebuild_into = xcodebuild -project uniterm.xcodeproj -scheme uniterm \
	-configuration $(CONFIGURATION) \
	-derivedDataPath $(1) \
	-clonedSourcePackagesDirPath $(SOURCE_PACKAGES)
XCODEBUILD := $(call xcodebuild_into,$(DERIVED_DATA))
XCODEBUILD_TEST := $(call xcodebuild_into,$(TEST_DERIVED_DATA))
UI_TEST_FLAGS := -test-timeouts-enabled YES \
	-default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 120 \
	-collect-test-diagnostics never
# The Xcode target's name holds a space, so each -only-testing argument is quoted whole.
UI_TEST_TARGET := uniterm UITests

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
build: check-ghosttykit-imports check-janet-isolation ghostty ## Build uniterm.app
	$(XCODEBUILD) build

# Runs the binary in the foreground, not through `open`, so the shell owns the process and sees its logs
# and any crash. The app uses the real settings and saves its layout to Application Support.
.PHONY: run
run: build ## Build, then run uniterm.app in the foreground
	$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/uniterm.app/Contents/MacOS/uniterm

.PHONY: clean
clean: ## Remove Xcode and SwiftPM build output. Keeps the Ghostty cache
	rm -rf .build/DerivedData .build/DerivedData-test .build/SourcePackages .build/swiftpm

# A hung package test outlives a cancelled `swift test`, and only this checkout's orphans are ended.
.PHONY: clean-test-processes
clean-test-processes: ## End xctest processes orphaned by a hung or cancelled test run, e.g. make clean-test-processes DRY_RUN=1
	scripts/clean-test-processes.sh $(if $(DRY_RUN),--dry-run) "$(abspath $(SWIFTPM_SCRATCH))" "$(abspath $(FUZZ_SCRATCH))"

##@ Test

.PHONY: test-ci
test-ci: ## Verify CI change detection, result gating, and the package test time limit with fixtures
	bash scripts/test-ci.sh

.PHONY: test
test: test-ci test-package test-helper-sandbox test-app ## Run CI gating, package tests, helper sandbox tests, and app UI tests

.PHONY: test-package
test-package: ghostty ## Run the package tests with swift test, each test under TEST_TIME_LIMIT seconds
	cd $(PACKAGE_DIR) && ../../scripts/run-swift-tests.sh $(TEST_TIME_LIMIT) \
		swift test --scratch-path ../../$(SWIFTPM_SCRATCH)

# An empty list fails instead of falling back to the whole suite, so a partial run never passes for
# a full one.
.PHONY: test-package-select
test-package-select: ghostty ## Run only the named package tests, e.g. make test-package-select PACKAGE_TESTS='LayoutStoreTests'
	$(if $(strip $(PACKAGE_TESTS)),,$(error PACKAGE_TESTS is empty. Name the tests to run, or use make test-package for all of them))
	cd $(PACKAGE_DIR) && ../../scripts/run-swift-tests.sh $(TEST_TIME_LIMIT) \
		swift test --scratch-path ../../$(SWIFTPM_SCRATCH) $(foreach t,$(PACKAGE_TESTS),--filter $(t))

# A helper's sandbox cannot be proved from a package build. This runs the probe and the samples
# against each helper inside the built app, and it fails when a helper is missing, so a lost copy
# phase cannot pass quietly. Run it outside an agent sandbox, where the helpers can start.
.PHONY: test-helper-sandbox
test-helper-sandbox: build ## Run each helper's sandbox probe and samples, and the command's hardened runtime check, against the built app
	test -x "$(abspath $(DERIVED_DATA))/Build/Products/$(CONFIGURATION)/uniterm.app/Contents/Helpers/ImageDecoder"
	test -x "$(abspath $(DERIVED_DATA))/Build/Products/$(CONFIGURATION)/uniterm.app/Contents/Helpers/DocumentDecoder"
	test -x "$(abspath $(DERIVED_DATA))/Build/Products/$(CONFIGURATION)/uniterm.app/Contents/Helpers/uniterm"
	cd $(PACKAGE_DIR) && \
		UNITERM_IMAGE_HELPER="$(abspath $(DERIVED_DATA))/Build/Products/$(CONFIGURATION)/uniterm.app/Contents/Helpers/ImageDecoder" \
		UNITERM_DOCUMENT_HELPER="$(abspath $(DERIVED_DATA))/Build/Products/$(CONFIGURATION)/uniterm.app/Contents/Helpers/DocumentDecoder" \
		UNITERM_COMMAND_HELPER="$(abspath $(DERIVED_DATA))/Build/Products/$(CONFIGURATION)/uniterm.app/Contents/Helpers/uniterm" \
		../../scripts/run-swift-tests.sh $(TEST_TIME_LIMIT) \
		swift test --scratch-path ../../$(SWIFTPM_SCRATCH) --filter HelperSandboxTests

.PHONY: fuzz
fuzz: ghostty ## Fuzz the table, GeoJSON, wire, exec frame, controller, policy, declaration, form spec, and PDF readers under ASan. Slow, so make ci skips it
	cd $(PACKAGE_DIR) && UNITERM_FUZZ_ITERATIONS=$(FUZZ_ITERATIONS) \
		swift test --sanitize=address --scratch-path ../../$(FUZZ_SCRATCH) \
		--filter TableFuzzTests --filter GeoJSONFuzzTests --filter ImageWireFuzzTests \
		--filter DocumentWireFuzzTests --filter PDFFuzzTests --filter ScriptWireFuzzTests \
		--filter ExecFrameFuzzTests --filter ControllerFormatFuzzTests --filter ControllerPolicyFuzzTests \
		--filter DeclaredScriptFuzzTests --filter FormSpecFuzzTests

# A failing UI test would otherwise attach a recording of the whole screen, with whatever else is
# on it. The tests keep screenshots of uniterm's own elements instead. The scheme also keeps no
# system attachments and captures screenshots, not recordings, so a direct xcodebuild test
# records nothing either.
.PHONY: test-app
test-app: ghostty ## Run the UI tests with xcodebuild. They need a GUI session and Accessibility permission. A local run needs the pointer and keyboard left alone. A failed run keeps XCTest's event log in .build/DerivedData-test/ui-test-kept-log.txt.gz
	UNITERM_UI_KEPT_LOG="$(TEST_DERIVED_DATA)/ui-test-kept-log.txt.gz" \
		scripts/run-ui-tests.sh $(XCODEBUILD_TEST) $(UI_TEST_FLAGS) test

# Like test-package-select, an empty list fails instead of running the whole suite. This fails loudly
# when a named class does not exist, so a selection that matches nothing cannot pass.
.PHONY: test-app-select
test-app-select: ghostty ## Run only the named UI test classes or methods, e.g. make test-app-select UI_TESTS='TabsUITests PaneTreeUITests/testCommandZLeavesAClosedPaneClosed'. A local run needs the pointer and keyboard left alone. A failed run keeps XCTest's event log in .build/DerivedData-test/ui-test-kept-log.txt.gz
	$(if $(strip $(UI_TESTS)),,$(error UI_TESTS is empty. Name the tests to run, or use make test-app for the full suite))
	UNITERM_UI_KEPT_LOG="$(TEST_DERIVED_DATA)/ui-test-kept-log.txt.gz" \
		scripts/run-ui-test-selection.sh "$(TEST_DERIVED_DATA)" "$(UI_TESTS)" "$(EXPECTED_TESTS)" "$(UI_TEST_TARGET)" $(XCODEBUILD_TEST) $(UI_TEST_FLAGS)

.PHONY: test-app-shard
test-app-shard: ghostty ## Run one shard of the UI tests, e.g. make test-app-shard SHARD=0 SHARDS=3. A local run needs the pointer and keyboard left alone. A failed shard keeps XCTest's event log in .build/DerivedData-test/ui-test-kept-log-shard-SHARD.txt.gz
	if [[ -z "$(SHARD)" ]]; then echo "Error: SHARD is empty. Set SHARD to the 0-based shard index" >&2; exit 1; fi; \
	if [[ -z "$(SHARDS)" ]]; then echo "Error: SHARDS is empty. Set SHARDS to the total number of shards" >&2; exit 1; fi; \
	if ! [[ "$(SHARD)" =~ ^[0-9]+$$ ]] || ! [[ "$(SHARDS)" =~ ^[0-9]+$$ ]]; then echo "Error: SHARD and SHARDS must be numbers" >&2; exit 1; fi; \
	if [[ "$(SHARD)" -lt 0 ]] || [[ "$(SHARD)" -ge "$(SHARDS)" ]]; then echo "Error: SHARD $(SHARD) out of range 0..$$(( $(SHARDS) - 1 ))" >&2; exit 1; fi
	@echo "Building test bundle..."
	$(XCODEBUILD_TEST) build-for-testing
	@echo "Enumerating test classes under screen lock..."
	@scripts/run-ui-tests.sh scripts/list-ui-test-classes.sh $(XCODEBUILD_TEST) >$(TEST_DERIVED_DATA)/class-list.txt
	@echo "Splitting into $(SHARDS) shards..."
	@scripts/shard-ui-tests.sh $(SHARD) $(SHARDS) $(TEST_DERIVED_DATA)/class-list.txt $(TEST_DERIVED_DATA)/shard-$(SHARD)-count.txt >$(TEST_DERIVED_DATA)/shard-$(SHARD).txt
	@if [[ ! -s $(TEST_DERIVED_DATA)/shard-$(SHARD).txt ]]; then \
		echo "Error: shard $(SHARD) is empty" >&2; exit 1; \
	fi
	@shard_classes=$$(cat $(TEST_DERIVED_DATA)/shard-$(SHARD).txt | tr '\n' ' ' | sed 's/ *$$//'); \
	test_count=$$(cat $(TEST_DERIVED_DATA)/shard-$(SHARD)-count.txt); \
	echo "Shard $(SHARD) of $(SHARDS) runs: $$shard_classes"; \
	echo "Reproduce this shard with: make test-app-select UI_TESTS='$$shard_classes' EXPECTED_TESTS=$$test_count"; \
	echo "Selected $$test_count tests"; \
	UNITERM_UI_KEPT_LOG="$(TEST_DERIVED_DATA)/ui-test-kept-log-shard-$(SHARD).txt.gz" \
		scripts/run-ui-test-selection.sh "$(TEST_DERIVED_DATA)" "$$shard_classes" "$$test_count" "$(UI_TEST_TARGET)" $(XCODEBUILD_TEST) $(UI_TEST_FLAGS)

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
check: check-ghosttykit-imports check-janet-isolation check-janet-vendor check-test-defaults check-ui-wheel ## Check the Swift language mode, the GhosttyKit and Janet boundaries, the vendored Janet, test defaults domains, UI test wheels, and that the sandbox is off
	scripts/check-swift-mode.sh
	scripts/check-sandbox-off.sh

.PHONY: check-test-defaults
check-test-defaults: ## Fail when a test opens a named defaults domain without TestDefaults, which leaks a plist
	scripts/check-test-defaults.sh

.PHONY: check-ui-wheel
check-ui-wheel: ## Fail when a UI test sends an XCUI wheel outside the shared call, which skips its pointer settle
	scripts/check-ui-wheel.sh --self-test
	scripts/check-ui-wheel.sh

.PHONY: check-ghosttykit-imports
check-ghosttykit-imports: ## Fail when any module but TerminalSurface can reach GhosttyKit
	scripts/check-ghosttykit-imports.sh

.PHONY: check-janet-isolation
check-janet-isolation: ## Fail when Janet can reach the app process
	scripts/check-janet-isolation.sh

.PHONY: check-janet-vendor
check-janet-vendor: ## Fail when the vendored Janet differs from janet.pin
	scripts/vendor-janet.sh --verify

.PHONY: vendor-janet
vendor-janet: ## Fetch the pinned Janet release, verify it, build the amalgamation, and copy it in. Needs the network
	scripts/vendor-janet.sh

.PHONY: licenses
licenses: ## Collect the license notices for Ghostty, its libraries, the Swift packages, and the web assets into Licenses/
	scripts/collect-licenses.sh

.PHONY: web-assets
web-assets: ## Fetch the pinned Markdown parser and sanitizer, verify them, and copy them in. Needs the network
	scripts/fetch-web-assets.sh

# CI runs ci-package and three app shards side by side, then ghostty-offline-check. The offline
# rebuild runs only when no earlier run proved the same Ghostty inputs on the same runner image. The
# job targets let a failed job be rerun locally on its own. A CI run calls test-app-shard, not
# ci-app, so ci-app covers every UI test for a local full run.
.PHONY: ci
ci: ci-package ci-app ghostty-offline-check ## Run every CI job. Includes the 4-minute offline Ghostty rebuild

.PHONY: ci-package
ci-package: fmt-check lint check test-ci test-package test-helper-sandbox swiftpm-offline-check ## Run CI's package job: checks, package tests, helper sandbox tests, and the SwiftPM offline check

.PHONY: ci-app
ci-app: test-app ## Run the UI tests locally. CI runs test-app-shard for each of three shards instead

.PHONY: ci-changes
ci-changes:
	bash scripts/ci-changes.sh

.PHONY: ci-tested-tree
ci-tested-tree:
	bash scripts/ci-tested-tree.sh

.PHONY: ci-result
ci-result:
	bash scripts/ci-result.sh
