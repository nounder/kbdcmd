build:
	./bundle.sh

build-cli:
	make setup && swift build -c release --product kbdcmd && cp .build/release/kbdcmd $${HOME}/bin/kbdcmd

install:
	make build && cp -r .build/Kbdcmd.app /Applications/

clean:
	swift package clean
	rm -rf .build/
