
build:
	make setup && swift build -c release && cp .build/release/kbdcmd $${HOME}/bin/kbdcmd

setup:
	mkdir -p $${HOME}/bin

debug:
	make build && swift build -c debug && mv .build/debug/kbdcmd $${HOME}/bin/kbdcmd-debug

dev:
	ls ls **/*.{c,swift} | entr -r make build
