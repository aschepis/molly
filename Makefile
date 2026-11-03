.PHONY: build release test run once doctor stack-up stack-down stack-logs app icon dist install uninstall install-agent uninstall-agent check-dashboards snap-settings snap-dashboards snapshots verify-signature notarize

build:
	swift build

release:
	swift build -c release

test:
	swift test

run:
	swift run molly run

once:
	swift run -q molly once

doctor:
	swift run -q molly doctor

stack-up:
	cd deploy && docker compose up -d

stack-down:
	cd deploy && docker compose down

stack-logs:
	cd deploy && docker compose logs -f --tail=100

APP := dist/Molly.app
ICON := packaging/AppIcon.icns
ENTITLEMENTS := packaging/Molly.entitlements
# A certificate keeps the code identity stable across rebuilds, so TCC grants
# (Full Disk Access) survive `make install`. Ad-hoc signing pins them to one build.
CODESIGN_IDENTITY ?= Developer ID Application
HAVE_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -c "$(CODESIGN_IDENTITY)")
ifeq ($(HAVE_IDENTITY),0)
CODESIGN_FLAGS := --sign -
else
CODESIGN_FLAGS := --sign "$(CODESIGN_IDENTITY)" --options runtime --timestamp --entitlements $(ENTITLEMENTS)
endif
NOTARY_PROFILE ?= notary-profile
VERSION := $(shell grep -o 'static let current = "[^"]*"' Sources/Molly/Core/CollectorManager.swift | cut -d'"' -f2)

# Regenerates the icon from scripts/render-icon.swift (macOS tools only).
icon:
	scripts/make-icon.sh $(ICON)

$(ICON):
	scripts/make-icon.sh $(ICON)

app: release $(ICON)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/molly $(APP)/Contents/MacOS/molly
	cp $(ICON) $(APP)/Contents/Resources/AppIcon.icns
	sed "s/@VERSION@/$(VERSION)/" packaging/Info.plist.in > $(APP)/Contents/Info.plist
ifeq ($(HAVE_IDENTITY),0)
	@echo "warning: no '$(CODESIGN_IDENTITY)' identity in keychain; signing ad-hoc (Full Disk Access will not survive rebuilds, see docs/SIGNING.md)"
endif
	codesign --force $(CODESIGN_FLAGS) $(APP)
	@echo "built $(APP) ($(VERSION), signed with: $(if $(filter 0,$(HAVE_IDENTITY)),ad-hoc,$(CODESIGN_IDENTITY)))"

verify-signature:
	codesign --verify --strict --verbose=2 $(APP)
	codesign -d -r- $(APP) 2>&1 | grep designated
	spctl -a -vv -t exec $(APP) || true

# Needs a keychain profile created once with:
#   xcrun notarytool store-credentials notary-profile --apple-id ... --team-id ... --password ...
notarize: dist
	xcrun notarytool submit dist/Molly-$(VERSION).zip --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(APP)
	@echo "notarized and stapled $(APP)"

# A zip plus checksum for handing the app to another machine.
dist: app
	rm -f dist/Molly-$(VERSION).zip dist/Molly-$(VERSION).zip.sha256
	cd dist && ditto -c -k --keepParent Molly.app Molly-$(VERSION).zip
	cd dist && shasum -a 256 Molly-$(VERSION).zip > Molly-$(VERSION).zip.sha256
	@echo "built dist/Molly-$(VERSION).zip"

install: app
	rm -rf /Applications/Molly.app
	cp -R $(APP) /Applications/Molly.app
	@echo "installed /Applications/Molly.app (grant it Full Disk Access, then enable Launch at Login from the menu bar or run: molly install-agent)"

uninstall:
	-launchctl print gui/$$(id -u)/com.aschepis.molly >/dev/null 2>&1 && /Applications/Molly.app/Contents/MacOS/molly uninstall-agent
	rm -rf /Applications/Molly.app

install-agent:
	swift run -q molly install-agent

uninstall-agent:
	swift run -q molly uninstall-agent

# Needs the installed Molly.app running (or MOLLY_BIN pointing at a running daemon's binary).
snap-settings:
	scripts/snap-settings.sh

# Starts the compose "render" profile; RANGE=7d changes the time window.
snap-dashboards:
	scripts/snap-dashboards.sh $(or $(RANGE),24h)

snapshots: snap-settings snap-dashboards

check-dashboards:
	scripts/check-dashboards.sh docs/METRICS.md
