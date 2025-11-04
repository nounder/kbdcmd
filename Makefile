.PHONY: build build-cli build-app build-app-bundle setup debug debug-app dev clean install-app

build: build-cli

build-cli:
	make setup && swift build -c release --product kbdcmd && cp .build/release/kbdcmd $${HOME}/bin/kbdcmd

build-app:
	swift build -c release --product kbdcmd-app && mkdir -p $${HOME}/Applications && cp .build/release/kbdcmd-app $${HOME}/bin/kbdcmd-app

build-app-bundle:
	./build-app-bundle.sh

install-app: build-app-bundle
	cp -r .build/Kbdcmd.app /Applications/
	@echo "✅ Kbdcmd.app installed to /Applications/"
	@echo "You can now launch it from Launchpad or Applications folder"

build-all: build-cli build-app

setup:
	mkdir -p $${HOME}/bin

debug:
	make setup && swift build -c debug --product kbdcmd && cp .build/debug/kbdcmd $${HOME}/bin/kbdcmd-debug

debug-app:
	swift build -c debug --product kbdcmd-app && cp .build/debug/kbdcmd-app $${HOME}/bin/kbdcmd-app-debug

dev:
	ls **/*.{c,swift} | entr -r make build

clean:
	swift package clean
	rm -rf .build/Kbdcmd.app
