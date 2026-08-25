APP := LLMUsageBar
# The app was called ClaudeUsageBar until it grew past Claude. install and uninstall clear the
# old bundle out too, so an upgrade does not leave two copies running side by side in the menu
# bar. Safe to drop once nobody is upgrading from a pre-rename build.
LEGACY_APP := ClaudeUsageBar
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
	-pkill -x $(LEGACY_APP)
	sleep 0.5
	rm -rf $(INSTALL_DIR)/$(APP).app $(INSTALL_DIR)/$(LEGACY_APP).app
	cp -R $(BUNDLE) $(INSTALL_DIR)/
	open $(INSTALL_DIR)/$(APP).app

# Remove the installed app (and any pre-rename copy). Turn off Launch at login from the click
# menu first if it was on, so macOS does not keep a login item pointing at a deleted bundle.
uninstall:
	-pkill -x $(APP)
	-pkill -x $(LEGACY_APP)
	rm -rf $(INSTALL_DIR)/$(APP).app $(INSTALL_DIR)/$(LEGACY_APP).app

clean:
	rm -rf .build build
