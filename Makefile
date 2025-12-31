build:
	./bundle.sh

build-cli:
	make setup && swift build -c release --product kbdcmd && cp .build/release/kbdcmd $${HOME}/bin/kbdcmd

install:
	make build && cp -r .build/Kbdcmd.app /Applications/

setup:
	make install && open /Applications/Kbdcmd.app

clean:
	swift package clean
	rm -rf .build/

reset-permissions:
	tccutil reset Accessibility org.libred.kbdcmd
