build:
	swift build -c release && mv .build/release/kbdcmd $${HOME}/bin/kbdcmd

debug:
	swift build -c debug && mv .build/debug/kbdcmd $${HOME}/bin/kbdcmd-debug

dev:
	ls ls **/*.{c,swift} | entr -r make build
