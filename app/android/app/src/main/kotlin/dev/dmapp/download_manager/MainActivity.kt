package dev.dmapp.download_manager

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    private val bridge: PlatformBridge
        get() = (application as DmApplication).bridge

    // Önbellekteki motor kullanılır; FlutterActivity kapanırken onu yok etmez.
    override fun getCachedEngineId(): String = DmApplication.ENGINE_ID

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        bridge.attachActivity(this)
        // Yeniden oluşturulan Activity aynı paylaşımı ikinci kez işlemesin.
        if (savedInstanceState == null) handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    override fun onDestroy() {
        bridge.detachActivity(this)
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        bridge.onPermissionResult(requestCode, grantResults)
    }

    private fun handleIntent(intent: Intent?) {
        val url = when (intent?.action) {
            Intent.ACTION_SEND -> extractUrl(intent.getStringExtra(Intent.EXTRA_TEXT))
            Intent.ACTION_VIEW -> intent.dataString?.takeIf(::isHttpUrl)
            else -> null
        }
        if (url != null) bridge.deliverSharedUrl(url)
    }

    private fun isHttpUrl(value: String): Boolean =
        value.startsWith("http://", ignoreCase = true) ||
            value.startsWith("https://", ignoreCase = true)

    /** Paylaşılan metnin içindeki ilk http(s) bağlantısını bulur. */
    private fun extractUrl(text: String?): String? =
        text?.let { URL_PATTERN.find(it)?.value }

    private companion object {
        val URL_PATTERN = Regex("""https?://\S+""", RegexOption.IGNORE_CASE)
    }
}
