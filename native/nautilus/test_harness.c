/*
 * Test harness of libzx-nautilus.so without Nautilus: loads the module the
 * way Nautilus does (GModule, nautilus_module_initialize with a
 * GTypeModule, nautilus_module_list_types), creates the menu provider and
 * asks it for the items of fake selections (a small NautilusFileInfo
 * implementation). Then activates an item and checks the command line the
 * fake launcher receives.
 *
 * Runs in a temporary HOME (set before GLib reads it), so the real
 * settings and installs of the user are not looked at, except the system
 * ones (/usr/bin/zx-gui, /opt/zx/zx-gui): when one of them exists the
 * checks that need "no launcher" and the activation are skipped.
 *
 * Usage: zx-nautilus-test path/to/libzx-nautilus.so
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <gio/gio.h>
#include <glib/gstdio.h>
#include <gmodule.h>
#include <nautilus-extension.h>

static int failures = 0;
static int checks = 0;

#define CHECK(cond, ...)                                                       \
    do                                                                         \
    {                                                                          \
        checks++;                                                              \
        if (!(cond))                                                           \
        {                                                                      \
            failures++;                                                        \
            fprintf (stderr, "FAIL %s:%d: ", __FILE__, __LINE__);              \
            fprintf (stderr, __VA_ARGS__);                                     \
            fputc ('\n', stderr);                                              \
        }                                                                      \
    } while (0)

/* ---- a GTypeModule that does nothing on load and unload ---- */

typedef struct
{
    GTypeModule parent;
} TestModule;
typedef struct
{
    GTypeModuleClass parent_class;
} TestModuleClass;

static GType test_module_get_type (void);
G_DEFINE_TYPE (TestModule, test_module, G_TYPE_TYPE_MODULE)

static gboolean
test_module_load (GTypeModule *m)
{
    return TRUE;
}
static void
test_module_unload (GTypeModule *m)
{
}
static void
test_module_class_init (TestModuleClass *klass)
{
    GTypeModuleClass *mc = G_TYPE_MODULE_CLASS (klass);
    mc->load = test_module_load;
    mc->unload = test_module_unload;
}
static void
test_module_init (TestModule *self)
{
}

/* ---- a fake NautilusFileInfo ---- */

typedef struct
{
    GObject parent;
    char *uri;
    char *mime;
    gboolean dir;
} FakeFile;
typedef struct
{
    GObjectClass parent_class;
} FakeFileClass;

static GType fake_file_get_type (void);
static void fake_file_iface_init (NautilusFileInfoInterface *iface);
G_DEFINE_TYPE_WITH_CODE (FakeFile, fake_file, G_TYPE_OBJECT,
                         G_IMPLEMENT_INTERFACE (NAUTILUS_TYPE_FILE_INFO, fake_file_iface_init))

static GFile *
ff_location (NautilusFileInfo *fi)
{
    return g_file_new_for_uri (((FakeFile *) fi)->uri);
}
static char *
ff_uri (NautilusFileInfo *fi)
{
    return g_strdup (((FakeFile *) fi)->uri);
}
static char *
ff_name (NautilusFileInfo *fi)
{
    g_autoptr (GFile) f = ff_location (fi);
    return g_file_get_basename (f);
}
static char *
ff_scheme (NautilusFileInfo *fi)
{
    return g_uri_parse_scheme (((FakeFile *) fi)->uri);
}
static char *
ff_mime (NautilusFileInfo *fi)
{
    return g_strdup (((FakeFile *) fi)->mime);
}
static gboolean
ff_is_dir (NautilusFileInfo *fi)
{
    return ((FakeFile *) fi)->dir;
}
static gboolean
ff_is_mime (NautilusFileInfo *fi, const char *m)
{
    return g_strcmp0 (((FakeFile *) fi)->mime, m) == 0;
}
static void
fake_file_iface_init (NautilusFileInfoInterface *iface)
{
    iface->get_location = ff_location;
    iface->get_uri = ff_uri;
    iface->get_name = ff_name;
    iface->get_uri_scheme = ff_scheme;
    iface->get_mime_type = ff_mime;
    iface->is_directory = ff_is_dir;
    iface->is_mime_type = ff_is_mime;
}
static void
fake_file_finalize (GObject *o)
{
    g_free (((FakeFile *) o)->uri);
    g_free (((FakeFile *) o)->mime);
    G_OBJECT_CLASS (fake_file_parent_class)->finalize (o);
}
static void
fake_file_class_init (FakeFileClass *klass)
{
    G_OBJECT_CLASS (klass)->finalize = fake_file_finalize;
}
static void
fake_file_init (FakeFile *self)
{
}

static const char *tmpdir;

/* A file of the temporary folder (or an URI when name has a scheme). */
static FakeFile *
fake (const char *name, const char *mime, gboolean dir)
{
    FakeFile *f = g_object_new (fake_file_get_type (), NULL);
    if (strstr (name, "://") != NULL)
    {
        f->uri = g_strdup (name);
    }
    else
    {
        g_autofree char *path = g_build_filename (tmpdir, name, NULL);
        f->uri = g_filename_to_uri (path, NULL, NULL);
    }
    f->mime = g_strdup (mime);
    f->dir = dir;
    return f;
}

static NautilusMenuProvider *provider;

/* The label of the single item for these files, or NULL for no item. The
 * item (when there is one) goes to *out_item when asked for. */
static char *
label_for (GList *files, NautilusMenuItem **out_item)
{
    GList *items = nautilus_menu_provider_get_file_items (provider, files);
    char *label = NULL;
    if (items == NULL)
        return NULL;
    CHECK (g_list_length (items) == 1, "one item expected, got %u", g_list_length (items));
    g_object_get (items->data, "label", &label, NULL);
    if (out_item != NULL)
        *out_item = g_object_ref (items->data);
    nautilus_menu_item_list_free (items);
    return label;
}

static char *
label1 (const char *name, const char *mime)
{
    FakeFile *f = fake (name, mime, FALSE);
    GList *l = g_list_append (NULL, f);
    char *label = label_for (l, NULL);
    g_list_free_full (l, g_object_unref);
    return label;
}

static void
expect1 (const char *name, const char *mime, const char *expected)
{
    g_autofree char *got = label1 (name, mime);
    CHECK (g_strcmp0 (got, expected) == 0, "%s (%s): expected %s, got %s", name,
           mime ? mime : "no mime", expected ? expected : "no item", got ? got : "no item");
}

static void
write_file (const char *path, const char *text, int mode)
{
    g_autoptr (GError) e = NULL;
    g_autofree char *dir = g_path_get_dirname (path);
    g_mkdir_with_parents (dir, 0755);
    if (!g_file_set_contents (path, text, -1, &e))
    {
        fprintf (stderr, "cannot write %s: %s\n", path, e->message);
        exit (2);
    }
    g_chmod (path, mode);
}

int
main (int argc, char **argv)
{
    g_autoptr (GError) error = NULL;
    GModule *so;
    void (*init) (GTypeModule *);
    void (*list) (const GType **, int *);
    void (*shutdown) (void);
    const GType *types = NULL;
    int ntypes = 0, i;
    GTypeModule *module;
    gboolean system_launcher;
    g_autofree char *home = NULL;
    g_autofree char *launcher = NULL;
    g_autofree char *flag = NULL;

    if (argc != 2)
    {
        fprintf (stderr, "usage: %s libzx-nautilus.so\n", argv[0]);
        return 2;
    }

    /* a temporary HOME before GLib reads it; no GVfs daemons */
    home = g_dir_make_tmp ("zx-nautilus-test-XXXXXX", &error);
    if (home == NULL)
    {
        fprintf (stderr, "%s\n", error->message);
        return 2;
    }
    g_setenv ("HOME", home, TRUE);
    g_unsetenv ("XDG_CONFIG_HOME");
    g_unsetenv ("XDG_DATA_HOME");
    g_setenv ("GIO_USE_VFS", "local", TRUE);
    tmpdir = home;
    launcher = g_build_filename (home, ".local", "bin", "zx-gui", NULL);
    flag = g_build_filename (home, ".config", "zx", "context-menu-disabled", NULL);
    system_launcher = g_file_test ("/usr/bin/zx-gui", G_FILE_TEST_EXISTS) ||
                      g_file_test ("/opt/zx/zx-gui", G_FILE_TEST_EXISTS);

    so = g_module_open (argv[1], G_MODULE_BIND_LOCAL);
    if (so == NULL)
    {
        fprintf (stderr, "cannot load %s: %s\n", argv[1], g_module_error ());
        return 1;
    }
    CHECK (g_module_symbol (so, "nautilus_module_initialize", (gpointer *) &init),
           "nautilus_module_initialize missing");
    CHECK (g_module_symbol (so, "nautilus_module_list_types", (gpointer *) &list),
           "nautilus_module_list_types missing");
    CHECK (g_module_symbol (so, "nautilus_module_shutdown", (gpointer *) &shutdown),
           "nautilus_module_shutdown missing");
    if (failures != 0)
        return 1;

    module = G_TYPE_MODULE (g_object_new (test_module_get_type (), NULL));
    g_type_module_use (module);
    init (module);
    list (&types, &ntypes);
    CHECK (ntypes == 1, "one type expected, got %d", ntypes);
    for (i = 0; i < ntypes; i++)
    {
        if (g_type_is_a (types[i], NAUTILUS_TYPE_MENU_PROVIDER))
            provider = g_object_new (types[i], NULL);
    }
    CHECK (provider != NULL, "no NautilusMenuProvider type");
    if (provider == NULL)
        return 1;
    printf ("loaded %s: type %s\n", argv[1], G_OBJECT_TYPE_NAME (provider));

    /* no zx installed: no item */
    if (!system_launcher)
        expect1 ("a.zip", "application/zip", NULL);

    write_file (launcher,
                "#!/bin/sh\n"
                "{ pwd; for a in \"$@\"; do echo \"$a\"; done; } > \"$HOME/args.tmp\"\n"
                "mv \"$HOME/args.tmp\" \"$HOME/args.txt\"\n",
                0755);

    /* names, MIME types, volumes */
    expect1 ("a.zip", "application/zip", "Extract to \"a/\"");
    expect1 ("a.tar.gz", "application/x-compressed-tar", "Extract to \"a/\"");
    expect1 ("A.TAR.GZ", NULL, "Extract to \"A/\"");
    expect1 ("a.tgz", NULL, "Extract to \"a/\"");
    expect1 ("a.tar.bz2", NULL, "Extract to \"a/\"");
    expect1 ("a.tar.xz", NULL, "Extract to \"a/\"");
    expect1 ("a.tar.lzma", NULL, "Extract to \"a/\"");
    expect1 ("a.tbz2", NULL, "Extract to \"a/\"");
    expect1 ("a.txz", NULL, "Extract to \"a/\"");
    expect1 ("a.tlz", NULL, "Extract to \"a/\"");
    expect1 ("a.tar", NULL, "Extract to \"a/\"");
    expect1 ("a.7z", NULL, "Extract to \"a/\"");
    expect1 ("a.rar", NULL, "Extract to \"a/\"");
    expect1 ("a.jar", NULL, "Extract to \"a/\"");
    expect1 ("a.apk", NULL, "Extract to \"a/\"");
    expect1 ("report.docx", NULL, "Extract to \"report/\"");
    expect1 ("notes.txt.gz", "application/gzip", "Extract to \"notes.txt/\"");
    expect1 ("notes.txt.bz2", NULL, "Extract to \"notes.txt/\"");
    expect1 ("notes.txt.xz", NULL, "Extract to \"notes.txt/\"");
    expect1 ("notes.txt.lzma", NULL, "Extract to \"notes.txt/\"");
    expect1 ("old.lzh", NULL, "Extract to \"old/\"");
    expect1 ("old.LHA", NULL, "Extract to \"old/\"");
    expect1 ("old.arj", NULL, "Extract to \"old/\"");
    expect1 ("big.7z.001", NULL, "Extract to \"big/\"");
    expect1 ("big.001", NULL, "Extract to \"big/\"");
    expect1 ("big.7z.002", NULL, NULL);
    expect1 ("big.part1.rar", "application/vnd.rar", "Extract to \"big/\"");
    expect1 ("big.part01.rar", "application/vnd.rar", "Extract to \"big/\"");
    expect1 ("big.part001.rar", "application/vnd.rar", "Extract to \"big/\"");
    expect1 ("big.part2.rar", "application/vnd.rar", NULL);
    expect1 ("big.part10.rar", "application/vnd.rar", NULL);
    expect1 ("big.r00", "application/vnd.rar", NULL);
    expect1 ("no_extension", "application/zip", "Extract to \"no__extension/\"");
    expect1 ("my_file.zip", NULL, "Extract to \"my__file/\"");
    expect1 ("photo.jpg", "image/jpeg", NULL);
    expect1 ("readme.txt", "text/plain", NULL);
    expect1 ("sftp://host/a.zip", "application/zip", NULL);

    /* a folder */
    {
        GList *l = g_list_append (NULL, fake ("a.zip", "inode/directory", TRUE));
        g_autofree char *got = label_for (l, NULL);
        CHECK (got == NULL, "folder: expected no item, got %s", got);
        g_list_free_full (l, g_object_unref);
    }
    /* several archives, and a mix */
    {
        GList *l = NULL;
        g_autofree char *got = NULL;
        g_autofree char *got2 = NULL;
        l = g_list_append (l, fake ("a.zip", "application/zip", FALSE));
        l = g_list_append (l, fake ("b.tar.gz", NULL, FALSE));
        got = label_for (l, NULL);
        CHECK (g_strcmp0 (got, "Extract each to its own folder") == 0, "two archives: got %s",
               got ? got : "no item");
        l = g_list_append (l, fake ("c.txt", "text/plain", FALSE));
        got2 = label_for (l, NULL);
        CHECK (got2 == NULL, "archive and text: expected no item, got %s", got2);
        g_list_free_full (l, g_object_unref);
    }
    /* the setting of zx switched the item off */
    write_file (flag, "", 0644);
    expect1 ("a.zip", "application/zip", NULL);
    g_unlink (flag);
    expect1 ("a.zip", "application/zip", "Extract to \"a/\"");

    /* activation starts the launcher, in the folder of the archive */
    if (system_launcher)
    {
        printf ("skipped the activation: a system install of zx exists\n");
    }
    else
    {
        GList *l = NULL;
        NautilusMenuItem *item = NULL;
        g_autofree char *got = NULL;
        g_autofree char *args = NULL;
        g_autofree char *args_file = g_build_filename (home, "args.txt", NULL);
        g_autofree char *expected = NULL;
        g_autofree char *pa = g_build_filename (home, "a b.zip", NULL);
        g_autofree char *pb = g_build_filename (home, "c'd.7z", NULL);
        int waited;

        l = g_list_append (l, fake ("a b.zip", "application/zip", FALSE));
        l = g_list_append (l, fake ("c'd.7z", NULL, FALSE));
        got = label_for (l, &item);
        g_list_free_full (l, g_object_unref);
        CHECK (item != NULL, "no item to activate");
        if (item != NULL)
        {
            nautilus_menu_item_activate (item);
            for (waited = 0; waited < 100 && !g_file_test (args_file, G_FILE_TEST_EXISTS); waited++)
                g_usleep (50000);
            g_file_get_contents (args_file, &args, NULL, NULL);
            expected = g_strdup_printf ("%s\n--extract-to-folder\n%s\n%s\n", home, pa, pb);
            CHECK (g_strcmp0 (args, expected) == 0, "launcher got:\n%s\nexpected:\n%s",
                   args ? args : "(nothing)", expected);
            g_object_unref (item);
        }
    }

    g_object_unref (provider);
    shutdown ();

    /* clean the temporary HOME */
    {
        g_autofree char *cmd = g_strdup_printf ("rm -rf '%s'", home);
        if (system (cmd) != 0)
            fprintf (stderr, "could not remove %s\n", home);
    }
    printf ("%d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
