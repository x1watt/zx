// The engine of a zx self-extracting archive (.zx.sfx): runs the
// architecture independent decoder (zxsfx.wasm) with wasm3 and gives it a
// small set of host functions (module "zx"), not WASI.
//
//   engine <file> <offset> <length> <args for the decoder...>
//   engine -v
//
// The decoder is the [length] bytes at [offset] of [file] (the .zx.sfx
// itself; a length of 0 means the whole file). -v prints the version (the
// stub checks with it that the engine can run where it was written).
//
// Host functions return a negative errno on failure. Strings are NUL
// terminated pointers into the linear memory of the decoder.

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "wasm3/wasm3.h"

static int g_argc;
static char **g_argv;

static int fail(const char *what, const char *msg) {
  fprintf(stderr, "zx sfx: %s: %s\n", what, msg);
  return 2;
}

static int neg_errno(int r) { return r < 0 ? -errno : r; }

// Checks that [p, p + n) lies in the linear memory.
#define CHECK(p, n) m3ApiCheckMem(p, n)

// A NUL terminated string at p, inside the memory.
static const char *cstr(IM3Runtime runtime, const char *p, void *_mem) {
  uint32_t size = 0;
  uint8_t *mem = m3_GetMemory(runtime, &size, 0);
  const char *end = (const char *)mem + size;
  if (p < (const char *)mem || p >= end) return NULL;
  if (memchr(p, 0, end - p) == NULL) return NULL;
  (void)_mem;
  return p;
}

#define STR(name, p)                                                       \
  const char *name = cstr(runtime, p, _mem);                               \
  if (!name) m3ApiTrap(m3Err_trapOutOfBoundsMemoryAccess)

m3ApiRawFunction(h_argc) {
  m3ApiReturnType(int32_t);
  m3ApiReturn(g_argc);
}

// argv(i, buf, cap) -> length of argument i (copied when it fits, with
// its NUL), -1 when i is out of range.
m3ApiRawFunction(h_argv) {
  m3ApiReturnType(int32_t);
  m3ApiGetArg(int32_t, i);
  m3ApiGetArgMem(char *, buf);
  m3ApiGetArg(int32_t, cap);
  if (i < 0 || i >= g_argc) m3ApiReturn(-1);
  int32_t n = (int32_t)strlen(g_argv[i]);
  if (cap > n) {
    CHECK(buf, n + 1);
    memcpy(buf, g_argv[i], n + 1);
  }
  m3ApiReturn(n);
}

// open(path, mode): 0 read, 1 write (create or truncate), 2 write (create,
// fail if it exists). New files are 0600 until chmod.
m3ApiRawFunction(h_open) {
  m3ApiReturnType(int32_t);
  m3ApiGetArgMem(const char *, p);
  m3ApiGetArg(int32_t, mode);
  STR(path, p);
  int flags = O_RDONLY;
  if (mode == 1) flags = O_WRONLY | O_CREAT | O_TRUNC;
  if (mode == 2) flags = O_WRONLY | O_CREAT | O_EXCL;
  m3ApiReturn(neg_errno(open(path, flags | O_CLOEXEC | O_NOFOLLOW, 0600)));
}

m3ApiRawFunction(h_close) {
  m3ApiReturnType(int32_t);
  m3ApiGetArg(int32_t, fd);
  m3ApiReturn(fd > 2 ? neg_errno(close(fd)) : 0);
}

m3ApiRawFunction(h_pread) {
  m3ApiReturnType(int32_t);
  m3ApiGetArg(int32_t, fd);
  m3ApiGetArgMem(void *, buf);
  m3ApiGetArg(int32_t, n);
  m3ApiGetArg(int64_t, off);
  if (n < 0) m3ApiReturn(-EINVAL);
  CHECK(buf, n);
  int32_t done = 0;
  while (done < n) {
    ssize_t r = pread(fd, (char *)buf + done, n - done, off + done);
    if (r < 0 && errno == EINTR) continue;
    if (r < 0) m3ApiReturn(-errno);
    if (r == 0) break;
    done += (int32_t)r;
  }
  m3ApiReturn(done);
}

m3ApiRawFunction(h_write) {
  m3ApiReturnType(int32_t);
  m3ApiGetArg(int32_t, fd);
  m3ApiGetArgMem(const void *, buf);
  m3ApiGetArg(int32_t, n);
  if (n < 0) m3ApiReturn(-EINVAL);
  CHECK(buf, n);
  int32_t done = 0;
  while (done < n) {
    ssize_t r = write(fd, (const char *)buf + done, n - done);
    if (r < 0 && errno == EINTR) continue;
    if (r < 0) m3ApiReturn(-errno);
    done += (int32_t)r;
  }
  m3ApiReturn(done);
}

m3ApiRawFunction(h_fsize) {
  m3ApiReturnType(int64_t);
  m3ApiGetArg(int32_t, fd);
  struct stat st;
  if (fstat(fd, &st) < 0) m3ApiReturn(-errno);
  m3ApiReturn((int64_t)st.st_size);
}

m3ApiRawFunction(h_mkdir) {
  m3ApiReturnType(int32_t);
  m3ApiGetArgMem(const char *, p);
  m3ApiGetArg(int32_t, mode);
  STR(path, p);
  m3ApiReturn(neg_errno(mkdir(path, mode)));
}

m3ApiRawFunction(h_symlink) {
  m3ApiReturnType(int32_t);
  m3ApiGetArgMem(const char *, t);
  m3ApiGetArgMem(const char *, p);
  STR(target, t);
  STR(path, p);
  m3ApiReturn(neg_errno(symlink(target, path)));
}

m3ApiRawFunction(h_link) {
  m3ApiReturnType(int32_t);
  m3ApiGetArgMem(const char *, o);
  m3ApiGetArgMem(const char *, p);
  STR(old, o);
  STR(path, p);
  m3ApiReturn(neg_errno(link(old, path)));
}

m3ApiRawFunction(h_chmod) {
  m3ApiReturnType(int32_t);
  m3ApiGetArgMem(const char *, p);
  m3ApiGetArg(int32_t, mode);
  STR(path, p);
  m3ApiReturn(neg_errno(chmod(path, mode & 07777)));
}

// utime(path, mtime in ns since the epoch): of the link itself, not of its
// target.
m3ApiRawFunction(h_utime) {
  m3ApiReturnType(int32_t);
  m3ApiGetArgMem(const char *, p);
  m3ApiGetArg(int64_t, ns);
  STR(path, p);
  struct timespec ts[2];
  int64_t s = ns / 1000000000, r = ns % 1000000000;
  if (r < 0) { r += 1000000000; s--; }
  ts[0].tv_sec = ts[1].tv_sec = (time_t)s;
  ts[0].tv_nsec = ts[1].tv_nsec = (long)r;
  m3ApiReturn(neg_errno(utimensat(AT_FDCWD, path, ts, AT_SYMLINK_NOFOLLOW)));
}

m3ApiRawFunction(h_unlink) {
  m3ApiReturnType(int32_t);
  m3ApiGetArgMem(const char *, p);
  STR(path, p);
  int r = unlink(path);
  if (r < 0 && errno == EISDIR) r = rmdir(path);
  m3ApiReturn(neg_errno(r));
}

// kind(path): -ENOENT (or another error), 0 file, 1 directory, 2 symlink,
// 3 other. Does not follow a symlink.
m3ApiRawFunction(h_kind) {
  m3ApiReturnType(int32_t);
  m3ApiGetArgMem(const char *, p);
  STR(path, p);
  struct stat st;
  if (lstat(path, &st) < 0) m3ApiReturn(-errno);
  if (S_ISREG(st.st_mode)) m3ApiReturn(0);
  if (S_ISDIR(st.st_mode)) m3ApiReturn(1);
  if (S_ISLNK(st.st_mode)) m3ApiReturn(2);
  m3ApiReturn(3);
}

// password(prompt, buf, cap) -> length, read from the terminal without
// echo; the line end is dropped.
m3ApiRawFunction(h_password) {
  m3ApiReturnType(int32_t);
  m3ApiGetArgMem(const char *, pr);
  m3ApiGetArgMem(char *, buf);
  m3ApiGetArg(int32_t, cap);
  STR(prompt, pr);
  if (cap <= 0) m3ApiReturn(-EINVAL);
  CHECK(buf, cap);
  int fd = open("/dev/tty", O_RDWR | O_CLOEXEC);
  int in = fd >= 0 ? fd : 0, out = fd >= 0 ? fd : 2;
  if (write(out, prompt, strlen(prompt)) < 0) {}
  struct termios old, raw;
  int tty = tcgetattr(in, &old) == 0;
  if (tty) {
    raw = old;
    raw.c_lflag &= ~(ECHO | ECHONL);
    tcsetattr(in, TCSAFLUSH, &raw);
  }
  int32_t n = 0;
  char c;
  while (read(in, &c, 1) == 1 && c != '\n') {
    if (n < cap) buf[n++] = c;
  }
  if (n > 0 && buf[n - 1] == '\r') n--;
  if (tty) tcsetattr(in, TCSAFLUSH, &old);
  if (write(out, "\n", 1) < 0) {}
  if (fd >= 0) close(fd);
  m3ApiReturn(n);
}

m3ApiRawFunction(h_exit) {
  m3ApiGetArg(int32_t, code);
  fflush(stdout);
  _exit(code);
  m3ApiSuccess();
}

#define LINK(name, sig, fn)                                                \
  do {                                                                     \
    M3Result r_ = m3_LinkRawFunction(module, "zx", name, sig, fn);         \
    if (r_ && r_ != m3Err_functionLookupFailed) return fail("link", r_);   \
  } while (0)

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "-v") == 0) {
    puts("zx sfx engine 1 (wasm3 " M3_VERSION ")");
    return 0;
  }
  if (argc < 4) return fail("usage", "engine <file> <offset> <length> [args...]");
  g_argc = argc - 4;
  g_argv = argv + 4;

  FILE *f = fopen(argv[1], "rb");
  if (!f) return fail(argv[1], strerror(errno));
  long long off = atoll(argv[2]), size = atoll(argv[3]);
  if (size == 0) {
    fseek(f, 0, SEEK_END);
    size = ftell(f) - off;
  }
  uint8_t *wasm = malloc(size > 0 ? size : 1);
  if (off < 0 || size <= 0 || !wasm || fseeko(f, off, SEEK_SET) != 0 ||
      fread(wasm, 1, size, f) != (size_t)size) {
    return fail(argv[1], "can not read the decoder");
  }
  fclose(f);

  IM3Environment env = m3_NewEnvironment();
  IM3Runtime runtime = m3_NewRuntime(env, 1 << 20, NULL);
  IM3Module module;
  M3Result r = m3_ParseModule(env, &module, wasm, (uint32_t)size);
  if (r) return fail("parse", r);
  r = m3_LoadModule(runtime, module);
  if (r) return fail("load", r);

  LINK("argc", "i()", h_argc);
  LINK("argv", "i(i*i)", h_argv);
  LINK("open", "i(*i)", h_open);
  LINK("close", "i(i)", h_close);
  LINK("pread", "i(i*iI)", h_pread);
  LINK("write", "i(i*i)", h_write);
  LINK("fsize", "I(i)", h_fsize);
  LINK("mkdir", "i(*i)", h_mkdir);
  LINK("symlink", "i(**)", h_symlink);
  LINK("link", "i(**)", h_link);
  LINK("chmod", "i(*i)", h_chmod);
  LINK("utime", "i(*I)", h_utime);
  LINK("unlink", "i(*)", h_unlink);
  LINK("kind", "i(*)", h_kind);
  LINK("password", "i(**i)", h_password);
  LINK("exit", "v(i)", h_exit);

  IM3Function start;
  r = m3_FindFunction(&start, runtime, "_start");
  if (r) return fail("_start", r);
  r = m3_CallV(start);
  if (r) {
    M3ErrorInfo info;
    m3_GetErrorInfo(runtime, &info);
    return fail("run", info.message ? info.message : r);
  }
  int32_t code = 0;
  m3_GetResultsV(start, &code);
  fflush(stdout);
  return code;
}
