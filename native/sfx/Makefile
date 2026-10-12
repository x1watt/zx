# Builds the parts of a zx self-extracting archive (.zx.sfx):
#   out/engine-<arch>  wasm3 + host functions, static, one per CPU
#   out/zxsfx.wasm     the decoder, one for every CPU
# Tools: zig (cross compiler for the engines), clang + wasm-ld (decoder).
# tool/build_sfx.sh fetches zig into build/tools when it is missing.

ZIG     ?= zig
CLANG   ?= clang
ARCHES  ?= x86_64 aarch64 riscv64 arm
OUT     := out

ENGINE_SRC := engine/engine.c $(wildcard engine/wasm3/*.c)
ENGINE_FLAGS := -Os -s -static -std=gnu11 -Iengine/wasm3 \
  -ffunction-sections -fdata-sections -Wl,--gc-sections \
  -fno-asynchronous-unwind-tables -fno-unwind-tables \
  -Dd_m3MaxLinearMemoryPages=65536 -Dd_m3VerboseErrorMessages=0 \
  -Dd_m3HasWASI=0 -Wno-everything

# The decoder: the zx reader and the C port of zcm (decoder/*.c, compiled
# with -fwrapv -ffp-contract=off so that it computes what the Dart code
# computes) and the LZMA SDK decoders (decoder/lzma, public domain).
DEC_SRC := $(filter-out decoder/host_native.c,$(wildcard decoder/*.c)) \
  $(wildcard decoder/lzma/*.c)
DEC_HDR := $(wildcard decoder/*.h decoder/lzma/*.h decoder/libc/*.h)
DEC_COMMON := -fwrapv -ffp-contract=off -Wall -Wextra -Wno-unused-parameter
DEC_FLAGS := --target=wasm32 -Os -nostdlib -ffreestanding -std=gnu11 \
  -mbulk-memory -isystem decoder/libc $(DEC_COMMON) \
  -Wl,--no-entry -Wl,--export=_start -Wl,--gc-sections \
  -Wl,--max-memory=4294967296 -Wl,-z,stack-size=1048576 -Wl,--strip-all

all: $(addprefix $(OUT)/engine-,$(ARCHES)) $(OUT)/zxsfx.wasm

# The same decoder as a native program, for the tests:
#   out/zxsfx-native <file> <archive offset> [options]
native: $(OUT)/zxsfx-native

$(OUT)/zxsfx-native: $(DEC_SRC) decoder/host_native.c $(DEC_HDR)
	@mkdir -p $(OUT)
	$(CC) -O2 -g -std=gnu11 $(DEC_COMMON) $(DEC_SRC) decoder/host_native.c -o $@

$(OUT)/engine-%: $(ENGINE_SRC) $(wildcard engine/wasm3/*.h)
	@mkdir -p $(OUT)
	$(ZIG) cc -target $*-linux-musl$(if $(filter arm,$*),eabihf,) $(ENGINE_FLAGS) $(ENGINE_SRC) -o $@ -lm

$(OUT)/zxsfx.wasm: $(DEC_SRC) $(DEC_HDR)
	@mkdir -p $(OUT)
	$(CLANG) $(DEC_FLAGS) $(DEC_SRC) -o $@

clean:
	rm -rf $(OUT)

.PHONY: all clean native
