/*
 * zx-mount-fuse2: the file system side of "zx mount" on Windows (WinFsp,
 * its FUSE compatible layer) and, with the same code, macOS (macFUSE).
 * The Linux daemon is zx-mount.c (libfuse 3); both speak the protocol of
 * zx-rpc.h to the zx program (docs/mount.md) and hold no archive logic.
 *
 *   zx-mount [--ro] [--name NAME] MOUNTPOINT
 *
 * MOUNTPOINT is a drive letter ("Z:") or a folder that does not exist yet
 * on Windows (WinFsp makes it), a folder on macOS. NAME is the volume name.
 * Standard output is the protocol: nothing else is printed to it.
 *
 * Built with MinGW against the WinFsp headers (tool/fetch_winfsp_headers.sh,
 * make -C native/fuse windows); it needs winfsp-x64.dll at run time (the
 * WinFsp installer).
 */

#define FUSE_USE_VERSION 28

#include <fuse.h>
#include <sys/stat.h>

#ifndef S_IFLNK
#define S_IFLNK 0120000
#endif
#ifndef S_IFDIR
#define S_IFDIR 0040000
#endif
#ifndef S_IFREG
#define S_IFREG 0100000
#endif

static struct fuse *g_fuse;
static void zx_rpc_dead(void) {
  if (g_fuse) fuse_exit(g_fuse);
}

#include "zx-rpc.h"

static int g_ro;

static int x_getattr(const char *path, struct fuse_stat *st) {
  buf a = {0}, r;
  b_str(&a, path);
  int e = rpc(OP_GETATTR, &a, &r);
  b_free(&a);
  if (e) { b_free(&r); return e; }
  uint8_t type = g_u8(&r);
  uint32_t mode = g_u32(&r);
  uint64_t size = g_u64(&r), mtime = g_u64(&r);
  uint32_t nlink = g_u32(&r);
  int bad = r.bad;
  b_free(&r);
  if (bad) return -EIO;
  memset(st, 0, sizeof *st);
  mode &= 07777;
  if (g_ro) mode &= ~0222u;
  st->st_mode = (type == 2 ? S_IFDIR : type == 3 ? S_IFLNK : S_IFREG) | mode;
  st->st_nlink = nlink;
  st->st_size = (fuse_off_t)size;
  st->st_blocks = (size + 511) / 512;
  st->st_blksize = 4096;
  st->st_atim.tv_sec = st->st_mtim.tv_sec = st->st_ctim.tv_sec =
      st->st_birthtim.tv_sec = (int32_t)mtime;
  return 0;
}

static int x_readdir(const char *path, void *out, fuse_fill_dir_t fill,
                     fuse_off_t off, struct fuse_file_info *fi) {
  (void)off; (void)fi;
  buf a = {0}, r;
  b_str(&a, path);
  int e = rpc(OP_READDIR, &a, &r);
  b_free(&a);
  if (e) { b_free(&r); return e; }
  fill(out, ".", NULL, 0);
  fill(out, "..", NULL, 0);
  uint32_t n = g_u32(&r);
  for (uint32_t i = 0; i < n && !r.bad; i++) {
    g_u8(&r); /* type: getattr tells it */
    char *name = g_str(&r);
    if (!name) break;
    fill(out, name, NULL, 0);
    free(name);
  }
  int bad = r.bad;
  b_free(&r);
  return bad ? -EIO : 0;
}

static int x_open(const char *path, struct fuse_file_info *fi) {
  uint32_t flags = 0;
  int acc = fi->flags & 3; /* O_ACCMODE */
  if (acc != 0) flags |= 1;
  if (fi->flags & 0x200) flags |= 2; /* O_TRUNC (Windows and Linux: octal 01000 / 0x200) */
  if ((flags & 1) && g_ro) return -EROFS;
  buf a = {0}, r;
  b_str(&a, path);
  b_u32(&a, flags);
  int e = rpc(OP_OPEN, &a, &r);
  b_free(&a);
  if (e) { b_free(&r); return e; }
  fi->fh = g_u64(&r);
  b_free(&r);
  return 0;
}

static int x_create(const char *path, fuse_mode_t mode, struct fuse_file_info *fi) {
  if (g_ro) return -EROFS;
  buf a = {0}, r;
  b_str(&a, path);
  b_u32(&a, (uint32_t)mode & 07777);
  int e = rpc(OP_CREATE, &a, &r);
  b_free(&a);
  if (e) { b_free(&r); return e; }
  fi->fh = g_u64(&r);
  b_free(&r);
  return 0;
}

static int x_read(const char *path, char *out, size_t size, fuse_off_t off,
                  struct fuse_file_info *fi) {
  (void)path;
  buf a = {0}, r;
  b_u64(&a, fi->fh);
  b_u64(&a, (uint64_t)off);
  b_u32(&a, (uint32_t)size);
  int e = rpc(OP_READ, &a, &r);
  b_free(&a);
  if (e) { b_free(&r); return e; }
  size_t n = r.len - r.pos;
  if (n > size) n = size;
  memcpy(out, r.p + r.pos, n);
  b_free(&r);
  return (int)n;
}

static int x_write(const char *path, const char *data, size_t size,
                   fuse_off_t off, struct fuse_file_info *fi) {
  (void)path;
  buf a = {0}, r;
  b_u64(&a, fi->fh);
  b_u64(&a, (uint64_t)off);
  b_u32(&a, (uint32_t)size);
  b_put(&a, data, size);
  int e = rpc(OP_WRITE, &a, &r);
  b_free(&a);
  if (e) { b_free(&r); return e; }
  uint32_t n = g_u32(&r);
  b_free(&r);
  return (int)n;
}

static int x_release(const char *path, struct fuse_file_info *fi) {
  (void)path;
  buf a = {0}, r;
  b_u64(&a, fi->fh);
  int e = rpc(OP_RELEASE, &a, &r);
  b_free(&a);
  b_free(&r);
  return e;
}

static int path_op(uint8_t op, const char *path) {
  if (g_ro) return -EROFS;
  buf a = {0}, r;
  b_str(&a, path);
  int e = rpc(op, &a, &r);
  b_free(&a);
  b_free(&r);
  return e;
}
static int x_unlink(const char *p) { return path_op(OP_UNLINK, p); }
static int x_rmdir(const char *p) { return path_op(OP_RMDIR, p); }
static int x_mkdir(const char *p, fuse_mode_t m) { (void)m; return path_op(OP_MKDIR, p); }

static int x_rename(const char *from, const char *to) {
  if (g_ro) return -EROFS;
  buf a = {0}, r;
  b_str(&a, from);
  b_str(&a, to);
  int e = rpc(OP_RENAME, &a, &r);
  b_free(&a);
  b_free(&r);
  return e;
}

static int x_truncate(const char *path, fuse_off_t size) {
  if (g_ro) return -EROFS;
  buf a = {0}, r;
  b_str(&a, path);
  b_u64(&a, (uint64_t)size);
  int e = rpc(OP_TRUNCATE, &a, &r);
  b_free(&a);
  b_free(&r);
  return e;
}

static int x_ftruncate(const char *path, fuse_off_t size, struct fuse_file_info *fi) {
  (void)fi;
  return x_truncate(path, size);
}

static int x_fsync(const char *path, int datasync, struct fuse_file_info *fi) {
  (void)path; (void)datasync; (void)fi;
  buf r;
  int e = rpc(OP_FSYNC, NULL, &r);
  b_free(&r);
  return e;
}

static int x_readlink(const char *path, char *out, size_t size) {
  buf a = {0}, r;
  b_str(&a, path);
  int e = rpc(OP_READLINK, &a, &r);
  b_free(&a);
  if (e) { b_free(&r); return e; }
  char *t = g_str(&r);
  b_free(&r);
  if (!t) return -EIO;
  snprintf(out, size, "%s", t);
  free(t);
  return 0;
}

static int x_statfs(const char *path, struct fuse_statvfs *s) {
  (void)path;
  buf r;
  int e = rpc(OP_STATFS, NULL, &r);
  if (e) { b_free(&r); return e; }
  uint64_t files = g_u64(&r), bytes = g_u64(&r);
  b_free(&r);
  memset(s, 0, sizeof *s);
  s->f_bsize = s->f_frsize = 4096;
  s->f_blocks = (bytes + 4095) / 4096;
  s->f_files = files;
  s->f_namemax = 255;
  return 0;
}

/* Attributes zx does not store are accepted and ignored. */
static int x_chmod(const char *p, fuse_mode_t m) { (void)p; (void)m; return 0; }
static int x_chown(const char *p, fuse_uid_t u, fuse_gid_t g) { (void)p; (void)u; (void)g; return 0; }
static int x_utimens(const char *p, const struct fuse_timespec t[2]) { (void)p; (void)t; return 0; }
static int x_flush(const char *p, struct fuse_file_info *fi) { (void)p; (void)fi; return 0; }

static void x_destroy(void *priv) {
  (void)priv;
  /* zx commits what is pending, then answers; its exit follows ours */
  buf r;
  rpc(OP_DESTROY, NULL, &r);
  b_free(&r);
}

static void *x_init(struct fuse_conn_info *conn) {
  (void)conn;
  g_fuse = fuse_get_context()->fuse;
  return NULL;
}

static struct fuse_operations ops;

int main(int argc, char **argv) {
  const char *mp = NULL, *name = "zx";
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--ro")) g_ro = 1;
    else if (!strcmp(argv[i], "--name") && i + 1 < argc) name = argv[++i];
    else if (argv[i][0] != '-' && !mp) mp = argv[i];
    else mp = NULL, i = argc;
  }
  if (!mp) {
    fprintf(stderr, "usage: zx-mount [--ro] [--name NAME] MOUNTPOINT\n");
    return 2;
  }
  rpc_lock_init();
  ops.init = x_init;
  ops.destroy = x_destroy;
  ops.getattr = x_getattr;
  ops.readdir = x_readdir;
  ops.open = x_open;
  ops.create = x_create;
  ops.read = x_read;
  ops.write = x_write;
  ops.release = x_release;
  ops.flush = x_flush;
  ops.unlink = x_unlink;
  ops.rmdir = x_rmdir;
  ops.mkdir = x_mkdir;
  ops.rename = x_rename;
  ops.truncate = x_truncate;
  ops.ftruncate = x_ftruncate;
  ops.fsync = x_fsync;
  ops.readlink = x_readlink;
  ops.statfs = x_statfs;
  ops.chmod = x_chmod;
  ops.chown = x_chown;
  ops.utimens = x_utimens;

  char opts[600];
#ifdef _WIN32
  /* uid=-1,gid=-1: the files belong to the user who mounts; umask 022 */
  snprintf(opts, sizeof opts,
           "volname=%.30s,FileSystemName=zx,uid=-1,gid=-1,umask=022", name);
#else
  snprintf(opts, sizeof opts, "volname=%.30s,fsname=zx", name);
#endif
  char *fargv[] = {"zx-mount", "-f", "-o", opts, (char *)mp, NULL};
  return fuse_main(5, fargv, &ops, NULL);
}
