.PHONY: build release test run once doctor stack-up stack-down stack-logs app install-agent uninstall-agent

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
