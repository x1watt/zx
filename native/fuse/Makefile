# Builds zx-mount, the FUSE daemon of "zx mount" (needs libfuse3).
#
#   make                 build ./zx-mount
#   make clean
#
# The headers come from libfuse3-dev when it is installed (pkg-config
# fuse3). Without it, tool/fetch_fuse_headers.sh puts them into
# ref/build-deps/root (apt-get download, no root) and this Makefile uses
# them there, linking against the libfuse3.so.4 that is installed.

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
DEPS := $(ROOT)/ref/build-deps/root
MULTIARCH ?= $(shell gcc -print-multiarch 2>/dev/null || echo x86_64-linux-gnu)

ifeq ($(shell pkg-config --exists fuse3 && echo yes),yes)
FUSE_CFLAGS ?= $(shell pkg-config --cflags fuse3)
FUSE_LIBS ?= $(shell pkg-config --libs fuse3)
else
FUSE_CFLAGS ?= -I$(DEPS)/usr/include/fuse3
FUSE_LIBS ?= -L/usr/lib/$(MULTIARCH) -l:libfuse3.so.4
endif

CC ?= gcc
CFLAGS ?= -O2 -g
HARDEN := -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fstack-clash-protection
# -fcf-protection exists on x86 only
HARDEN += $(shell $(CC) -fcf-protection -E -x c /dev/null -o /dev/null 2>/dev/null && echo -fcf-protection)
WARN := -Wall -Wextra
LDHARDEN := -Wl,-z,relro -Wl,-z,now -Wl,--as-needed

all: zx-mount

zx-mount: zx-mount.c zx-rpc.h
	$(CC) $(CFLAGS) $(HARDEN) $(WARN) -D_FILE_OFFSET_BITS=64 $(FUSE_CFLAGS) \
	  -o $@ $< $(LDFLAGS) $(LDHARDEN) $(FUSE_LIBS)

# ---- Windows: zx-mount.exe against WinFsp (tool/fetch_winfsp_headers.sh),
# cross compiled with MinGW (apt install gcc-mingw-w64-x86-64). The program
# loads winfsp-x64.dll (the WinFsp installer); the import library is made
# from the names the headers declare.
WINFSP := $(ROOT)/ref/build-deps/winfsp/inc
WINCC ?= x86_64-w64-mingw32-gcc
WINDLLTOOL ?= x86_64-w64-mingw32-dlltool
WINHDR := $(WINFSP)/fuse/winfsp_fuse.h

windows: zx-mount.exe

winfsp-x64.def: $(WINHDR)
	( echo LIBRARY winfsp-x64.dll; echo EXPORTS; \
	  grep -o 'FSP_FUSE_API_NAME(fsp_fuse_[a-z_]*)' $(WINFSP)/fuse/*.h \
	  | sed 's/.*(\(.*\))/\1/' | sort -u ) > $@

libwinfsp-x64.dll.a: winfsp-x64.def
	$(WINDLLTOOL) -d winfsp-x64.def -l $@

zx-mount.exe: zx-mount-fuse2.c zx-rpc.h libwinfsp-x64.dll.a
	$(WINCC) -O2 $(WARN) -I$(WINFSP) -I$(WINFSP)/fuse -o $@ zx-mount-fuse2.c \
	  -L. -lwinfsp-x64 -static-libgcc -Wl,--nxcompat -Wl,--dynamicbase

clean:
	rm -f zx-mount zx-mount.exe winfsp-x64.def libwinfsp-x64.dll.a

.PHONY: all clean windows
