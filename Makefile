APP_NAME := Sightline
APP      := build/$(APP_NAME).app
RELEASE  := $(shell swift build -c release --show-bin-path 2>/dev/null)
ARM_BIN  := .build/arm64-apple-macosx/release
X86_BIN  := .build/x86_64-apple-macosx/release
VERSION  := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
DMG      := build/$(APP_NAME)-$(VERSION).dmg
DMG_DIR  := build/dmg
DMG_RW   := build/rw.dmg
# Release builds don't embed this machine's absolute source paths (#file literals, debug info).
RELEASE_FLAGS := -Xswiftc -file-prefix-map -Xswiftc $(CURDIR)=. -Xswiftc -debug-prefix-map -Xswiftc $(CURDIR)=.
# Files copied into Sightline.app/Contents/Resources (icon + welcome illustration).
APP_RES  := Resources/AppIcon.icns Resources/welcome-light.svg Resources/welcome-dark.svg

.PHONY: run build test app universal dmg install open clean

run:            ## Build + launch the debug binary (fast iteration)
	swift run $(APP_NAME)

build:
	swift build

test:
	swift test

app:            ## Release build (this Mac's arch) wrapped in a signed .app at build/Sightline.app
	swift build -c release $(RELEASE_FLAGS)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(RELEASE)/$(APP_NAME) $(APP)/Contents/MacOS/
	strip -S -x $(APP)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP)/Contents/
	cp -R $(RELEASE)/SwiftTerm_SwiftTerm.bundle $(APP)/Contents/Resources/ 2>/dev/null || true
	cp $(APP_RES) $(APP)/Contents/Resources/
	codesign --force --deep --sign - $(APP)
	@echo "Built $(APP)"

# The combined `--arch arm64 --arch x86_64` build fails under SwiftPM's xcbuild path,
# so each arch is built separately and merged with lipo.
universal:      ## Universal (Apple Silicon + Intel) .app at build/Sightline.app
	swift build -c release --arch arm64 $(RELEASE_FLAGS)
	swift build -c release --arch x86_64 $(RELEASE_FLAGS)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	lipo -create -output $(APP)/Contents/MacOS/$(APP_NAME) $(ARM_BIN)/$(APP_NAME) $(X86_BIN)/$(APP_NAME)
	strip -S -x $(APP)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP)/Contents/
	cp -R $(ARM_BIN)/SwiftTerm_SwiftTerm.bundle $(APP)/Contents/Resources/
	cp $(APP_RES) $(APP)/Contents/Resources/
	codesign --force --deep --sign - $(APP)
	@lipo -info $(APP)/Contents/MacOS/$(APP_NAME)

dmg: universal  ## Shareable disk image: build/Sightline-<version>.dmg (ad-hoc signed, not notarized)
	rm -rf $(DMG_DIR) $(DMG) $(DMG_RW)
	mkdir -p $(DMG_DIR)/.background
	cp -R $(APP) $(DMG_DIR)/
	ln -s /Applications $(DMG_DIR)/Applications
	cp Resources/dmg-background.tiff $(DMG_DIR)/.background/background.tiff
	hdiutil create -volname "$(APP_NAME)" -srcfolder $(DMG_DIR) -fs HFS+ -format UDRW -ov $(DMG_RW)
	scripts/layout-dmg.sh $(DMG_RW) "$(APP_NAME)" $(APP_NAME) Resources/VolumeIcon.icns
	hdiutil convert $(DMG_RW) -format UDZO -imagekey zlib-level=9 -ov -o $(DMG)
	rm -rf $(DMG_DIR) $(DMG_RW)
	@echo "Built $(DMG)"

install: app    ## Copy the .app into /Applications
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP) /Applications/
	@echo "Installed /Applications/$(APP_NAME).app"

open: app
	open $(APP)

clean:
	rm -rf .build build
