// zxsfx decoder: port of zcm_x86.dart, the x86 and x64 code model (level
// 4 and up, on exe blocks).
//
// A port of the ExeModel of paq8px (Marcio Pais, after the earlier paq
// exe models and DisFilter by Fabian Giesen): it parses the input as x86
// and x64 instructions (prefixes, opcode tables, ModRM, SIB, immediates
// and displacements), keeps the last instructions quantised into 32 bits,
// and uses the parser state, the instruction fields and sparse contexts
// at the positions relevant to parsing as contexts, plus six mixer weight
// set selectors. The opcode tables are copied from paq8px ExeModel.hpp.
// Hashes are zcm's 32-bit ones (paq8px uses 64-bit hashes).

#include "zc_x86.h"

// Instruction formats.
#define F_AM 1
#define F_MR 2
#define F_MEXTRA 3
#define F_MODE 3
#define F_BI 4
#define F_WI 8
#define F_DI 12
#define F_TYPE 12
#define F_AD 0
#define F_DA 4
#define F_BR 8
#define F_DR 12
#define F_ERR 15

// Parser states.
enum {
  S_START = 0,
  S_PREF_OP_SIZE = 1,
  S_PREF_MULTI_BYTE_OP = 2,
  S_PARSE_FLAGS = 3,
  S_EXTRA_FLAGS = 4,
  S_READ_MODRM = 5,
  S_READ_OP3_38 = 6,
  S_READ_OP3_3A = 7,
  S_READ_SIB = 8,
  S_READ8 = 9,
  S_READ16 = 10,
  S_READ32 = 11,
  S_READ8_MODRM = 12,
  S_READ16F = 13,
  S_READ32_MODRM = 14,
  S_ERROR = 15,
};

#define OP_GEN_BRANCH 12

#define CODE_SHIFT 3
#define CODE_MASK ((i64)0xFF << CODE_SHIFT)
#define CLEAR_CODE_MASK ((i64)0xFFFFFFFF ^ CODE_MASK)
#define PREFIX_MASK (((i64)1 << CODE_SHIFT) - 1)
#define OPERAND_SIZE_OVERRIDE ((i64)0x01 << (8 + CODE_SHIFT))
#define MULTI_BYTE_OPCODE ((i64)0x02 << (8 + CODE_SHIFT))
#define PREFIX_REX ((i64)0x04 << (8 + CODE_SHIFT))
#define PREFIX_38 ((i64)0x08 << (8 + CODE_SHIFT))
#define PREFIX_3A ((i64)0x10 << (8 + CODE_SHIFT))
#define HAS_EXTRA_FLAGS ((i64)0x20 << (8 + CODE_SHIFT))
#define HAS_MODRM ((i64)0x40 << (8 + CODE_SHIFT))
#define MODRM_SHIFT (7 + 8 + CODE_SHIFT)
#define SIB_SCALE_SHIFT (MODRM_SHIFT + 8 - 6)
#define REG_DWORD_DISPLACEMENT ((i64)1 << (8 + SIB_SCALE_SHIFT))
#define ADDRESS_MODE ((i64)2 << (8 + SIB_SCALE_SHIFT))
#define TYPE_SHIFT (2 + 8 + SIB_SCALE_SHIFT)
#define CATEGORY_SHIFT 5
#define CATEGORY_MASK (((i64)1 << CATEGORY_SHIFT) - 1)
#define MODRM_MOD 0xC0
#define MODRM_REG 0x38
#define MODRM_RM 0x07
#define SIB_SCALE 0xC0
#define SIB_BASE 0x07
#define REX_W 0x08
#define NCM1 10
#define SCALE 128

static const u8 kTable1[256] = {
    2, 2, 2, 2, 4, 12, 0, 0, 2, 2, 2, 2, 4, 12, 0, 0,
    2, 2, 2, 2, 4, 12, 0, 0, 2, 2, 2, 2, 4, 12, 0, 0,
    2, 2, 2, 2, 4, 12, 0, 0, 2, 2, 2, 2, 4, 12, 0, 0,
    2, 2, 2, 2, 4, 12, 0, 0, 2, 2, 2, 2, 4, 12, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 2, 2, 0, 0, 0, 0, 12, 14, 4, 6, 0, 0, 0, 0,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    6, 14, 6, 6, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 0, 0, 0, 0, 4, 12, 0, 0, 0, 0, 0, 0,
    4, 4, 4, 4, 4, 4, 4, 4, 12, 12, 12, 12, 12, 12, 12, 12,
    6, 6, 8, 0, 2, 2, 6, 14, 4, 0, 8, 0, 0, 4, 15, 0,
    2, 2, 2, 2, 4, 4, 0, 0, 2, 2, 2, 2, 2, 2, 2, 2,
    9, 9, 9, 9, 4, 4, 4, 4, 13, 13, 1, 9, 0, 0, 0, 0,
    0, 15, 0, 0, 0, 0, 3, 3, 0, 0, 0, 0, 0, 0, 3, 3,
};

static const u8 kTable2[256] = {
    15, 15, 15, 15, 15, 15, 0, 15, 0, 0, 15, 15, 15, 15, 15, 15,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 15, 15, 15, 15, 15, 15, 15,
    2, 2, 2, 2, 15, 15, 15, 15, 2, 2, 2, 2, 2, 2, 2, 2,
    0, 0, 0, 0, 0, 0, 15, 0, 15, 15, 15, 15, 15, 15, 15, 15,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    6, 6, 6, 6, 2, 2, 2, 0, 15, 15, 15, 15, 15, 15, 2, 2,
    13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    0, 0, 0, 2, 6, 2, 2, 2, 15, 15, 15, 2, 6, 2, 15, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 15, 15, 15, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 15,
};

static const u8 kTable338[256] = {
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 15, 15, 15, 15,
    2, 15, 15, 15, 2, 2, 15, 2, 15, 15, 15, 15, 2, 2, 2, 15,
    2, 2, 2, 2, 2, 2, 15, 15, 2, 2, 2, 2, 15, 15, 15, 15,
    2, 2, 2, 2, 2, 2, 15, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    2, 2, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    2, 2, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
};

static const u8 kTable33A[256] = {
    15, 15, 15, 15, 15, 15, 15, 15, 6, 6, 6, 6, 6, 6, 6, 6,
    15, 15, 15, 15, 6, 6, 6, 6, 15, 15, 15, 15, 15, 15, 15, 15,
    6, 6, 6, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    6, 6, 6, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    6, 6, 6, 6, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
};

static const u8 kTableX[32] = {
    6, 15, 2, 2, 2, 2, 2, 2, 14, 15, 2, 2, 2, 2, 2, 2,
    2, 2, 15, 15, 15, 15, 15, 15, 2, 2, 2, 15, 2, 15, 2, 15,
};

static const u8 kTypeOp1[256] = {
    8, 8, 8, 8, 8, 8, 5, 5, 9, 9, 9, 9, 9, 9, 5, 2,
    8, 8, 8, 8, 8, 8, 5, 5, 8, 8, 8, 8, 8, 8, 5, 5,
    9, 9, 9, 9, 9, 9, 1, 7, 8, 8, 8, 8, 8, 8, 1, 7,
    9, 9, 9, 9, 9, 9, 1, 7, 8, 8, 8, 8, 8, 8, 1, 7,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 14, 6, 1, 1, 2, 2, 5, 8, 5, 8, 16, 16, 16, 16,
    13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
    8, 8, 8, 8, 8, 8, 4, 4, 4, 4, 4, 4, 4, 4, 4, 5,
    4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 12, 3, 5, 5, 4, 4,
    4, 4, 4, 4, 15, 15, 15, 15, 9, 9, 15, 15, 15, 15, 15, 15,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    10, 10, 12, 12, 4, 4, 4, 4, 5, 5, 12, 12, 14, 14, 14, 14,
    10, 10, 10, 10, 7, 7, 4, 4, 22, 21, 22, 21, 22, 21, 22, 21,
    13, 13, 13, 13, 16, 16, 16, 16, 12, 12, 12, 12, 16, 16, 16, 16,
    2, 14, 2, 2, 20, 17, 8, 8, 17, 17, 17, 17, 17, 17, 8, 12,
};

static const u8 kTypeOp2[256] = {
    20, 20, 20, 20, 0, 20, 20, 20, 20, 20, 0, 19, 0, 19, 0, 0,
    31, 31, 31, 31, 30, 30, 31, 31, 30, 19, 19, 19, 19, 19, 19, 19,
    20, 20, 20, 20, 20, 0, 20, 0, 31, 31, 30, 30, 30, 30, 30, 30,
    20, 20, 20, 20, 20, 20, 0, 0, 2, 0, 2, 0, 0, 0, 0, 0,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    31, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
    29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 0, 0, 29, 29,
    30, 29, 29, 29, 29, 29, 29, 29, 0, 0, 0, 0, 0, 0, 29, 29,
    13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    5, 5, 19, 11, 10, 10, 0, 0, 5, 5, 20, 11, 10, 10, 28, 8,
    4, 4, 4, 11, 4, 4, 6, 6, 0, 19, 11, 11, 11, 11, 6, 6,
    4, 4, 30, 30, 30, 30, 30, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    0, 29, 29, 29, 30, 29, 0, 30, 29, 29, 30, 29, 29, 29, 30, 29,
    30, 29, 30, 29, 30, 29, 0, 30, 29, 29, 30, 29, 29, 29, 30, 29,
    0, 29, 29, 29, 30, 29, 30, 30, 29, 29, 29, 30, 29, 29, 29, 0,
};

static const u8 kTypeOp338[256] = {
    30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 0, 0, 0, 0,
    30, 0, 0, 0, 30, 30, 0, 30, 0, 0, 0, 0, 30, 30, 30, 0,
    30, 30, 30, 30, 30, 30, 0, 0, 30, 30, 30, 30, 0, 0, 0, 0,
    30, 30, 30, 30, 30, 30, 0, 30, 30, 30, 30, 30, 30, 30, 30, 30,
    30, 30, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    4, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
};

static const u8 kTypeOp33A[256] = {
    0, 0, 0, 0, 0, 0, 0, 0, 30, 30, 30, 30, 30, 30, 30, 30,
    0, 0, 0, 0, 30, 30, 30, 30, 0, 0, 0, 0, 0, 0, 0, 0,
    30, 30, 30, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    30, 30, 30, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    30, 30, 30, 30, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
};

static const u8 kTypeOpX[32] = {
    9, 9, 9, 8, 8, 8, 8, 8, 9, 9, 9, 8, 8, 8, 8, 8,
    8, 8, 0, 0, 0, 0, 0, 0, 8, 8, 12, 12, 12, 12, 5, 0,
};

// Bit 0: invalid in x64, bit 1: a valid x64 prefix.
static u8 kX64Flags[256];
static int kX64FlagsBuilt = 0;

static void buildX64Flags(void) {
  if (kX64FlagsBuilt) return;
  static const u8 invalid[] = {0x06, 0x07, 0x16, 0x17, 0x1E, 0x1F, 0x27,
                               0x2F, 0x37, 0x3F, 0x60, 0x61, 0x62, 0x82,
                               0x9A, 0xD4, 0xD5, 0xD6, 0xEA};
  static const u8 prefixes[] = {0x26, 0x2E, 0x36, 0x3E, 0x9B, 0xF0, 0xF2, 0xF3};
  for (size_t i = 0; i < sizeof(invalid); i++) kX64Flags[invalid[i]] |= 1;
  for (size_t i = 0; i < sizeof(prefixes); i++) kX64Flags[prefixes[i]] |= 2;
  for (int p = 0x40; p <= 0x4F; p++) kX64Flags[p] |= 2;
  for (int p = 0x64; p <= 0x67; p++) kX64Flags[p] |= 2;
  kX64FlagsBuilt = 1;
}

static const i64 kSizesFull[6] = {1024, 1024, 1024, 8192, 8192, 8192};

static void x86_mix(ZModel *self, ZState *s, Mixer *m);
static void x86_setCtx(ZModel *self, ZState *s, Mixer *m);

void x86model_init(X86Model *m, i64 bytes, int full) {
  buildX64Flags();
  memset(m, 0, sizeof(*m));
  contextmap_init(&m->cm, bytes, 20, full, full);
  m->im = ZNEW(u8, 1 << 20);
  statemap_init(&m->imSm, 256, 1023, 1);
  zrandom_init(&m->rnd);
  m->pState = m->state = S_START;
  m->full = full;
  m->base.inputs = m->cm.nCtx * contextmap_inputsPerContext(&m->cm) + 2;
  m->base.mix = x86_mix;
  m->base.nsel = full ? 6 : 3;
  m->base.selSizes = kSizesFull;
  m->base.setCtx = x86_setCtx;
}

static void clearOp(X86Model *m) {
  m->data = m->prefix = m->code = m->modRM = m->sib = m->rex = 0;
  m->flags = m->bytesRead = m->category = 0;
  m->mustCheckRex = m->decoding = m->o16 = m->imm8 = 0;
}

ZINLINE int isInvalidX64Op(i64 op) { return (kX64Flags[op] & 1) != 0; }
ZINLINE int isValidX64Prefix(i64 p) { return (kX64Flags[p] & 2) != 0; }
ZINLINE i64 opN(X86Model *m, i64 n) {
  return m->cache[(m->cacheIndex - n) & 31];
}

// processMode
static void processMode(X86Model *m) {
  if ((m->flags & F_MODE) == F_AM) {
    m->data |= ADDRESS_MODE;
    m->bytesRead = 0;
    switch (m->flags & F_TYPE) {
      case F_DR:
        m->data |= (i64)2 << TYPE_SHIFT;
        m->data |= (i64)1 << TYPE_SHIFT;
        m->state = S_READ32;
        break;
      case F_DA:
        m->data |= (i64)1 << TYPE_SHIFT;
        m->state = S_READ32;
        break;
      case F_AD:
        m->state = S_READ32;
        break;
      case F_BR:
        m->data |= (i64)2 << TYPE_SHIFT;
        m->state = S_READ8;
        break;
    }
  } else {
    switch (m->flags & F_TYPE) {
      case F_BI:
        m->state = S_READ8;
        break;
      case F_WI:
        m->state = S_READ16;
        m->data |= (i64)1 << TYPE_SHIFT;
        m->bytesRead = 0;
        break;
      case F_DI:
        m->imm8 = (m->rex & REX_W) > 0 && (m->code & 0xF8) == 0xB8;
        if (!m->o16 || m->imm8) {
          m->state = S_READ32;
          m->data |= (i64)2 << TYPE_SHIFT;
        } else {
          m->state = S_READ16;
          m->data |= (i64)3 << TYPE_SHIFT;
        }
        m->bytesRead = 0;
        break;
      default:
        m->state = S_START;
    }
  }
  m->data &= 0xFFFFFFFF;
}

// processFlags2
static void processFlags2(X86Model *m) {
  if ((m->flags & F_MODE) == F_MR && m->state != S_EXTRA_FLAGS) {
    m->state = S_READ_MODRM;
    return;
  }
  processMode(m);
}

// processFlags
static void processFlags(X86Model *m) {
  if (m->code == 0x9A || m->code == 0xEA || m->code == 0xC8) {
    m->bytesRead = 0;
    m->state = S_READ16F;
    return;
  }
  processFlags2(m);
}

// checkFlags
static void checkFlags(X86Model *m) {
  if (m->flags == F_MEXTRA) {
    m->state = S_EXTRA_FLAGS;
  } else if (m->flags == F_ERR) {
    clearOp(m);
    m->state = S_ERROR;
  } else {
    processFlags(m);
  }
}

static void readFlags(X86Model *m) {
  m->flags = kTable1[m->code];
  m->category = kTypeOp1[m->code];
  checkFlags(m);
}

static void processModRm(X86Model *m) {
  if ((m->modRM & MODRM_MOD) == 0x40) {
    m->state = S_READ8_MODRM;
  } else if ((m->modRM & MODRM_MOD) == 0x80 ||
             (m->modRM & (MODRM_MOD | MODRM_RM)) == 0x05 ||
             (m->modRM < 0x40 && (m->sib & SIB_BASE) == 0x05)) {
    m->state = S_READ32_MODRM;
    m->bytesRead = 0;
  } else {
    processMode(m);
  }
}

static void applyCodeAndSetFlag(X86Model *m, i64 flag) {
  m->data &= CLEAR_CODE_MASK;
  m->data = (m->data | (m->code << CODE_SHIFT) | flag) & 0xFFFFFFFF;
}

static i64 pref(ZState *s, i64 i) {
  if (i > s->pos) return 0;
  i64 b = zstate_back(s, i);
  return (b == 0x0F ? 1 : 0) + 2 * (b == 0x66 ? 1 : 0) +
         3 * (b == 0x67 ? 1 : 0);
}

ZINLINE i64 byteAt(ZState *s, i64 k) {
  return k <= s->pos ? zstate_back(s, k) : 0;
}

// exeCxt
static i64 exeCxt(ZState *s, i64 i, i64 x) {
  i64 prefix = 0, opcode = 0, modRm = 0, sib = 0;
  if (i != 0) prefix += 4 * pref(s, i--);
  if (i != 0) prefix += pref(s, i--);
  if (i != 0) opcode += byteAt(s, i--);
  if (i != 0) modRm += byteAt(s, i--) & (MODRM_MOD | MODRM_RM);
  if (i != 0 && (modRm & MODRM_RM) == 4 && modRm < MODRM_MOD) {
    sib = byteAt(s, i) & SIB_SCALE;
  }
  return (prefix | (opcode << 4) | (modRm << 12) | (x << 20) |
          (sib << (28 - 6))) &
         0xFFFFFFFF;
}

// ExeModel::update (once per byte)
static void update(X86Model *m, ZState *s) {
  i64 c1 = s->c4 & 255;
  m->pState = m->state;
  switch (m->state) {
    case S_START:
    case S_ERROR: {
      int skip = 0;
      if (m->mustCheckRex) {
        m->mustCheckRex = 0;
        if (!isInvalidX64Op(c1) && !isValidX64Prefix(c1)) {
          m->rex = m->code;
          m->code = c1;
          m->data = PREFIX_REX | (m->code << CODE_SHIFT) |
                    (m->data & PREFIX_MASK);
          skip = 1;
        }
      }
      m->modRM = m->sib = m->rex = m->flags = m->bytesRead = 0;
      int done = 0;
      if (!skip) {
        m->code = c1;
        m->mustCheckRex = (m->code & 0xF0) == 0x40 &&
                          !(m->decoding && (m->data & PREFIX_MASK) == 1);
        i64 cd = m->code;
        m->prefix =
            ((cd == 0x26 || cd == 0x2E || cd == 0x36 || cd == 0x3E) ? 1 : 0) +
            (cd == 0x64 ? 2 : 0) + (cd == 0x65 ? 3 : 0) +
            (cd == 0x67 ? 4 : 0) + (cd == 0x9B ? 5 : 0) +
            (cd == 0xF0 ? 6 : 0) + ((cd == 0xF2 || cd == 0xF3) ? 7 : 0);
        if (!m->decoding) {
          m->opMask =
              ((m->opMask << 1) | (m->state != S_ERROR ? 1 : 0)) & 0xFFFFFFFF;
          m->opCategoryMask =
              ((m->opCategoryMask << CATEGORY_SHIFT) | m->category) &
              0xFFFFFFFF;
          m->cache[m->cacheIndex & 31] = (u32)m->data;
          m->cacheIndex++;
          if (m->prefix == 0) {
            m->data = m->code << CODE_SHIFT;
          } else {
            m->data = m->prefix;
            m->category = kTypeOp1[m->code];
            m->decoding = 1;
            m->brkCtx =
                hash3(0, m->prefix, m->opCategoryMask & CATEGORY_MASK);
            done = 1;
          }
        } else {
          if (m->prefix == 0) {
            m->data |= m->code << CODE_SHIFT;
            m->decoding = 0;
          } else {
            m->data = m->prefix;
            m->category = kTypeOp1[m->code];
            m->brkCtx =
                hash3(1, m->prefix, m->opCategoryMask & CATEGORY_MASK);
            done = 1;
          }
        }
      }
      if (done) break;
      m->o16 = m->code == 0x66;
      if (m->o16) {
        m->state = S_PREF_OP_SIZE;
      } else if (m->code == 0x0F) {
        m->state = S_PREF_MULTI_BYTE_OP;
      } else {
        readFlags(m);
      }
      m->brkCtx =
          hash4(hash2(2, m->state), m->code, m->opCategoryMask & CATEGORY_MASK,
                opN(m, 1) & ((i64)(MODRM_MOD | MODRM_REG | MODRM_RM)
                             << MODRM_SHIFT));
      break;
    }
    case S_PREF_OP_SIZE:
      m->code = c1;
      applyCodeAndSetFlag(m, OPERAND_SIZE_OVERRIDE);
      readFlags(m);
      m->brkCtx = hash2(3, m->state);
      break;
    case S_PREF_MULTI_BYTE_OP:
      m->code = c1;
      m->data |= MULTI_BYTE_OPCODE;
      if (m->code == 0x38) {
        m->state = S_READ_OP3_38;
      } else if (m->code == 0x3A) {
        m->state = S_READ_OP3_3A;
      } else {
        applyCodeAndSetFlag(m, 0);
        m->flags = kTable2[m->code];
        m->category = kTypeOp2[m->code];
        checkFlags(m);
      }
      m->brkCtx = hash2(4, m->state);
      break;
    case S_PARSE_FLAGS:
      processFlags(m);
      m->brkCtx = hash2(5, m->state);
      break;
    case S_EXTRA_FLAGS:
    case S_READ_MODRM:
      m->modRM = c1;
      m->data =
          (m->data | (m->modRM << MODRM_SHIFT) | HAS_MODRM) & 0xFFFFFFFF;
      m->sib = 0;
      if (m->flags == F_MEXTRA) {
        m->data |= HAS_EXTRA_FLAGS;
        i64 i = ((m->modRM >> 3) & 0x07) | ((m->code & 0x01) << 3) |
                ((m->code & 0x08) << 1);
        m->flags = kTableX[i];
        m->category = kTypeOpX[i];
        if (m->flags == F_ERR) {
          clearOp(m);
          m->state = S_ERROR;
          m->brkCtx = hash2(6, m->state);
          break;
        }
        processFlags(m);
        m->brkCtx = hash2(7, m->state);
        break;
      }
      if ((m->modRM & MODRM_RM) == 4 && m->modRM < MODRM_MOD) {
        m->state = S_READ_SIB;
        m->brkCtx = hash2(8, m->state);
        break;
      }
      processModRm(m);
      m->brkCtx = hash3(9, m->state, m->code);
      break;
    case S_READ_OP3_38:
    case S_READ_OP3_3A:
      m->code = c1;
      applyCodeAndSetFlag(m, PREFIX_38 << (m->state - S_READ_OP3_38));
      if (m->state == S_READ_OP3_38) {
        m->flags = kTable338[m->code];
        m->category = kTypeOp338[m->code];
      } else {
        m->flags = kTable33A[m->code];
        m->category = kTypeOp33A[m->code];
      }
      checkFlags(m);
      m->brkCtx = hash2(10, m->state);
      break;
    case S_READ_SIB:
      m->sib = c1;
      m->data =
          (m->data | ((m->sib & SIB_SCALE) << SIB_SCALE_SHIFT)) & 0xFFFFFFFF;
      processModRm(m);
      m->brkCtx = hash3(11, m->state, m->sib & SIB_SCALE);
      break;
    case S_READ8:
    case S_READ16:
    case S_READ32: {
      if (++m->bytesRead >=
          ((m->state - S_READ8) << ((m->imm8 ? 1 : 0) + 1))) {
        m->bytesRead = 0;
        m->imm8 = 0;
        m->state = S_START;
      }
      i64 br = m->bytesRead;
      m->brkCtx = hash4(hash2(12, m->state), m->flags & F_MODE, br,
                        ((br > 1 && br <= s->pos) ? (zstate_back(s, br) << 8)
                                                  : 0) |
                            (br != 0 ? c1 : 0));
      break;
    }
    case S_READ8_MODRM:
      processMode(m);
      m->brkCtx = hash2(13, m->state);
      break;
    case S_READ16F:
      if (++m->bytesRead == 2) {
        m->bytesRead = 0;
        processFlags2(m);
      }
      m->brkCtx = hash2(14, m->state);
      break;
    case S_READ32_MODRM:
      m->data = (m->data | REG_DWORD_DISPLACEMENT) & 0xFFFFFFFF;
      if (++m->bytesRead == 4) {
        m->bytesRead = 0;
        processMode(m);
      }
      m->brkCtx = hash2(15, m->state);
      break;
  }
  m->context = (m->state + 16 * m->bytesRead + 16 * (m->rex & REX_W)) & 255;
  m->stateBh[m->context] =
      (u32)((((i64)m->stateBh[m->context] << 8) | c1) & 0xFFFFFFFF);

  // Contexts (the exe block is forced, as in paq8px for EXE blocks).
  ContextMap *cm = &m->cm;
  i64 mask = 0, count0 = 0, i = 0;
  while (i < NCM1) {
    if (i > 1) {
      mask = mask * 2 +
             ((i - 1 <= s->pos && zstate_back(s, i - 1) == 0) ? 1 : 0);
      count0 += mask & 1;
    }
    i64 j = i < 4 ? i + 1 : 5 + (i - 4) * (2 + (i > 6 ? 1 : 0));
    contextmap_set(
        cm, i,
        hash4(i, exeCxt(s, j, j > 6 ? c1 : 0),
              (((i64)1 << NCM1) | mask) * ((count0 * NCM1 / 2 >= i) ? 1 : 0),
              (0x08 | (s->pos & 7)) * (i < 4 ? 1 : 0)));
    i++;
  }
  contextmap_set(cm, i, m->brkCtx);
  i64 st = m->state + 16 * m->bytesRead;
  mask = PREFIX_MASK | ((i64)0xF8 << CODE_SHIFT) | MULTI_BYTE_OPCODE |
         PREFIX_38 | PREFIX_3A;
  ++i;
  contextmap_set(
      cm, i,
      hash4(hash2(i, opN(m, 1) & (mask | REG_DWORD_DISPLACEMENT | ADDRESS_MODE)),
            st, m->data & mask, (m->rex << 8) | m->category));
  mask = 0x04 | ((i64)0xFE << CODE_SHIFT) | MULTI_BYTE_OPCODE | PREFIX_38 |
         PREFIX_3A | ((i64)(MODRM_MOD | MODRM_REG) << MODRM_SHIFT);
  ++i;
  contextmap_set(
      cm, i,
      hash4(hash3(i, opN(m, 1) & mask, opN(m, 2) & mask), opN(m, 3) & mask,
            m->context + 256 * ((m->modRM & MODRM_MOD) == MODRM_MOD ? 1 : 0),
            m->data & ((mask | PREFIX_REX) ^ ((i64)MODRM_MOD << MODRM_SHIFT))));
  mask = 0x04 | CODE_MASK;
  ++i;
  contextmap_set(
      cm, i,
      hash4(hash3(i, opN(m, 1) & mask, opN(m, 2) & mask), opN(m, 3) & mask,
            opN(m, 4) & mask,
            (m->data & mask) | (m->state << 11) | (m->bytesRead << 15)));
  mask = 0x04 | ((i64)0xFC << CODE_SHIFT) | MULTI_BYTE_OPCODE | PREFIX_38 |
         PREFIX_3A;
  ++i;
  contextmap_set(
      cm, i,
      hash4(hash3(i, st, m->data & mask), m->category * 8 + (m->opMask & 0x07),
            m->flags,
            ((m->sib & SIB_BASE) == 5 ? 4 : 0) +
                ((m->modRM & MODRM_REG) == MODRM_REG ? 2 : 0) +
                ((m->modRM & MODRM_MOD) == 0 ? 1 : 0)));
  mask = PREFIX_MASK | CODE_MASK | OPERAND_SIZE_OVERRIDE | MULTI_BYTE_OPCODE |
         PREFIX_REX | PREFIX_38 | PREFIX_3A | HAS_EXTRA_FLAGS | HAS_MODRM |
         ((i64)(MODRM_MOD | MODRM_RM) << MODRM_SHIFT);
  ++i;
  contextmap_set(cm, i, hash4(i, m->data & mask, st, m->flags));
  mask = PREFIX_MASK | CODE_MASK | OPERAND_SIZE_OVERRIDE | MULTI_BYTE_OPCODE |
         PREFIX_38 | PREFIX_3A | HAS_EXTRA_FLAGS | HAS_MODRM;
  ++i;
  contextmap_set(
      cm, i,
      hash4(hash2(i, opN(m, 1) & mask), m->state,
            m->bytesRead * 2 + ((m->rex & REX_W) > 0 ? 1 : 0),
            m->data & ((mask ^ OPERAND_SIZE_OVERRIDE) & 0xFFFF)));
  mask = 0x04 | ((i64)0xFE << CODE_SHIFT) | MULTI_BYTE_OPCODE | PREFIX_38 |
         PREFIX_3A | ((i64)MODRM_REG << MODRM_SHIFT);
  ++i;
  contextmap_set(cm, i,
                 hash4(hash2(i, opN(m, 1) & mask), opN(m, 2) & mask, st,
                       m->data & (mask | PREFIX_MASK | CODE_MASK)));
  ++i;
  contextmap_set(cm, i, hash2(i, st));
  ++i;
  contextmap_set(
      cm, i,
      hash4(i, (0x100 | c1) * (m->bytesRead > 0 ? 1 : 0),
            m->state + 16 * m->pState + 256 * m->bytesRead,
            ((m->flags & F_MODE) == F_AM ? 16 : 0) + (m->rex & REX_W) +
                (m->o16 ? 4 : 0) + ((m->code & 0xFE) == 0xE8 ? 2 : 0) +
                (((m->data & MULTI_BYTE_OPCODE) != 0 &&
                  (m->code & 0xF0) == 0x80)
                     ? 1
                     : 0)));
}

static void x86_mix(ZModel *self, ZState *s, Mixer *mx) {
  X86Model *m = (X86Model *)self;
  i64 y = s->y;
  // IndirectMap update of the last bit.
  m->im[m->imIdx] = (u8)nextState(m->im[m->imIdx], y, &m->rnd);
  if (s->bpos == 0) update(m, s);
  i64 k0 = mx->nx;
  contextmap_mix(&m->cm, mx, y, s->bpos, s->c0, s->c4 & 255);
  i32 *t = mx->tx;
  for (i64 i = k0; i < mx->nx; i++) t[i] = (i32)(((i64)t[i] * SCALE) >> 6);
  // IndirectMap: a bit history per (break context, bit position).
  m->imIdx = hash2(m->brkCtx, s->bpos) & ((1 << 20) - 1);
  i64 state = m->im[m->imIdx];
  i64 k = mx->nx;
  i64 p1 = statemap_p(&m->imSm, y, state);
  if (state == 0) {
    t[k] = 0;
    t[k + 1] = 0;
  } else {
    t[k] = (i32)(((kStretch[p1] >> 1) * SCALE) >> 6);
    t[k + 1] = (i32)((((p1 - 2048) >> 2) * SCALE) >> 6);
  }
  mx->nx = k + 2;
}

static void x86_setCtx(ZModel *self, ZState *s, Mixer *mx) {
  X86Model *m = (X86Model *)self;
  i64 bpos = s->bpos;
  i64 c0 = s->c0;
  i64 bh = m->stateBh[m->context];
  i64 sb = ((bh >> (28 - bpos)) & 0x08) | ((bh >> (21 - bpos)) & 0x04) |
           ((bh >> (14 - bpos)) & 0x02) | ((bh >> (7 - bpos)) & 0x01) |
           (m->category == OP_GEN_BRANCH ? 16 : 0) |
           ((c0 & (((i64)1 << bpos) - 1)) == 0 ? 32 : 0);
  mixer_set(mx, (m->context * 4 + (sb >> 4)) & 1023);
  mixer_set(mx, (m->state * 64 + bpos * 8 + (m->bytesRead > 0 ? 4 : 0) +
                 (sb >> 4)) &
                    1023);
  mixer_set(mx, (m->brkCtx & 0x1FF) | ((sb & 0x20) << 4));
  if (!m->full) return;
  mixer_set(mx, hash3(m->code, m->state, opN(m, 1) & CODE_MASK) & 8191);
  mixer_set(mx, hash4(m->state, bpos, m->code, m->bytesRead) & 8191);
  mixer_set(mx, hash4(m->state, (bpos << 2) | (c0 & 3),
                      m->opCategoryMask & CATEGORY_MASK,
                      (m->category == OP_GEN_BRANCH ? 4 : 0) |
                          ((m->flags & F_MODE) == F_AM ? 2 : 0) |
                          (m->bytesRead > 0 ? 1 : 0)) &
                    8191);
}
