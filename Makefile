# Developer entry points. `make check` = format lint + all tests.
PACKAGE      := Packages/TuyaLocal
SWIFT_DIRS   := $(PACKAGE)/Sources $(PACKAGE)/Tests $(wildcard catLight catLightTests)
XCODEPROJ    := catLight.xcodeproj

DERIVED      := build
APP_PATH     := $(DERIVED)/Build/Products/Debug/catLight.app

.PHONY: check lint format build run release install test test-package test-app probe discover clean

check: lint test

lint:
	swift format lint --recursive --strict $(SWIFT_DIRS)

format:
	swift format --in-place --recursive $(SWIFT_DIRS)

build:
	cd $(PACKAGE) && swift build
ifneq ($(wildcard $(XCODEPROJ)),)
	xcodebuild -project $(XCODEPROJ) -scheme catLight -derivedDataPath $(DERIVED) build
endif

# Builds and launches the menu bar app (no Dock icon). Stop it with: pkill -x catLight
run: build
	open $(APP_PATH)

# Release build (ad-hoc signed, Hardened Runtime, sandboxed) -> build/catLight.xcarchive
release:
	xcodebuild -project $(XCODEPROJ) -scheme catLight -configuration Release -archivePath $(DERIVED)/catLight.xcarchive archive

# Copies the release app into /Applications (quit any running catLight first).
install: release
	-pkill -x catLight
	rm -rf /Applications/catLight.app
	cp -R $(DERIVED)/catLight.xcarchive/Products/Applications/catLight.app /Applications/catLight.app
	open /Applications/catLight.app

test: test-package test-app

test-package:
	cd $(PACKAGE) && swift test

# App tests need the Xcode project (and full Xcode, not just Command Line Tools).
test-app:
ifneq ($(wildcard $(XCODEPROJ)),)
	xcodebuild -project $(XCODEPROJ) -scheme catLight test
else
	@echo "note: $(XCODEPROJ) not present yet - skipping app tests"
endif

# make probe IP=192.168.0.20 ID=<deviceID> KEY=<localKey>
probe:
	cd $(PACKAGE) && swift run tuya-probe $(IP) $(ID) $(KEY)

discover:
	cd $(PACKAGE) && swift run tuya-probe --discover 15

clean:
	cd $(PACKAGE) && swift package clean
