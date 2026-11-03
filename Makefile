.PHONY: build release test run once doctor stack-up stack-down stack-logs app install uninstall install-agent uninstall-agent check-dashboards

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

app: release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/molly $(APP)/Contents/MacOS/molly
	sed "s/@VERSION@/$$($(APP)/Contents/MacOS/molly version | awk '{print $$2}')/" packaging/Info.plist.in > $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)
	@echo "built $(APP)"

install: app
	rm -rf /Applications/Molly.app
	cp -R $(APP) /Applications/Molly.app
	@echo "installed /Applications/Molly.app (grant it Full Disk Access, then: molly install-agent)"

uninstall:
	rm -rf /Applications/Molly.app

install-agent:
	swift run -q molly install-agent

uninstall-agent:
	swift run -q molly uninstall-agent

check-dashboards:
	scripts/check-dashboards.sh docs/METRICS-PLAN.md
