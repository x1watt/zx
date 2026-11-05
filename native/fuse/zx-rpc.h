/*
 * zx-rpc.h: the pipe protocol between a FUSE daemon (zx-mount.c on Linux,
 * zx-mount-fuse2.c on Windows and macOS) and the zx program
 * (lib/src/mount/fuse_bridge.dart). Private to the two; see docs/mount.md.
 *
 * Frames, little endian. Request: u32 length of the rest, u8 op, the
 * arguments. Response: u32 length of the rest, i32 status (0, or minus an
 * errno of Linux, translated here to the local value), the result.
 * Strings are u32 length and bytes. One request at a time (a lock).
 *
 * The including file defines zx_rpc_dead() (called once when the pipe
 * breaks: it should end the file system loop) before including this.
 */
#ifndef ZX_RPC_H
#define ZX_RPC_H

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <windows.h>
static CRITICAL_SECTION g_rpc_lock;
static void rpc_lock_init(void) {
  InitializeCriticalSection(&g_rpc_lock);
  _setmode(0, _O_BINARY);
  _setmode(1, _O_BINARY);
}
#define RPC_LOCK() EnterCriticalSection(&g_rpc_lock)
#define RPC_UNLOCK() LeaveCriticalSection(&g_rpc_lock)
#else
#include <pthread.h>
#include <unistd.h>
static pthread_mutex_t g_rpc_lock = PTHREAD_MUTEX_INITIALIZER;
__attribute__((unused)) static void rpc_lock_init(void) {}
#define RPC_LOCK() pthread_mutex_lock(&g_rpc_lock)
#define RPC_UNLOCK() pthread_mutex_unlock(&g_rpc_lock)
#endif

/* Linux errno numbers (the protocol's) to the local ones. */
static int zx_errno(int linux_errno) {
#ifdef _WIN32
  switch (linux_errno) {
    case 1: return EPERM;
    case 2: return ENOENT;
    case 5: return EIO;
    case 13: return EACCES;
    case 17: return EEXIST;
    case 20: return ENOTDIR;
    case 21: return EISDIR;
    case 22: return EINVAL;
    case 30: return EROFS;
    case 39: return ENOTEMPTY;
    default: return EIO;
  }
#else
  return linux_errno;
#endif
}

static void zx_rpc_dead(void);

enum {
  OP_GETATTR = 1, OP_READDIR, OP_OPEN, OP_CREATE, OP_READ, OP_WRITE,
  OP_RELEASE, OP_UNLINK, OP_RMDIR, OP_MKDIR, OP_RENAME, OP_TRUNCATE,
  OP_FSYNC, OP_READLINK, OP_STATFS, OP_DESTROY,
};

#define MAX_FRAME (64u << 20)

/* ---- buffers ---- */

typedef struct {
  uint8_t *p;
  size_t len, cap;
  size_t pos; /* read cursor */
  int bad;    /* a read went past the end */
} buf;

static void b_free(buf *b) { free(b->p); memset(b, 0, sizeof *b); }

static void b_put(buf *b, const void *d, size_t n) {
  if (b->len + n > b->cap) {
    size_t c = b->cap ? b->cap : 256;
    while (c < b->len + n) c *= 2;
    b->p = realloc(b->p, c);
    if (!b->p) { perror("zx-mount: realloc"); exit(1); }
    b->cap = c;
  }
  if (n) memcpy(b->p + b->len, d, n);
  b->len += n;
}
static void b_u8(buf *b, uint8_t v) { b_put(b, &v, 1); }
static void b_u32(buf *b, uint32_t v) {
  uint8_t t[4] = {v, v >> 8, v >> 16, v >> 24};
  b_put(b, t, 4);
}
static void b_u64(buf *b, uint64_t v) {
  b_u32(b, (uint32_t)v);
  b_u32(b, (uint32_t)(v >> 32));
}
static void b_str(buf *b, const char *s) {
  size_t n = strlen(s);
  b_u32(b, (uint32_t)n);
  b_put(b, s, n);
}

static uint32_t g_u32(buf *b) {
  if (b->pos + 4 > b->len) { b->bad = 1; return 0; }
  const uint8_t *t = b->p + b->pos;
  b->pos += 4;
  return t[0] | (uint32_t)t[1] << 8 | (uint32_t)t[2] << 16 | (uint32_t)t[3] << 24;
}
static uint64_t g_u64(buf *b) {
  uint64_t lo = g_u32(b);
  return lo | (uint64_t)g_u32(b) << 32;
}
static uint8_t g_u8(buf *b) {
  if (b->pos + 1 > b->len) { b->bad = 1; return 0; }
  return b->p[b->pos++];
}
/* A string: copied to a new NUL terminated buffer (caller frees). */
static char *g_str(buf *b) {
  uint32_t n = g_u32(b);
  if (b->bad || b->pos + n > b->len) { b->bad = 1; return NULL; }
  char *s = malloc(n + 1);
  if (!s) { perror("zx-mount: malloc"); exit(1); }
  memcpy(s, b->p + b->pos, n);
  s[n] = 0;
  b->pos += n;
  return s;
}

/* ---- the pipe to zx ---- */

static int g_dead; /* the pipe broke: every request fails */

static int write_all(int fd, const void *d, size_t n) {
  const uint8_t *p = d;
  while (n) {
    ssize_t w = write(fd, p, n);
    if (w < 0) { if (errno == EINTR) continue; return -1; }
    p += w;
    n -= (size_t)w;
  }
  return 0;
}
static int read_all(int fd, void *d, size_t n) {
  uint8_t *p = d;
  while (n) {
    ssize_t r = read(fd, p, n);
    if (r < 0) { if (errno == EINTR) continue; return -1; }
    if (r == 0) return -1;
    p += r;
    n -= (size_t)r;
  }
  return 0;
}

/* Sends op and args, reads the response into resp (cursor after the
 * status). Returns 0 or minus an errno. */
static int rpc_locked(uint8_t op, buf *args, buf *resp) {
  memset(resp, 0, sizeof *resp);
  if (g_dead) return -EIO;
  buf f = {0};
  b_u32(&f, (uint32_t)(1 + (args ? args->len : 0)));
  b_u8(&f, op);
  if (args) b_put(&f, args->p, args->len);
  int bad = write_all(1, f.p, f.len);
  b_free(&f);
  uint8_t h[4];
  if (!bad) bad = read_all(0, h, 4);
  uint32_t n = 0;
  if (!bad) {
    n = h[0] | (uint32_t)h[1] << 8 | (uint32_t)h[2] << 16 | (uint32_t)h[3] << 24;
    if (n < 4 || n > MAX_FRAME) bad = 1;
  }
  if (!bad) {
    resp->p = malloc(n);
    if (!resp->p) bad = 1;
    else {
      resp->cap = resp->len = n;
      bad = read_all(0, resp->p, n);
    }
  }
  if (bad) {
    g_dead = 1;
    fprintf(stderr, "zx-mount: lost the zx program, unmounting\n");
    b_free(resp);
    zx_rpc_dead();
    return -EIO;
  }
  int32_t st = (int32_t)g_u32(resp);
  return st < 0 ? -zx_errno(-st) : st;
}

static int rpc(uint8_t op, buf *args, buf *resp) {
  RPC_LOCK();
  int r = rpc_locked(op, args, resp);
  RPC_UNLOCK();
  return r;
}


#endif
