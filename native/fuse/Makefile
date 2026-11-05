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

zx-mount: zx-mount.c
	$(CC) $(CFLAGS) $(HARDEN) $(WARN) -D_FILE_OFFSET_BITS=64 $(FUSE_CFLAGS) \
	  -o $@ $< $(LDFLAGS) $(LDHARDEN) $(FUSE_LIBS)

clean:
	rm -f zx-mount

.PHONY: all clean
