// zxsfx decoder: the host functions with libc, for the native test build
// (the self-extracting archive runs the wasm build in the engine).

#ifndef __wasm__
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "host.h"

static int g_argc;
static char **g_argv;

int zxsfx_main(void);

int main(int argc, char **argv) {
  g_argc = argc - 1;
  g_argv = argv + 1;
  return zxsfx_main();
}

static int ne(int r) { return r < 0 ? -errno : r; }

int host_argc(void) { return g_argc; }
int host_argv(int i, char *buf, int cap) {
  if (i < 0 || i >= g_argc) return -1;
  int n = (int)strlen(g_argv[i]);
  if (cap > n) memcpy(buf, g_argv[i], n + 1);
  return n;
}
int host_open(const char *path, int mode) {
  int flags = O_RDONLY;
  if (mode == 1) flags = O_WRONLY | O_CREAT | O_TRUNC;
  if (mode == 2) flags = O_WRONLY | O_CREAT | O_EXCL;
  return ne(open(path, flags | O_CLOEXEC | O_NOFOLLOW, 0600));
}
int host_close(int fd) { return fd > 2 ? ne(close(fd)) : 0; }
int host_pread(int fd, void *buf, int n, int64_t off) {
  int done = 0;
  while (done < n) {
    ssize_t r = pread(fd, (char *)buf + done, n - done, off + done);
    if (r < 0 && errno == EINTR) continue;
    if (r < 0) return -errno;
    if (r == 0) break;
    done += (int)r;
  }
  return done;
}
int host_write(int fd, const void *buf, int n) {
  int done = 0;
  while (done < n) {
    ssize_t r = write(fd, (const char *)buf + done, n - done);
    if (r < 0 && errno == EINTR) continue;
    if (r < 0) return -errno;
    done += (int)r;
  }
  return done;
}
int64_t host_fsize(int fd) {
  struct stat st;
  return fstat(fd, &st) < 0 ? -errno : (int64_t)st.st_size;
}
int host_mkdir(const char *path, int mode) { return ne(mkdir(path, mode)); }
int host_symlink(const char *t, const char *p) { return ne(symlink(t, p)); }
int host_link(const char *o, const char *p) { return ne(link(o, p)); }
int host_chmod(const char *p, int mode) { return ne(chmod(p, mode & 07777)); }
int host_utime(const char *path, int64_t ns) {
  struct timespec ts[2];
  int64_t s = ns / 1000000000, r = ns % 1000000000;
  if (r < 0) { r += 1000000000; s--; }
  ts[0].tv_sec = ts[1].tv_sec = (time_t)s;
  ts[0].tv_nsec = ts[1].tv_nsec = (long)r;
  return ne(utimensat(AT_FDCWD, path, ts, AT_SYMLINK_NOFOLLOW));
}
int host_unlink(const char *path) {
  int r = unlink(path);
  if (r < 0 && errno == EISDIR) r = rmdir(path);
  return ne(r);
}
int host_kind(const char *path) {
  struct stat st;
  if (lstat(path, &st) < 0) return -errno;
  if (S_ISREG(st.st_mode)) return 0;
  if (S_ISDIR(st.st_mode)) return 1;
  if (S_ISLNK(st.st_mode)) return 2;
  return 3;
}
int host_password(const char *prompt, char *buf, int cap) {
  const char *p = getenv("ZXSFX_PASSWORD");
  if (p) {
    int n = (int)strlen(p);
    if (n > cap) n = cap;
    memcpy(buf, p, n);
    return n;
  }
  fputs(prompt, stderr);
  if (!fgets(buf, cap, stdin)) return 0;
  int n = (int)strlen(buf);
  while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) n--;
  return n;
}
void host_exit(int code) { exit(code); }
#endif
