APP_NAME := Stash
BUNDLE := $(APP_NAME).app
INSTALL_DIR := /Applications
SIGN_IDENTITY := Stash Dev

build:
	swift build -c release

# Force a full from-scratch build by wiping the SwiftPM cache
# first. Use when something looks stale (corrupted incremental
# state, suspect dep version mismatch). Normal `make deploy`
# relies on swift's incremental builder so VimEngine and other
# unchanged dependencies don't recompile on every iteration.
rebuild: clean build

bundle: build icon
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	command cp .build/release/StashMac $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	command cp AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	command cp Info.plist $(BUNDLE)/Contents/Info.plist
	xcrun actool Sources/StashMac/Resources/Assets.xcassets \
		--compile $(BUNDLE)/Contents/Resources \
		--platform macosx \
		--minimum-deployment-target 15.0 \
		--output-format human-readable-text >/dev/null
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q "$(SIGN_IDENTITY)"; then \
		codesign --force --sign "$(SIGN_IDENTITY)" $(BUNDLE); \
		echo "Signed with $(SIGN_IDENTITY)"; \
	else \
		echo "Warning: no '$(SIGN_IDENTITY)' certificate — run 'make cert' to create one"; \
	fi

cert:
	@echo "Creating self-signed code-signing certificate '$(SIGN_IDENTITY)'..."
	@printf '[req]\ndistinguished_name=dn\nx509_extensions=cs\nprompt=no\n[dn]\nCN=$(SIGN_IDENTITY)\n[cs]\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\n' > /tmp/stash-cert.conf
	@openssl req -x509 -newkey rsa:2048 -noenc -keyout /tmp/stash-dev.key -out /tmp/stash-dev.crt -days 3650 -config /tmp/stash-cert.conf 2>/dev/null
	@openssl pkcs12 -export -legacy -passout pass:stashdev -inkey /tmp/stash-dev.key -in /tmp/stash-dev.crt -out /tmp/stash-dev.p12 2>/dev/null
	@security import /tmp/stash-dev.p12 -k ~/Library/Keychains/login.keychain-db -P "stashdev" -T /usr/bin/codesign
	@rm -f /tmp/stash-dev.key /tmp/stash-dev.crt /tmp/stash-dev.p12 /tmp/stash-cert.conf
	@echo "Done. Grant trust: open Keychain Access > '$(SIGN_IDENTITY)' cert > Trust > Always Trust"
	@echo "Then run 'make deploy' — Accessibility permission will persist across rebuilds."

icon:
	@test -f AppIcon.icns || swift scripts/generate-icon.swift

deploy: bundle
	pkill -9 -f "$(APP_NAME)" 2>/dev/null || true
	@sleep 1
	command rm -rf $(INSTALL_DIR)/$(BUNDLE)
	ditto $(BUNDLE) $(INSTALL_DIR)/$(BUNDLE)
	xattr -dr com.apple.quarantine $(INSTALL_DIR)/$(BUNDLE) 2>/dev/null || true
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q "$(SIGN_IDENTITY)"; then \
		echo "Installed copy retains '$(SIGN_IDENTITY)' signature from bundle step"; \
	else \
		codesign --force --deep --sign - $(INSTALL_DIR)/$(BUNDLE); \
		echo "Ad-hoc signed (no '$(SIGN_IDENTITY)' cert found — run 'make cert' for a stable identity)"; \
	fi
	@osascript -e 'use framework "AppKit"' \
		-e 'set iconImage to current application'\''s NSImage'\''s alloc()'\''s initWithContentsOfFile:"$(INSTALL_DIR)/$(BUNDLE)/Contents/Resources/AppIcon.icns"' \
		-e 'current application'\''s NSWorkspace'\''s sharedWorkspace()'\''s setIcon:iconImage forFile:"$(INSTALL_DIR)/$(BUNDLE)" options:0'
	@killall Dock 2>/dev/null || true
	@/System/Library/CoreServices/pbs -update 2>/dev/null || true
	@echo "Deployed to $(INSTALL_DIR)/$(BUNDLE)"
	open $(INSTALL_DIR)/$(BUNDLE)

clean:
	rm -rf .build $(BUNDLE)

test:
	swift test

# Launches the installed app with STASH_PHANTOM_CHECK=1, which makes
# it run the phantom-popup watcher and exit after a fixed window with
# status 0 (no hits) or 1 (popup observed). The exec runs Stash
# foreground so any STASH_PHANTOM_POPUP_HIT line on stderr is visible
# in the make output. CHECK_SECONDS is tunable so you can keep it open
# longer while you click around exercising trigger surfaces.
#
# NB: this scans passively — actually exercising every focus path
# (sheets, popovers, inline edits) still requires the user to click
# around during the window. Increase CHECK_SECONDS for that.
CHECK_SECONDS ?= 30
phantom-check:
	@if [ ! -x "$(INSTALL_DIR)/$(BUNDLE)/Contents/MacOS/$(APP_NAME)" ]; then \
		echo "$(BUNDLE) is not installed. Run 'make deploy' first." >&2; \
		exit 2; \
	fi
	@pkill -9 -f "$(APP_NAME)" 2>/dev/null || true
	@sleep 1
	@echo "Running phantom-popup check for $(CHECK_SECONDS)s — click around the app to exercise trigger surfaces…"
	@STASH_PHANTOM_CHECK=1 STASH_PHANTOM_CHECK_SECONDS=$(CHECK_SECONDS) \
		"$(INSTALL_DIR)/$(BUNDLE)/Contents/MacOS/$(APP_NAME)" 2>&1; \
	status=$$?; \
	if [ $$status -eq 0 ]; then \
		echo "✓ Phantom-popup check passed (no hits in $(CHECK_SECONDS)s)"; \
	else \
		echo "✗ Phantom-popup check FAILED — see hits above"; \
	fi; \
	exit $$status

update-vim:
	@echo "Updating swift-vim-engine to the latest tagged release in the configured range..."
	@swift package update swift-vim-engine
	@echo "Review Package.resolved, smoke-test /vim in the app, then commit."

.PHONY: build rebuild bundle icon deploy clean test cert phantom-check update-vim
