APP_NAME := Stash
BUNDLE := $(APP_NAME).app
INSTALL_DIR := /Applications
SIGN_IDENTITY := Stash Dev

build: clean
	swift build -c release

bundle: build icon
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	command cp .build/release/StashMac $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	command cp AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	command cp Info.plist $(BUNDLE)/Contents/Info.plist
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
	@osascript -e 'use framework "AppKit"' \
		-e 'set iconImage to current application'\''s NSImage'\''s alloc()'\''s initWithContentsOfFile:"$(INSTALL_DIR)/$(BUNDLE)/Contents/Resources/AppIcon.icns"' \
		-e 'current application'\''s NSWorkspace'\''s sharedWorkspace()'\''s setIcon:iconImage forFile:"$(INSTALL_DIR)/$(BUNDLE)" options:0'
	@killall Dock 2>/dev/null || true
	@echo "Deployed to $(INSTALL_DIR)/$(BUNDLE)"
	open $(INSTALL_DIR)/$(BUNDLE)

clean:
	rm -rf .build $(BUNDLE)

test:
	swift test

.PHONY: build bundle icon deploy clean test cert
