APP := LLMUsageBar
BUNDLE := build/$(APP).app
INSTALL_DIR := /Applications

.PHONY: build test bundle run install uninstall clean

build:
	swift build -c release

test:
	swift test

bundle:
	scripts/bundle-app.sh

# Rebuild the bundle and launch it from build/ (kills a running copy first).
run: bundle
	-pkill -x $(APP)
	sleep 0.5
	open $(BUNDLE)

# Rebuild the bundle, copy to /Applications, and launch it.
install: bundle
	-pkill -x $(APP)
	sleep 0.5
	rm -rf $(INSTALL_DIR)/$(APP).app
	cp -R $(BUNDLE) $(INSTALL_DIR)/
	open $(INSTALL_DIR)/$(APP).app

# Remove the installed app. Turn off Launch at login from the click menu first if it was on,
# so macOS does not keep a login item pointing at a deleted bundle.
uninstall:
	-pkill -x $(APP)
	rm -rf $(INSTALL_DIR)/$(APP).app

clean:
	rm -rf .build build
