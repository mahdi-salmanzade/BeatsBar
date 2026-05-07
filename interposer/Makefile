CC = clang
CFLAGS = -fobjc-arc -O0 -g -arch arm64 -arch x86_64 -mmacosx-version-min=13.0
FRAMEWORKS = -framework Foundation -framework IOBluetooth

all: libaacp_unlock.dylib

libaacp_unlock.dylib: aacp_unlock.m
	$(CC) $(CFLAGS) -dynamiclib -o $@ $< $(FRAMEWORKS)
	codesign --force --sign - --timestamp=none $@

clean:
	rm -f libaacp_unlock.dylib

.PHONY: all clean
