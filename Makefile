# MaccessHub build helpers. `make` regenerates the Xcode project and builds.
APP      = MaccessHub
BUILD    = build
CONFIG  ?= Debug
PRODUCT  = $(BUILD)/Build/Products/$(CONFIG)/$(APP).app

.PHONY: all gen build run install clean check check-catalog-download

all: build

gen:
	xcodegen generate

# Sign local builds with the same Developer ID identity releases use. macOS
# ties privacy grants (Accessibility, Input Monitoring, Automation) to the
# signing identity, so a Sparkle update from a differently signed local build
# would silently lose them.
DEVID := $(shell security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/')
ifneq ($(DEVID),)
SIGNING = CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$(DEVID)" OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime"
endif

build: gen
	xcodebuild -project $(APP).xcodeproj -scheme $(APP) -configuration $(CONFIG) \
	  -derivedDataPath $(BUILD) $(SIGNING) build | tail -20

# Wait for the old instance to exit; otherwise `open` sees it as still
# running and the relaunch is silently dropped.
define relaunch
	pkill -x $(APP) || true
	while pgrep -x $(APP) >/dev/null; do sleep 0.2; done
	open $(1)
endef

run: build
	$(call relaunch,$(PRODUCT))

# Copy the built app into /Applications and relaunch it.
install: CONFIG = Release
install: build
	pkill -x $(APP) || true
	while pgrep -x $(APP) >/dev/null; do sleep 0.2; done
	rm -rf /Applications/$(APP).app
	cp -R $(PRODUCT) /Applications/$(APP).app
	open /Applications/$(APP).app

clean:
	rm -rf $(BUILD) $(APP).xcodeproj

# Assertion checks for logic that has no UI. Builds only the files involved.
check:
	swiftc -Onone -parse-as-library -o $(BUILD)/speech-history-check Tests/SpeechHistoryCheck.swift \
	  Sources/MaccessHub/Core/Speaker.swift Sources/MaccessHub/Features/SpeechHistory/SpeechHistoryFeature.swift
	$(BUILD)/speech-history-check
	swiftc -Onone -parse-as-library -o $(BUILD)/disk-click-check Tests/DiskClickCheck.swift \
	  Sources/MaccessHub/Features/DiskSounds/DiskClick.swift
	$(BUILD)/disk-click-check
	$(MAKE) $(BUILD)/sound-catalog-check
	$(BUILD)/sound-catalog-check

CATALOG_CHECK_SOURCES = Tests/SoundCatalogCheck.swift Sources/MaccessHub/Sound/SoundCatalog.swift \
  Sources/MaccessHub/Sound/Soundpack.swift Sources/MaccessHub/Sound/SoundEvent.swift \
  Sources/MaccessHub/Sound/NavSoundsImporter.swift

$(BUILD)/sound-catalog-check: $(CATALOG_CHECK_SOURCES)
	mkdir -p $(BUILD)
	swiftc -Onone -parse-as-library -o $@ $(CATALOG_CHECK_SOURCES)

# Downloads the smallest catalog packs into a scratch folder (needs the network).
check-catalog-download: $(BUILD)/sound-catalog-check
	$(BUILD)/sound-catalog-check Resources/SoundCatalog/catalog.json --download
