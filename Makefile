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

run: build
	pkill -x $(APP) || true
	open $(PRODUCT)

# Copy the built app into /Applications and relaunch it.
install: CONFIG = Release
install: build
	pkill -x $(APP) || true
	rm -rf /Applications/$(APP).app
	cp -R $(PRODUCT) /Applications/$(APP).app
	open /Applications/$(APP).app

clean:
	rm -rf $(BUILD) $(APP).xcodeproj
