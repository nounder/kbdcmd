.PHONY: build build-cli install setup clean reset-permissions signing-cert

build:
	./bundle.sh

signing-cert:
	./make-signing-cert.sh

build-cli:
	swift build -c release --product kbdcmd
	mkdir -p $${HOME}/bin
	cp .build/release/kbdcmd $${HOME}/bin/kbdcmd

install: build
	cp -r .build/Kbdcmd.app /Applications/

setup: install
	open /Applications/Kbdcmd.app

clean:
	swift package clean
	rm -rf .build/

reset-permissions:
	tccutil reset Accessibility org.libred.kbdcmd

reset-mic-permission:
	tccutil reset Microphone org.libred.kbdcmd
