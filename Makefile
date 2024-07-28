build:
	swift build -c release && mv .build/release/kbdcmd $${HOME}/bin/kbdcmd

dev:
	ls ls **/*.{c,swift} | entr -r make build
