/*
 * zx-nautilus: the "Extract to "name/"" item of the Nautilus right-click
 * menu (Nautilus 43 and later, extensions-4 API).
 *
 * The item shows when every selected file is a local archive that zx
 * opens (by name or by MIME type; of a multi-volume set only the first
 * volume). Activating it starts
 *
 *     zx-gui --extract-to-folder <path>...
 *
 * without a shell. The program is the first one that exists of
 * /usr/bin/zx-gui (the package), ~/.local/bin/zx-gui (tool/install_linux.sh),
 * /opt/zx/zx_app and $XDG_DATA_HOME/zx/app/zx_app. Without one the item
 * does not show.
 *
 * The app's setting "Add Extract to folder to the file manager right-click
 * menu" writes $XDG_CONFIG_HOME/zx/context-menu-disabled when switched
 * off; while that file exists the item does not show. It is checked each
 * time the menu opens, so no restart of Nautilus is needed.
 *
 * The lists of extensions and MIME types and the folder name rules mirror
 * app/lib/src/formats.dart (kArchiveExtensions, kArchiveMimeTypes,
 * folderNameFor); app/test/nautilus_extension_test.dart checks that they
 * stay in step.
 */

#include <string.h>

#include <gio/gio.h>
#include <glib-object.h>
#include <glib.h>
#include <nautilus-extension.h>

/* Extensions of the archives the app opens (kArchiveExtensions). */
static const char *const zx_extensions[] = {
    "tar.gz", "tar.bz2", "tar.xz", "tar.lzma", "tar.bz", "tar.z",
    "7z", "zip", "jar", "war", "ear", "apk", "zipx", "rar", "tar",
    "tgz", "tbz", "tbz2", "tb2", "txz", "tlz",
    "gz", "bz2", "bz", "xz", "lzma", "lzh", "lha", "arj", "zpaq", "zx",
    "cbz", "cbr", "epub", "docx", "xlsx", "pptx", "odt", "ods", "odp",
    NULL,
};

/* Extensions that are only a compressor around another name. */
static const char *const zx_compressor_extensions[] = {
    "gz", "bz2", "bz", "xz", "lzma", "z", NULL,
};

/* The compound tar extensions, cut as a whole. */
static const char *const zx_compound_extensions[] = {
    "tar.gz", "tar.bz2", "tar.xz", "tar.lzma", "tar.bz", "tar.z", NULL,
};

/* The MIME types of the formats (kArchiveMimeTypes). */
static const char *const zx_mime_types[] = {
    "application/x-7z-compressed",
    "application/zip",
    "application/x-zip-compressed",
    "application/java-archive",
    "application/vnd.rar",
    "application/x-rar",
    "application/x-rar-compressed",
    "application/x-tar",
    "application/x-compressed-tar",
    "application/gzip",
    "application/x-gzip",
    "application/x-bzip2",
    "application/x-bzip",
    "application/x-bzip2-compressed-tar",
    "application/x-bzip-compressed-tar",
    "application/x-bzip1",
    "application/x-bzip1-compressed-tar",
    "application/x-xz",
    "application/x-xz-compressed-tar",
    "application/x-lzma",
    "application/x-lzma-compressed-tar",
    "application/x-lha",
    "application/x-lzh-compressed",
    "application/x-arj",
    "application/x-zpaq",
    "application/x-zx",
    NULL,
};

static gboolean
in_list (const char *const *list, const char *s)
{
    for (; *list != NULL; list++)
    {
        if (strcmp (*list, s) == 0)
            return TRUE;
    }
    return FALSE;
}

static gboolean
ends_with (const char *s, gsize len, const char *suffix)
{
    gsize n = strlen (suffix);
    return len >= n && memcmp (s + len - n, suffix, n) == 0;
}

/* Length of a ".NNN" suffix (3 digits) of low[0..len), else 0. */
static gsize
numbered_volume_suffix (const char *low, gsize len)
{
    if (len >= 4 && low[len - 4] == '.' && g_ascii_isdigit (low[len - 3]) &&
        g_ascii_isdigit (low[len - 2]) && g_ascii_isdigit (low[len - 1]))
        return 4;
    return 0;
}

/* Length of a ".rNN" suffix, else 0. */
static gsize
rnn_suffix (const char *low, gsize len)
{
    if (len >= 4 && low[len - 4] == '.' && low[len - 3] == 'r' &&
        g_ascii_isdigit (low[len - 2]) && g_ascii_isdigit (low[len - 1]))
        return 4;
    return 0;
}

/* Length of a ".partN.rar" suffix, else 0; *number gets N. */
static gsize
part_rar_suffix (const char *low, gsize len, guint64 *number)
{
    gsize i;
    if (!ends_with (low, len, ".rar"))
        return 0;
    i = len - 4;
    if (i == 0 || !g_ascii_isdigit (low[i - 1]))
        return 0;
    while (i > 0 && g_ascii_isdigit (low[i - 1]))
        i--;
    if (i < 5 || memcmp (low + i - 5, ".part", 5) != 0)
        return 0;
    if (number != NULL)
        *number = g_ascii_strtoull (low + i, NULL, 10);
    return len - (i - 5);
}

/* True when a file of this name and MIME type is an archive zx opens and,
 * of a multi-volume set, the first volume. */
static gboolean
zx_is_supported (const char *name, const char *mime)
{
    g_autofree char *low = g_ascii_strdown (name, -1);
    gsize len = strlen (low);
    guint64 part = 0;
    const char *const *e;

    if (numbered_volume_suffix (low, len) != 0)
        return ends_with (low, len, ".001");
    if (rnn_suffix (low, len) != 0)
        return FALSE;
    if (part_rar_suffix (low, len, &part) != 0)
        return part == 1;
    for (e = zx_extensions; *e != NULL; e++)
    {
        g_autofree char *dotted = g_strconcat (".", *e, NULL);
        if (ends_with (low, len, dotted))
            return TRUE;
    }
    return mime != NULL && in_list (zx_mime_types, mime);
}

/* The folder an archive extracts to, as folderNameFor names it: the name
 * without its archive extensions (a.tar.gz, a.tgz, a.7z.001, a.part1.rar
 * give a; a.txt.gz gives a.txt). */
static char *
zx_folder_name (const char *name)
{
    g_autofree char *low = g_ascii_strdown (name, -1);
    gsize len = strlen (low);
    gsize cut;
    const char *const *e;
    const char *dot;

    cut = numbered_volume_suffix (low, len);
    len -= cut;
    low[len] = '\0';

    cut = part_rar_suffix (low, len, NULL);
    if (cut == 0)
        cut = rnn_suffix (low, len);
    if (cut != 0)
    {
        len -= cut;
        return len == 0 ? g_strdup ("archive") : g_strndup (name, len);
    }

    for (e = zx_compound_extensions; *e != NULL; e++)
    {
        g_autofree char *dotted = g_strconcat (".", *e, NULL);
        if (ends_with (low, len, dotted) && len > strlen (dotted))
            return g_strndup (name, len - strlen (dotted));
    }

    low[len] = '\0';
    dot = strrchr (low, '.');
    if (dot != NULL && dot > low)
    {
        const char *ext = dot + 1;
        if (in_list (zx_extensions, ext) || in_list (zx_compressor_extensions, ext))
            len = (gsize) (dot - low);
    }
    return len == 0 ? g_strdup ("archive") : g_strndup (name, len);
}

/* The program to start, or NULL when zx is not installed. */
static char *
zx_find_launcher (void)
{
    char *candidates[4];
    char *found = NULL;
    int i;

    candidates[0] = g_strdup ("/usr/bin/zx-gui");
    candidates[1] = g_build_filename (g_get_home_dir (), ".local", "bin", "zx-gui", NULL);
    candidates[2] = g_strdup ("/opt/zx/zx_app");
    candidates[3] = g_build_filename (g_get_user_data_dir (), "zx", "app", "zx_app", NULL);
    for (i = 0; i < 4; i++)
    {
        if (found == NULL && g_file_test (candidates[i], G_FILE_TEST_IS_EXECUTABLE) &&
            !g_file_test (candidates[i], G_FILE_TEST_IS_DIR))
            found = g_strdup (candidates[i]);
        g_free (candidates[i]);
    }
    return found;
}

/* True when the user switched the item off in the settings of zx. */
static gboolean
zx_menu_disabled (void)
{
    g_autofree char *flag =
        g_build_filename (g_get_user_config_dir (), "zx", "context-menu-disabled", NULL);
    return g_file_test (flag, G_FILE_TEST_EXISTS);
}

/* Menu labels take '_' as a mnemonic mark: double it to keep it. */
static char *
escape_underscores (const char *s)
{
    GString *out = g_string_new (NULL);
    for (; *s != '\0'; s++)
    {
        if (*s == '_')
            g_string_append_c (out, '_');
        g_string_append_c (out, *s);
    }
    return g_string_free (out, FALSE);
}

/* ------------------------------------------------------------------------ */

#define ZX_TYPE_MENU_PROVIDER (zx_menu_provider_get_type ())
G_DECLARE_FINAL_TYPE (ZxMenuProvider, zx_menu_provider, ZX, MENU_PROVIDER, GObject)

struct _ZxMenuProvider
{
    GObject parent_instance;
};

static void zx_menu_provider_iface_init (NautilusMenuProviderInterface *iface);

G_DEFINE_DYNAMIC_TYPE_EXTENDED (ZxMenuProvider, zx_menu_provider, G_TYPE_OBJECT, G_TYPE_FLAG_FINAL,
                                G_IMPLEMENT_INTERFACE_DYNAMIC (NAUTILUS_TYPE_MENU_PROVIDER,
                                                               zx_menu_provider_iface_init))

static void
zx_activate (NautilusMenuItem *item, gpointer user_data)
{
    const char *launcher = g_object_get_data (G_OBJECT (item), "zx-launcher");
    char **paths = g_object_get_data (G_OBJECT (item), "zx-paths");
    g_autoptr (GPtrArray) argv = NULL;
    g_autoptr (GError) error = NULL;
    g_autofree char *cwd = NULL;
    char **p;

    (void) user_data;
    if (launcher == NULL || paths == NULL || paths[0] == NULL)
        return;
    argv = g_ptr_array_new ();
    g_ptr_array_add (argv, (gpointer) launcher);
    g_ptr_array_add (argv, (gpointer) "--extract-to-folder");
    for (p = paths; *p != NULL; p++)
        g_ptr_array_add (argv, *p);
    g_ptr_array_add (argv, NULL);
    cwd = g_path_get_dirname (paths[0]);
    if (!g_spawn_async (cwd, (char **) argv->pdata, NULL, G_SPAWN_DEFAULT, NULL, NULL, NULL,
                        &error))
        g_warning ("zx-nautilus: could not start %s: %s", launcher, error->message);
}

static GList *
zx_get_file_items (NautilusMenuProvider *provider, GList *files)
{
    g_autoptr (GPtrArray) paths = NULL;
    g_autofree char *launcher = NULL;
    g_autofree char *label = NULL;
    NautilusMenuItem *item;
    GList *l;

    (void) provider;
    if (files == NULL || zx_menu_disabled ())
        return NULL;

    paths = g_ptr_array_new_with_free_func (g_free);
    for (l = files; l != NULL; l = l->next)
    {
        NautilusFileInfo *info = NAUTILUS_FILE_INFO (l->data);
        g_autoptr (GFile) location = NULL;
        g_autofree char *name = NULL;
        g_autofree char *mime = NULL;
        char *path;

        if (nautilus_file_info_is_directory (info))
            return NULL;
        location = nautilus_file_info_get_location (info);
        path = location != NULL ? g_file_get_path (location) : NULL;
        if (path == NULL)
            return NULL; /* not a local file */
        g_ptr_array_add (paths, path);
        name = g_path_get_basename (path);
        mime = nautilus_file_info_get_mime_type (info);
        if (!zx_is_supported (name, mime))
            return NULL;
    }

    launcher = zx_find_launcher ();
    if (launcher == NULL)
        return NULL;

    if (paths->len == 1)
    {
        g_autofree char *base = g_path_get_basename (g_ptr_array_index (paths, 0));
        g_autofree char *folder = zx_folder_name (base);
        g_autofree char *escaped = escape_underscores (folder);
        label = g_strdup_printf ("Extract to \"%s/\"", escaped);
    }
    else
    {
        label = g_strdup ("Extract each to its own folder");
    }

    item = nautilus_menu_item_new ("ZxMenuProvider::extract_to_folder", label,
                                   "Extract into a folder named after the archive (zx)", "zx");
    g_ptr_array_add (paths, NULL);
    g_object_set_data_full (G_OBJECT (item), "zx-paths",
                            g_ptr_array_steal (paths, NULL), (GDestroyNotify) g_strfreev);
    g_object_set_data_full (G_OBJECT (item), "zx-launcher", g_steal_pointer (&launcher), g_free);
    g_signal_connect (item, "activate", G_CALLBACK (zx_activate), NULL);
    return g_list_append (NULL, item);
}

static GList *
zx_get_background_items (NautilusMenuProvider *provider, NautilusFileInfo *folder)
{
    (void) provider;
    (void) folder;
    return NULL;
}

static void
zx_menu_provider_iface_init (NautilusMenuProviderInterface *iface)
{
    iface->get_file_items = zx_get_file_items;
    iface->get_background_items = zx_get_background_items;
}

static void
zx_menu_provider_init (ZxMenuProvider *self)
{
    (void) self;
}

static void
zx_menu_provider_class_init (ZxMenuProviderClass *klass)
{
    (void) klass;
}

static void
zx_menu_provider_class_finalize (ZxMenuProviderClass *klass)
{
    (void) klass;
}

/* ------------------------------------------------------------------------ */
/* The module entry points Nautilus looks up. */

static GType zx_types[1];

G_MODULE_EXPORT void
nautilus_module_initialize (GTypeModule *module)
{
    zx_menu_provider_register_type (module);
    zx_types[0] = ZX_TYPE_MENU_PROVIDER;
}

G_MODULE_EXPORT void
nautilus_module_shutdown (void)
{
}

G_MODULE_EXPORT void
nautilus_module_list_types (const GType **types, int *num_types)
{
    *types = zx_types;
    *num_types = G_N_ELEMENTS (zx_types);
}
