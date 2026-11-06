package dev.dmapp.download_manager

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** Dart ile Android arasındaki `dm/platform` kanalı. */
class PlatformBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor = Executors.newSingleThreadExecutor()

    private var activity: Activity? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var pendingSharedUrl: String? = null
    private var dartReady = false

    fun attachActivity(activity: Activity) {
        this.activity = activity
    }

    fun detachActivity(activity: Activity) {
        if (this.activity === activity) this.activity = null
    }

    fun deliverSharedUrl(url: String) {
        if (dartReady) {
            channel.invokeMethod("sharedUrl", url)
        } else {
            pendingSharedUrl = url
        }
    }

    /** Bildirim düğmesi veya servis zaman aşımı: Dart tarafı indirmeleri güvenle durdurur. */
    fun requestPauseAll() {
        mainHandler.post { channel.invokeMethod("pauseAll", null) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "takePendingSharedUrl" -> {
                dartReady = true
                result.success(pendingSharedUrl)
                pendingSharedUrl = null
            }
            "requestNotificationPermission" -> requestNotificationPermission(result)
            "updateForeground" -> updateForeground(call, result)
            "stopForeground" -> {
                context.stopService(Intent(context, DownloadForegroundService::class.java))
                result.success(null)
            }
            "publishToDownloads" -> publishToDownloads(call, result)
            else -> result.notImplemented()
        }
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        val permission = Manifest.permission.POST_NOTIFICATIONS
        if (context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        val current = activity
        if (current == null || pendingPermission != null) {
            result.success(false)
            return
        }
        pendingPermission = result
        current.requestPermissions(arrayOf(permission), REQUEST_NOTIFICATIONS)
    }

    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != REQUEST_NOTIFICATIONS) return
        pendingPermission?.success(
            grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED,
        )
        pendingPermission = null
    }

    private fun updateForeground(call: MethodCall, result: MethodChannel.Result) {
        val intent = Intent(context, DownloadForegroundService::class.java)
            .putExtra(DownloadForegroundService.EXTRA_TITLE, call.argument<String>("title"))
            .putExtra(DownloadForegroundService.EXTRA_TEXT, call.argument<String>("text"))
            .putExtra(DownloadForegroundService.EXTRA_PERCENT, call.argument<Int>("percent") ?: -1)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            result.success(true)
        } catch (e: IllegalStateException) {
            // Android 12+: uygulama arka plandayken ilk başlatma reddedilir.
            result.success(false)
        }
    }

    /** Dosyayı MediaStore üzerinden İndirilenler'e kopyalar, başarılıysa kaynağı siler. */
    private fun publishToDownloads(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val name = call.argument<String>("name")
        if (path == null || name == null) {
            result.error("bad_args", "path ve name gerekli", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(null)
            return
        }
        ioExecutor.execute {
            try {
                val uri = copyToMediaStore(File(path), name)
                mainHandler.post { result.success(uri) }
            } catch (e: Exception) {
                mainHandler.post { result.error("publish_failed", e.message, null) }
            }
        }
    }

    private fun copyToMediaStore(source: File, name: String): String {
        val resolver = context.contentResolver
        val extension = name.substringAfterLast('.', "").lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: "application/octet-stream"
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("MediaStore kaydı oluşturulamadı")
        try {
            val output = resolver.openOutputStream(uri)
                ?: throw IllegalStateException("MediaStore dosyası açılamadı")
            output.use { sink -> source.inputStream().use { it.copyTo(sink) } }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            // Yarım kopya İndirilenler'de görünmesin; kaynak dosya duruyor.
            resolver.delete(uri, null, null)
            throw e
        }
        source.delete()
        return uri.toString()
    }

    private companion object {
        const val CHANNEL = "dm/platform"
        const val REQUEST_NOTIFICATIONS = 4101
    }
}
