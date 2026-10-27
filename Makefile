SHELL := /bin/bash

APP_NAME := MixTake
CONFIGURATION ?= release
ARCHITECTURE ?= arm64

BUILD_DIRECTORY := build
APP_BUNDLE := $(BUILD_DIRECTORY)/$(APP_NAME).app
APP_EXECUTABLE := $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
ARCHIVE := $(BUILD_DIRECTORY)/$(APP_NAME).zip
SWIFT_BINARY_DIRECTORY := $(BUILD_DIRECTORY)/swift/$(CONFIGURATION)-$(ARCHITECTURE)
SWIFT_BINARY := $(SWIFT_BINARY_DIRECTORY)/$(APP_NAME)
INFO_PLIST := Resources/Info.plist
ICON_DIRECTORY := $(BUILD_DIRECTORY)/app-icon
ASSET_CATALOG := $(ICON_DIRECTORY)/Assets.car
FALLBACK_ICON := $(ICON_DIRECTORY)/MixTake.icns
GENERATED_ICON_PLIST := $(ICON_DIRECTORY)/assetcatalog_generated_info.plist
MODERN_ICON_DIRECTORY := Resources/MixTake.icon
MODERN_ICON_SOURCES := $(shell find $(MODERN_ICON_DIRECTORY) -type f -print)
LEGACY_ICON_SOURCE := Resources/MixTakeLegacy.png
LEGACY_ICONSET := $(BUILD_DIRECTORY)/MixTake.iconset
LEGACY_ICON_FILES := \
	$(LEGACY_ICONSET)/icon_16x16.png \
	$(LEGACY_ICONSET)/icon_16x16@2x.png \
	$(LEGACY_ICONSET)/icon_32x32.png \
	$(LEGACY_ICONSET)/icon_32x32@2x.png \
	$(LEGACY_ICONSET)/icon_128x128.png \
	$(LEGACY_ICONSET)/icon_128x128@2x.png \
	$(LEGACY_ICONSET)/icon_256x256.png \
	$(LEGACY_ICONSET)/icon_256x256@2x.png \
	$(LEGACY_ICONSET)/icon_512x512.png \
	$(LEGACY_ICONSET)/icon_512x512@2x.png
SWIFT_SOURCES := $(shell find Sources -type f -name '*.swift' -print)
SWIFT_SOURCE_DIRECTORIES := $(shell find Sources -type d -print)
ACTOOL := $(shell command -v xcrun >/dev/null 2>&1 && xcrun --find actool 2>/dev/null)

ifneq ($(ACTOOL),)
APP_ICON_DEPENDENCIES := $(ASSET_CATALOG) $(FALLBACK_ICON)
else
APP_ICON_DEPENDENCIES := $(FALLBACK_ICON)
endif

.DEFAULT_GOAL := all
.DELETE_ON_ERROR:

.PHONY: all app clean clean-all

all: $(ARCHIVE)

app: $(APP_EXECUTABLE)

$(SWIFT_BINARY_DIRECTORY) $(LEGACY_ICONSET) $(ICON_DIRECTORY):
	@mkdir -p "$@"

$(SWIFT_BINARY): Package.swift $(SWIFT_SOURCES) $(SWIFT_SOURCE_DIRECTORIES) | $(SWIFT_BINARY_DIRECTORY)
	swift build -c "$(CONFIGURATION)" --arch "$(ARCHITECTURE)"
	@cp "$$(swift build -c "$(CONFIGURATION)" --arch "$(ARCHITECTURE)" --show-bin-path)/$(APP_NAME)" "$@"

$(LEGACY_ICONSET)/icon_16x16.png: ICON_SIZE := 16
$(LEGACY_ICONSET)/icon_16x16@2x.png: ICON_SIZE := 32
$(LEGACY_ICONSET)/icon_32x32.png: ICON_SIZE := 32
$(LEGACY_ICONSET)/icon_32x32@2x.png: ICON_SIZE := 64
$(LEGACY_ICONSET)/icon_128x128.png: ICON_SIZE := 128
$(LEGACY_ICONSET)/icon_128x128@2x.png: ICON_SIZE := 256
$(LEGACY_ICONSET)/icon_256x256.png: ICON_SIZE := 256
$(LEGACY_ICONSET)/icon_256x256@2x.png: ICON_SIZE := 512
$(LEGACY_ICONSET)/icon_512x512.png: ICON_SIZE := 512
$(LEGACY_ICONSET)/icon_512x512@2x.png: ICON_SIZE := 1024

$(LEGACY_ICON_FILES): $(LEGACY_ICON_SOURCE) | $(LEGACY_ICONSET)
	@sips -z "$(ICON_SIZE)" "$(ICON_SIZE)" "$<" --out "$@" >/dev/null

ifneq ($(ACTOOL),)
$(ASSET_CATALOG): $(MODERN_ICON_SOURCES) | $(ICON_DIRECTORY)
	"$(ACTOOL)" "$(MODERN_ICON_DIRECTORY)" \
		--compile "$(ICON_DIRECTORY)" \
		--output-format human-readable-text \
		--notices \
		--warnings \
		--errors \
		--output-partial-info-plist "$(GENERATED_ICON_PLIST)" \
		--app-icon MixTake \
		--include-all-app-icons \
		--enable-on-demand-resources NO \
		--development-region en \
		--target-device mac \
		--minimum-deployment-target 13.0 \
		--platform macosx \
		--standalone-icon-behavior all
	@test -f "$@"
	@test -f "$(FALLBACK_ICON)"
	@test -f "$(GENERATED_ICON_PLIST)"

$(FALLBACK_ICON): $(ASSET_CATALOG)
	@test -f "$@"
else
$(FALLBACK_ICON): $(LEGACY_ICON_FILES) | $(ICON_DIRECTORY)
	@iconutil --convert icns --output "$@" "$(LEGACY_ICONSET)"
endif

$(APP_EXECUTABLE): $(SWIFT_BINARY) $(INFO_PLIST) $(APP_ICON_DEPENDENCIES) Makefile
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(SWIFT_BINARY)" "$@"
	@cp "$(INFO_PLIST)" "$(APP_BUNDLE)/Contents/Info.plist"
	@cp "$(FALLBACK_ICON)" "$(APP_BUNDLE)/Contents/Resources/MixTake.icns"
ifneq ($(ACTOOL),)
	@cp "$(ASSET_CATALOG)" "$(APP_BUNDLE)/Contents/Resources/Assets.car"
else
	@/usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$(APP_BUNDLE)/Contents/Info.plist"
endif
	@/usr/libexec/PlistBuddy -c "Set :MixTakeBuildDate $$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$(APP_BUNDLE)/Contents/Info.plist"
	@codesign --force --deep --sign - "$(APP_BUNDLE)"

$(ARCHIVE): $(APP_EXECUTABLE)
	rm -f "$@"
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$@"

clean:
	rm -rf ".build" "$(BUILD_DIRECTORY)"

clean-all:
	swift package reset
	swift package purge-cache
	rm -rf ".build" "$(BUILD_DIRECTORY)" ".swiftpm"
