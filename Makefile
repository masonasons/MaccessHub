# MaccessHub build helpers. `make` regenerates the Xcode project and builds.
APP      = MaccessHub
BUILD    = build
CONFIG  ?= Debug
PRODUCT  = $(BUILD)/Build/Products/$(CONFIG)/$(APP).app

.PHONY: all gen build run install clean

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
