all:
	gcc -o $${HOME}/bin/kbdcmd kbdcmd.c -framework CoreFoundation -framework ApplicationServices -framework Carbon

