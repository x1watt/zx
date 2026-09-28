package io.github.maxbrito.zx_app

import android.app.Activity
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

/**
 * Storage for zx on Android: the volumes and the standard folders, the
 * app's own folders, free space, the Storage Access Framework (document
 * trees chosen by the user, used when dart:io cannot reach a folder),
 * FileProvider URIs for open with and share, and the files of incoming
 * intents. Every method that does I/O is called on a background thread.
 */
class ZxStorage(private val ctx: Context) {
    private val resolver = ctx.contentResolver

    // ---- places ----

    /** The mounted volumes: internal storage, SD cards, USB drives. */
    fun volumes(): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val seen = HashSet<String>()
        val sm = ctx.getSystemService(Context.STORAGE_SERVICE) as StorageManager
        for (v in sm.storageVolumes) {
            val dir: File? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) v.directory else volumePathLegacy(v)
            val path = dir?.absolutePath ?: continue
            if (!seen.add(path)) continue
            out.add(
                mapOf(
                    "path" to path,
                    "label" to v.getDescription(ctx),
                    "primary" to v.isPrimary,
                    "removable" to v.isRemovable,
                    "state" to v.state,
                    "uuid" to v.uuid,
                )
            )
        }
        // Volumes that StorageManager did not return (older devices): the
        // roots of getExternalFilesDirs.
        for (d in ctx.getExternalFilesDirs(null)) {
            val p = d?.absolutePath ?: continue
            val i = p.indexOf("/Android/data/")
            if (i <= 0) continue
            val root = p.substring(0, i)
            if (seen.add(root)) {
                out.add(
                    mapOf(
                        "path" to root, "label" to File(root).name, "primary" to false,
                        "removable" to true, "state" to Environment.getExternalStorageState(d), "uuid" to null,
                    )
                )
            }
        }
        return out
    }

    private fun volumePathLegacy(v: android.os.storage.StorageVolume): File? = try {
        val m = v.javaClass.getMethod("getPathFile")
        m.invoke(v) as? File
    } catch (e: Exception) {
        null
    }

    fun publicDirs(): Map<String, String> {
        val m = LinkedHashMap<String, String>()
        m["root"] = Environment.getExternalStorageDirectory().absolutePath
        for ((k, t) in listOf(
            "downloads" to Environment.DIRECTORY_DOWNLOADS,
            "documents" to Environment.DIRECTORY_DOCUMENTS,
            "dcim" to Environment.DIRECTORY_DCIM,
            "pictures" to Environment.DIRECTORY_PICTURES,
            "music" to Environment.DIRECTORY_MUSIC,
            "movies" to Environment.DIRECTORY_MOVIES,
        )) {
            m[k] = Environment.getExternalStoragePublicDirectory(t).absolutePath
        }
        return m
    }

    fun appDirs(): Map<String, Any?> = mapOf(
        "files" to ctx.filesDir.absolutePath,
        "cache" to ctx.cacheDir.absolutePath,
        "externalFiles" to ctx.getExternalFilesDirs(null).filterNotNull().map { it.absolutePath },
        "externalCache" to ctx.externalCacheDir?.absolutePath,
    )

    fun freeSpace(path: String): Map<String, Long> {
        var f = File(path)
        while (!f.exists() && f.parentFile != null) f = f.parentFile!!
        val st = StatFs(f.absolutePath)
        return mapOf("free" to st.availableBytes, "total" to st.totalBytes)
    }

    // ---- open with, share ----

    private fun contentUri(path: String): Uri =
        FileProvider.getUriForFile(ctx, ctx.packageName + ".files", File(path))

    fun mimeOf(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        if (ext == "zx") return "application/x-zx"
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
    }

    fun openWith(activity: Activity, path: String, mime: String?, chooser: Boolean) {
        val uri = contentUri(path)
        val i = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, mime ?: mimeOf(path))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        activity.startActivity(if (chooser) Intent.createChooser(i, "Open with") else i)
    }

    fun share(activity: Activity, paths: List<String>, mime: String?) {
        if (paths.isEmpty()) return
        val uris = ArrayList(paths.map { contentUri(it) })
        val type = mime ?: if (paths.size == 1) mimeOf(paths[0]) else "*/*"
        val i = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uris[0])
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
        }
        i.type = type
        val clip = ClipData.newUri(resolver, File(paths[0]).name, uris[0])
        for (u in uris.drop(1)) clip.addItem(ClipData.Item(u))
        i.clipData = clip
        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        activity.startActivity(Intent.createChooser(i, "Share"))
    }

    // ---- Storage Access Framework ----

    private fun docUri(s: String): Uri {
        val u = Uri.parse(s)
        // a bare tree URI: its root document
        if (DocumentsContract.isTreeUri(u) && !u.path.orEmpty().contains("/document/")) {
            return DocumentsContract.buildDocumentUriUsingTree(u, DocumentsContract.getTreeDocumentId(u))
        }
        return u
    }

    /** Keeps the permission of a chosen tree; returns its root document. */
    fun keepTree(tree: Uri): Map<String, Any?> {
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        try {
            resolver.takePersistableUriPermission(tree, flags)
        } catch (e: SecurityException) {
            resolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return treeInfo(tree)
    }

    private fun treeInfo(tree: Uri): Map<String, Any?> {
        val doc = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        return mapOf(
            "uri" to doc.toString(),
            "tree" to tree.toString(),
            "name" to (queryName(doc) ?: tree.lastPathSegment ?: "Folder"),
            "path" to safPathOf(doc),
        )
    }

    fun trees(): List<Map<String, Any?>> =
        resolver.persistedUriPermissions.filter { DocumentsContract.isTreeUri(it.uri) }.map {
            try {
                treeInfo(it.uri)
            } catch (e: Exception) {
                mapOf("uri" to it.uri.toString(), "tree" to it.uri.toString(), "name" to it.uri.lastPathSegment, "path" to null)
            }
        }

    fun releaseTree(s: String) {
        val u = Uri.parse(s)
        for (p in resolver.persistedUriPermissions) {
            if (p.uri == u || u.toString().startsWith(p.uri.toString())) {
                resolver.releasePersistableUriPermission(
                    p.uri,
                    (if (p.isReadPermission) Intent.FLAG_GRANT_READ_URI_PERMISSION else 0) or
                        (if (p.isWritePermission) Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0),
                )
            }
        }
    }

    private val docColumns = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_SIZE,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        DocumentsContract.Document.COLUMN_FLAGS,
    )

    private fun row(c: Cursor, uri: Uri): Map<String, Any?> {
        val mime = c.getString(2)
        return mapOf(
            "uri" to uri.toString(),
            "name" to c.getString(1),
            "mime" to mime,
            "dir" to (mime == DocumentsContract.Document.MIME_TYPE_DIR),
            "size" to (if (c.isNull(3)) 0L else c.getLong(3)),
            "mtime" to (if (c.isNull(4)) 0L else c.getLong(4)),
            "writable" to ((c.getInt(5) and DocumentsContract.Document.FLAG_SUPPORTS_WRITE) != 0),
            "deletable" to ((c.getInt(5) and DocumentsContract.Document.FLAG_SUPPORTS_DELETE) != 0),
        )
    }

    /** The children of a folder document, one row per child. */
    fun safList(s: String): List<Map<String, Any?>> {
        val parent = docUri(s)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(parent, DocumentsContract.getDocumentId(parent))
        val out = ArrayList<Map<String, Any?>>()
        resolver.query(children, docColumns, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val u = DocumentsContract.buildDocumentUriUsingTree(parent, c.getString(0))
                out.add(row(c, u))
            }
        }
        return out
    }

    fun safStat(s: String): Map<String, Any?>? {
        val u = docUri(s)
        resolver.query(u, docColumns, null, null, null)?.use { c ->
            if (c.moveToFirst()) return row(c, u)
        }
        return null
    }

    /** The file path of a document when dart:io can reach it, or null. */
    fun safPath(s: String): String? = safPathOf(docUri(s))

    private fun safPathOf(u: Uri): String? {
        if (u.authority != "com.android.externalstorage.documents") return null
        val id = try {
            DocumentsContract.getDocumentId(u)
        } catch (e: Exception) {
            return null
        }
        val colon = id.indexOf(':')
        if (colon < 0) return null
        val vol = id.substring(0, colon)
        val rel = id.substring(colon + 1)
        val root = if (vol == "primary") Environment.getExternalStorageDirectory().absolutePath else "/storage/$vol"
        val f = if (rel.isEmpty()) File(root) else File(root, rel)
        return if (f.canRead()) f.absolutePath else null
    }

    fun safCopyOut(s: String, path: String): String {
        val dest = File(path)
        dest.parentFile?.mkdirs()
        resolver.openInputStream(docUri(s)).use { input ->
            if (input == null) throw IllegalStateException("cannot read $s")
            FileOutputStream(dest).use { input.copyTo(it, 1 shl 16) }
        }
        return dest.absolutePath
    }

    fun safCopyIn(path: String, parent: String, name: String, mime: String?): String {
        val p = docUri(parent)
        val doc = DocumentsContract.createDocument(resolver, p, mime ?: mimeOf(name), name)
            ?: throw IllegalStateException("cannot create $name")
        resolver.openOutputStream(doc, "wt").use { out ->
            if (out == null) throw IllegalStateException("cannot write $name")
            FileInputStream(path).use { it.copyTo(out, 1 shl 16) }
        }
        return doc.toString()
    }

    fun safDelete(s: String): Boolean = DocumentsContract.deleteDocument(resolver, docUri(s))

    fun safMkdir(parent: String, name: String): String? =
        DocumentsContract.createDocument(resolver, docUri(parent), DocumentsContract.Document.MIME_TYPE_DIR, name)
            ?.toString()

    fun safRename(s: String, name: String): String? =
        DocumentsContract.renameDocument(resolver, docUri(s), name)?.toString()

    // ---- incoming intents ----

    private fun queryName(u: Uri): String? = try {
        resolver.query(u, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) c.getString(0) else null
        }
    } catch (e: Exception) {
        null
    }

    /** A readable file path for a URI, without copying, or null. */
    private fun directPath(u: Uri): String? {
        if (u.scheme == "file") return u.path?.takeIf { File(it).canRead() }
        if (u.scheme != "content") return null
        try {
            if (DocumentsContract.isDocumentUri(ctx, u)) {
                safPathOf(u)?.let { return it }
            }
        } catch (e: Exception) {
            // not a document
        }
        try {
            resolver.query(u, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)?.use { c ->
                if (c.moveToFirst() && !c.isNull(0)) {
                    val p = c.getString(0)
                    if (p != null && p.startsWith("/") && File(p).canRead()) return p
                }
            }
        } catch (e: Exception) {
            // no _data column
        }
        return null
    }

    private fun safeName(n: String): String =
        n.replace('/', '_').replace('\u0000', '_').ifBlank { "file" }

    /**
     * The files of a VIEW / SEND / SEND_MULTIPLE intent: the file path when
     * zx can read it directly, a copy in the cache otherwise ("copied":
     * true; changes to it do not reach the original).
     */
    fun incoming(intent: Intent): Map<String, Any?> {
        val uris = ArrayList<Uri>()
        when (intent.action) {
            Intent.ACTION_VIEW -> intent.data?.let { uris.add(it) }
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uris.add(it) }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
            }
        }
        if (uris.isEmpty()) {
            intent.clipData?.let { c -> for (k in 0 until c.itemCount) c.getItemAt(k).uri?.let { uris.add(it) } }
        }
        val dir = File(ctx.cacheDir, "incoming/" + System.currentTimeMillis())
        val files = ArrayList<Map<String, Any?>>()
        for (u in uris) {
            val direct = directPath(u)
            if (direct != null) {
                files.add(mapOf("path" to direct, "name" to File(direct).name, "copied" to false, "uri" to u.toString()))
                continue
            }
            var name = safeName(queryName(u) ?: u.lastPathSegment?.substringAfterLast('/') ?: "file")
            dir.mkdirs()
            var dest = File(dir, name)
            var n = 2
            while (dest.exists()) {
                dest = File(dir, name.substringBeforeLast('.') + " ($n)" +
                    (if (name.contains('.')) "." + name.substringAfterLast('.') else ""))
                n++
            }
            try {
                resolver.openInputStream(u)?.use { input ->
                    FileOutputStream(dest).use { input.copyTo(it, 1 shl 16) }
                } ?: continue
                files.add(mapOf("path" to dest.absolutePath, "name" to dest.name, "copied" to true, "uri" to u.toString()))
            } catch (e: Exception) {
                files.add(mapOf("path" to null, "name" to name, "copied" to false, "uri" to u.toString(), "error" to (e.message ?: e.toString())))
            }
        }
        // Shared text without a file: saved as a text file.
        if (uris.isEmpty() && intent.action == Intent.ACTION_SEND) {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            if (text != null) {
                dir.mkdirs()
                val f = File(dir, "shared.txt")
                f.writeText(text)
                files.add(mapOf("path" to f.absolutePath, "name" to f.name, "copied" to true, "uri" to null))
            }
        }
        return mapOf(
            "action" to when (intent.action) {
                Intent.ACTION_VIEW -> "view"
                else -> "send"
            },
            "mime" to intent.type,
            "files" to files,
        )
    }
}
