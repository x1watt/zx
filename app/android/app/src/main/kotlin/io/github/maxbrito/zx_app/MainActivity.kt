package io.github.maxbrito.zx_app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.system.Os
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * The Android side of zx: storage access, the Storage Access Framework,
 * open with / share, and the intents other apps send (open an archive,
 * share files to zx). Dart talks to it through the "zx/android" channel
 * (app/lib/src/platform/android_channel.dart). Everything that touches the
 * disk or a content provider runs on a background thread; the replies are
 * posted back on the main thread.
 */
class MainActivity : FlutterActivity() {
    private lateinit var channel: MethodChannel
    private lateinit var storage: ZxStorage
    private val io = Executors.newFixedThreadPool(3)
    private val main = Handler(Looper.getMainLooper())

    /** The intent that started or reached the app, until Dart takes it. */
    private var pendingIntent: Intent? = null
    private var dartReady = false

    private var permissionResult: MethodChannel.Result? = null
    private var treeResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Before the Dart VM starts: the zx library and the app take their
        // temporary folder from Directory.systemTemp (TMPDIR, else the
        // unwritable /data/local/tmp) and the settings folder from HOME
        // (AppPaths.fromEnvironment: $HOME/.config/zx). Both point into the
        // app's private storage.
        try {
            Os.setenv("TMPDIR", cacheDir.absolutePath, true)
            Os.setenv("HOME", filesDir.absolutePath, true)
        } catch (e: Exception) {
            // keep the defaults
        }
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) pendingIntent = intent
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        storage = ZxStorage(applicationContext)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zx/android")
        channel.setMethodCallHandler { call, result -> onCall(call, result) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (!isIncoming(intent)) return
        if (dartReady) {
            background(null) {
                val m = storage.incoming(intent)
                main.post { channel.invokeMethod("intent", m) }
                null
            }
        } else {
            pendingIntent = intent
        }
    }

    private fun isIncoming(i: Intent?): Boolean = when (i?.action) {
        Intent.ACTION_VIEW, Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE -> true
        else -> false
    }

    /** Runs [work] on a background thread and replies with its value. */
    private fun background(result: MethodChannel.Result?, work: () -> Any?) {
        io.execute {
            try {
                val v = work()
                main.post { result?.success(v) }
            } catch (e: Exception) {
                main.post { result?.error("zx", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        fun s(k: String): String = call.argument<String>(k) ?: throw IllegalArgumentException("missing $k")
        when (call.method) {
            "info" -> result.success(
                mapOf(
                    "sdk" to Build.VERSION.SDK_INT,
                    "allFilesAccess" to hasAllFilesAccess(),
                    "legacyAccess" to hasLegacyAccess(),
                )
            )
            "hasAllFilesAccess" -> result.success(hasAllFilesAccess())
            "requestAllFilesAccess" -> requestAllFilesAccess(result)
            "takeIntent" -> {
                dartReady = true
                val i = pendingIntent
                pendingIntent = null
                if (!isIncoming(i)) result.success(null)
                else background(result) { storage.incoming(i!!) }
            }
            "volumes" -> background(result) { storage.volumes() }
            "publicDirs" -> result.success(storage.publicDirs())
            "appDirs" -> result.success(storage.appDirs())
            "freeSpace" -> background(result) { storage.freeSpace(s("path")) }
            "openWith" -> try {
                storage.openWith(this, s("path"), call.argument<String>("mime"), call.argument<Boolean>("chooser") ?: true)
                result.success(true)
            } catch (e: Exception) {
                result.error("zx", e.message ?: e.toString(), null)
            }
            "share" -> try {
                storage.share(this, call.argument<List<String>>("paths") ?: emptyList(), call.argument<String>("mime"))
                result.success(true)
            } catch (e: Exception) {
                result.error("zx", e.message ?: e.toString(), null)
            }
            "pickTree" -> pickTree(result)
            "trees" -> result.success(storage.trees())
            "releaseTree" -> { storage.releaseTree(s("uri")); result.success(null) }
            "safList" -> background(result) { storage.safList(s("uri")) }
            "safStat" -> background(result) { storage.safStat(s("uri")) }
            "safPath" -> background(result) { storage.safPath(s("uri")) }
            "safCopyOut" -> background(result) { storage.safCopyOut(s("uri"), s("path")) }
            "safCopyIn" -> background(result) {
                storage.safCopyIn(s("path"), s("parent"), s("name"), call.argument<String>("mime"))
            }
            "safDelete" -> background(result) { storage.safDelete(s("uri")) }
            "safMkdir" -> background(result) { storage.safMkdir(s("parent"), s("name")) }
            "safRename" -> background(result) { storage.safRename(s("uri"), s("name")) }
            else -> result.notImplemented()
        }
    }

    // ---- storage permission ----

    private fun hasAllFilesAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Environment.isExternalStorageManager()
        else hasLegacyAccess()

    private fun hasLegacyAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= 33) false
        else checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED &&
            (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ||
                checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED)

    private fun requestAllFilesAccess(result: MethodChannel.Result) {
        if (hasAllFilesAccess()) {
            result.success(true)
            return
        }
        permissionResult?.success(hasAllFilesAccess())
        permissionResult = result
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val i = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName"))
            try {
                startActivityForResult(i, REQ_ALL_FILES)
            } catch (e: Exception) {
                startActivityForResult(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION), REQ_ALL_FILES)
            }
        } else {
            requestPermissions(
                arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.WRITE_EXTERNAL_STORAGE),
                REQ_LEGACY,
            )
        }
    }

    private fun pickTree(result: MethodChannel.Result) {
        treeResult?.success(null)
        treeResult = result
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
        )
        try {
            startActivityForResult(i, REQ_TREE)
        } catch (e: Exception) {
            treeResult = null
            result.error("zx", "No document picker: ${e.message}", null)
        }
    }

    @Deprecated("startActivityForResult is what FlutterActivity offers")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQ_ALL_FILES -> {
                permissionResult?.success(hasAllFilesAccess())
                permissionResult = null
            }
            REQ_TREE -> {
                val r = treeResult
                treeResult = null
                val uri = data?.data
                if (resultCode != RESULT_OK || uri == null) {
                    r?.success(null)
                } else {
                    try {
                        r?.success(storage.keepTree(uri))
                    } catch (e: Exception) {
                        r?.error("zx", e.message ?: e.toString(), null)
                    }
                }
            }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_LEGACY) {
            permissionResult?.success(hasAllFilesAccess())
            permissionResult = null
        }
    }

    override fun onDestroy() {
        io.shutdown()
        super.onDestroy()
    }

    companion object {
        private const val REQ_ALL_FILES = 7101
        private const val REQ_LEGACY = 7102
        private const val REQ_TREE = 7103
    }
}
