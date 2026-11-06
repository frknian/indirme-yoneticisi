package dev.dmapp.download_manager

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Flutter motorunu Activity'den bağımsız tutar. Kullanıcı ekranı kapatınca Activity
 * yok edilse de motor ve indirme isolate'ları süreç yaşadıkça çalışmaya devam eder.
 */
class DmApplication : Application() {
    lateinit var bridge: PlatformBridge
        private set

    override fun onCreate() {
        super.onCreate()
        val engine = FlutterEngine(this)
        bridge = PlatformBridge(this, engine.dartExecutor.binaryMessenger)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    }

    companion object {
        const val ENGINE_ID = "dm_main_engine"
    }
}
