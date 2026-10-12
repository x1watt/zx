// zxsfx decoder: the functions of the engine (module "zx", see
// engine/engine.c). Natively (tests) host_native.c implements them with
// libc. Errors are negative errno values.

#ifndef HOST_H
#define HOST_H

#include <stdint.h>

#ifdef __wasm__
#define HOST(name) __attribute__((import_module("zx"), import_name(#name)))
#else
#define HOST(name)
#endif

HOST(argc) int host_argc(void);
HOST(argv) int host_argv(int i, char *buf, int cap);
// mode: 0 read, 1 write (create or truncate), 2 write (create new).
HOST(open) int host_open(const char *path, int mode);
HOST(close) int host_close(int fd);
HOST(pread) int host_pread(int fd, void *buf, int n, int64_t off);
HOST(write) int host_write(int fd, const void *buf, int n);
HOST(fsize) int64_t host_fsize(int fd);
HOST(mkdir) int host_mkdir(const char *path, int mode);
HOST(symlink) int host_symlink(const char *target, const char *path);
HOST(link) int host_link(const char *old, const char *path);
HOST(chmod) int host_chmod(const char *path, int mode);
HOST(utime) int host_utime(const char *path, int64_t mtimeNs);
HOST(unlink) int host_unlink(const char *path);
// -errno, 0 file, 1 directory, 2 symlink, 3 other (not followed).
HOST(kind) int host_kind(const char *path);
HOST(password) int host_password(const char *prompt, char *buf, int cap);
HOST(exit) __attribute__((noreturn)) void host_exit(int code);

#endif
