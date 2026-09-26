# MaccessHub build helpers. `make` regenerates the Xcode project and builds.
APP      = MaccessHub
BUILD    = build
CONFIG  ?= Debug
PRODUCT  = $(BUILD)/Build/Products/$(CONFIG)/$(APP).app

.PHONY: all gen build run install clean

all: build

gen:
	xcodegen generate

build: gen
	xcodebuild -project $(APP).xcodeproj -scheme $(APP) -configuration $(CONFIG) \
	  -derivedDataPath $(BUILD) build | tail -20

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
