/*
 * zx-mount: the FUSE side of "zx mount" (docs/mount.md).
 *
 * One process per mounted archive. It holds no archive logic: every file
 * system request is sent as a message on standard output to the zx
 * program (lib/src/mount/fuse_bridge.dart), which answers on standard
 * input. Run it through "zx mount"; the protocol is private to the two.
 *
 *   zx-mount [--ro] [--allow-other] [--name NAME] MOUNTPOINT
 *
 * Standard output is the protocol: nothing else is printed to it. Messages
 * go to standard error.
 */

#define FUSE_USE_VERSION 31

#include <fuse.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

static struct fuse *g_fuse;
static void zx_rpc_dead(void) {
  if (g_fuse) fuse_exit(g_fuse);
}

#include "zx-rpc.h"

/* ---- operations ---- */

static uid_t g_uid;
static gid_t g_gid;
static int g_ro;

static int x_getattr(const char *path, struct stat *st, struct fuse_file_info *fi) {
  (void)fi;
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
  st->st_size = (off_t)size;
  st->st_blocks = (blkcnt_t)((size + 511) / 512);
  st->st_blksize = 4096;
  st->st_uid = g_uid;
  st->st_gid = g_gid;
  st->st_atime = st->st_mtime = st->st_ctime = (time_t)mtime;
  return 0;
}

static int x_readdir(const char *path, void *out, fuse_fill_dir_t fill, off_t off,
                     struct fuse_file_info *fi, enum fuse_readdir_flags fl) {
  (void)off; (void)fi; (void)fl;
  buf a = {0}, r;
  b_str(&a, path);
  int e = rpc(OP_READDIR, &a, &r);
  b_free(&a);
  if (e) { b_free(&r); return e; }
  fill(out, ".", NULL, 0, 0);
  fill(out, "..", NULL, 0, 0);
  uint32_t n = g_u32(&r);
  for (uint32_t i = 0; i < n && !r.bad; i++) {
    g_u8(&r); /* type: getattr tells it */
    char *name = g_str(&r);
    if (!name) break;
    fill(out, name, NULL, 0, 0);
    free(name);
  }
  int bad = r.bad;
  b_free(&r);
  return bad ? -EIO : 0;
}

static int x_open(const char *path, struct fuse_file_info *fi) {
  uint32_t flags = 0;
  if ((fi->flags & O_ACCMODE) != O_RDONLY) flags |= 1;
  if (fi->flags & O_TRUNC) flags |= 2;
  if ((flags & 1) && g_ro) return -EROFS;
  buf a = {0}, r;
  b_str(&a, path);
  b_u32(&a, flags);
  int e = rpc(OP_OPEN, &a, &r);
  b_free(&a);
  if (e) { b_free(&r); return e; }
  fi->fh = g_u64(&r);
  fi->keep_cache = !(flags & 1);
  b_free(&r);
  return 0;
}

static int x_create(const char *path, mode_t mode, struct fuse_file_info *fi) {
  if (g_ro) return -EROFS;
  buf a = {0}, r;
  b_str(&a, path);
  b_u32(&a, mode & 07777);
  int e = rpc(OP_CREATE, &a, &r);
  b_free(&a);
  if (e) { b_free(&r); return e; }
  fi->fh = g_u64(&r);
  b_free(&r);
  return 0;
}

static int x_read(const char *path, char *out, size_t size, off_t off,
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

static int x_write(const char *path, const char *data, size_t size, off_t off,
                   struct fuse_file_info *fi) {
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

/* One path in, status out. */
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
static int x_mkdir(const char *p, mode_t m) { (void)m; return path_op(OP_MKDIR, p); }

static int x_rename(const char *from, const char *to, unsigned int flags) {
  if (g_ro) return -EROFS;
  if (flags) return -EINVAL; /* RENAME_NOREPLACE, EXCHANGE: not supported */
  buf a = {0}, r;
  b_str(&a, from);
  b_str(&a, to);
  int e = rpc(OP_RENAME, &a, &r);
  b_free(&a);
  b_free(&r);
  return e;
}

static int x_truncate(const char *path, off_t size, struct fuse_file_info *fi) {
  (void)fi;
  if (g_ro) return -EROFS;
  buf a = {0}, r;
  b_str(&a, path);
  b_u64(&a, (uint64_t)size);
  int e = rpc(OP_TRUNCATE, &a, &r);
  b_free(&a);
  b_free(&r);
  return e;
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

static int x_statfs(const char *path, struct statvfs *s) {
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
static int x_chmod(const char *p, mode_t m, struct fuse_file_info *fi) { (void)p; (void)m; (void)fi; return 0; }
static int x_chown(const char *p, uid_t u, gid_t g, struct fuse_file_info *fi) { (void)p; (void)u; (void)g; (void)fi; return 0; }
static int x_utimens(const char *p, const struct timespec t[2], struct fuse_file_info *fi) { (void)p; (void)t; (void)fi; return 0; }

static void x_destroy(void *priv) {
  (void)priv;
  /* zx commits what is pending, then answers; its exit follows ours */
  buf r;
  rpc(OP_DESTROY, NULL, &r);
  b_free(&r);
}

static void *x_init(struct fuse_conn_info *conn, struct fuse_config *cfg) {
  (void)conn;
  cfg->use_ino = 0;
  cfg->kernel_cache = 0;
  cfg->entry_timeout = 1.0;
  cfg->attr_timeout = 1.0;
  cfg->negative_timeout = 0.0;
  g_fuse = fuse_get_context()->fuse;
  return NULL;
}

static const struct fuse_operations ops = {
  .init = x_init,
  .destroy = x_destroy,
  .getattr = x_getattr,
  .readdir = x_readdir,
  .open = x_open,
  .create = x_create,
  .read = x_read,
  .write = x_write,
  .release = x_release,
  .unlink = x_unlink,
  .rmdir = x_rmdir,
  .mkdir = x_mkdir,
  .rename = x_rename,
  .truncate = x_truncate,
  .fsync = x_fsync,
  .readlink = x_readlink,
  .statfs = x_statfs,
  .chmod = x_chmod,
  .chown = x_chown,
  .utimens = x_utimens,
};

int main(int argc, char **argv) {
  const char *mp = NULL, *name = "zx";
  int allow_other = 0;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--ro")) g_ro = 1;
    else if (!strcmp(argv[i], "--allow-other")) allow_other = 1;
    else if (!strcmp(argv[i], "--name") && i + 1 < argc) name = argv[++i];
    else if (argv[i][0] != '-' && !mp) mp = argv[i];
    else {
      fprintf(stderr, "usage: zx-mount [--ro] [--allow-other] [--name NAME] MOUNTPOINT\n");
      return 2;
    }
  }
  if (!mp) {
    fprintf(stderr, "usage: zx-mount [--ro] [--allow-other] [--name NAME] MOUNTPOINT\n");
    return 2;
  }
  g_uid = getuid();
  g_gid = getgid();
  char opts[600];
  snprintf(opts, sizeof opts, "fsname=%.200s,subtype=zx,default_permissions%s%s", name,
           g_ro ? ",ro" : "", allow_other ? ",allow_other" : "");
  char *fargv[] = {"zx-mount", "-f", "-s", "-o", opts, (char *)mp, NULL};
  return fuse_main(6, fargv, &ops, NULL);
}
