.PHONY: build release test run once doctor stack-up stack-down stack-logs app icon dist install uninstall install-agent uninstall-agent check-dashboards

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
	codesign --force --sign - $(APP)
	@echo "built $(APP) ($(VERSION))"

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

check-dashboards:
	scripts/check-dashboards.sh docs/METRICS.md
