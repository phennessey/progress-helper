# progress-helper build. `make` builds a universal binary and the AppleScript library.
# `make install` puts them in ~/.local (no sudo). Override with PREFIX=/some/path.

PREFIX    ?= $(HOME)/.local
MIN_MACOS := 12.0
SRC       := Sources/progress-helper/main.swift
BUILD     := build
BIN       := $(BUILD)/progress-helper
LIB       := $(BUILD)/ProgressHelperLib.scptd

.PHONY: all install uninstall test clean

all: $(BIN) $(LIB)

$(BIN): $(SRC)
	@mkdir -p $(BUILD)
	swiftc -O -target arm64-apple-macos$(MIN_MACOS)  -o $(BUILD)/progress-helper-arm64  $(SRC) -framework Cocoa
	swiftc -O -target x86_64-apple-macos$(MIN_MACOS) -o $(BUILD)/progress-helper-x86_64 $(SRC) -framework Cocoa
	lipo -create -output $@ $(BUILD)/progress-helper-arm64 $(BUILD)/progress-helper-x86_64
	codesign --force --sign - $@

$(LIB): AppleScript/ProgressHelperLib.applescript AppleScript/ProgressHelperLib.sdef AppleScript/Info.plist
	@mkdir -p $(BUILD)
	rm -rf $@
	osacompile -o $@ AppleScript/ProgressHelperLib.applescript
	cp AppleScript/Info.plist $@/Contents/Info.plist
	cp AppleScript/ProgressHelperLib.sdef $@/Contents/Resources/ProgressHelperLib.sdef

install: all
	install -d "$(PREFIX)/bin" "$(PREFIX)/share/progress-helper"
	install -m 755 $(BIN) "$(PREFIX)/bin/progress-helper"
	rm -rf "$(PREFIX)/share/progress-helper/ProgressHelperLib.scptd"
	cp -R $(LIB) "$(PREFIX)/share/progress-helper/"
	"$(PREFIX)/bin/progress-helper" setup-applescript

uninstall:
	rm -f "$(PREFIX)/bin/progress-helper"
	rm -rf "$(PREFIX)/share/progress-helper"
	rm -rf "$(HOME)/Library/Script Libraries/ProgressHelperLib.scptd"

test: $(BIN)
	tests/test.sh $(BIN)

clean:
	rm -rf $(BUILD)
