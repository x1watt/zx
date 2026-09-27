# Builds libzx-nautilus.so, the Nautilus (43 and later) extension of zx.
#
#   make                 build ./libzx-nautilus.so
#   make test            build and run the test harness (no Nautilus needed)
#   make clean
#
# The headers come from libnautilus-extension-dev when it is installed
# (pkg-config libnautilus-extension-4). Without it, tool/fetch_nautilus_headers.sh
# puts them into ref/build-deps/root (apt-get download, no root) and this
# Makefile uses them there. The library linked against is the
# libnautilus-extension.so.4 that comes with Nautilus.

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
DEPS := $(ROOT)/ref/build-deps/root
MULTIARCH ?= $(shell gcc -print-multiarch 2>/dev/null || echo x86_64-linux-gnu)

ifeq ($(shell pkg-config --exists libnautilus-extension-4 && echo yes),yes)
NAUTILUS_CFLAGS ?= $(shell pkg-config --cflags libnautilus-extension-4)
NAUTILUS_LIBS ?= $(shell pkg-config --libs libnautilus-extension-4)
else
NAUTILUS_CFLAGS ?= -I$(DEPS)/usr/include/nautilus $(shell pkg-config --cflags gio-2.0 gmodule-2.0)
NAUTILUS_LIBS ?= -L/usr/lib/$(MULTIARCH) -l:libnautilus-extension.so.4 \
                 $(shell pkg-config --libs gio-2.0 gobject-2.0 glib-2.0)
endif

CC ?= gcc
CFLAGS ?= -O2 -g
HARDEN := -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fstack-clash-protection -fcf-protection
WARN := -Wall -Wextra -Wno-unused-parameter
LDHARDEN := -Wl,-z,relro -Wl,-z,now -Wl,--as-needed -Wl,-z,defs

all: libzx-nautilus.so

libzx-nautilus.so: zx-nautilus.c
	$(CC) $(CFLAGS) $(HARDEN) $(WARN) -fPIC -fvisibility=hidden -shared \
	  $(NAUTILUS_CFLAGS) -o $@ $< $(LDFLAGS) $(LDHARDEN) $(NAUTILUS_LIBS)

zx-nautilus-test: test_harness.c libzx-nautilus.so
	$(CC) $(CFLAGS) $(WARN) $(NAUTILUS_CFLAGS) -o $@ test_harness.c \
	  $(NAUTILUS_LIBS) $(shell pkg-config --libs gmodule-2.0)

test: zx-nautilus-test
	./zx-nautilus-test ./libzx-nautilus.so

clean:
	rm -f libzx-nautilus.so zx-nautilus-test

.PHONY: all test clean
