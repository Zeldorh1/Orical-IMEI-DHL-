package com.orical.imeitag

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "orical.imeitag/capture"
    private val reqProjection = 7321
    private var pendingProjectionResult: MethodChannel.Result? = null
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "isAccessibilityEnabled" -> result.success(isAccessibilityEnabled())
                "openAccessibilitySettings" -> {
                    openAccessibilitySettings()
                    result.success(null)
                }
                "captureViaAccessibility" -> captureViaAccessibility(result)
                "captureScreenshot" -> captureScreenshot(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun isAccessibilityEnabled(): Boolean {
        val expectedId = "$packageName/com.orical.imeitag.AccessibilityScrapeService"
        val expectedShort = "$packageName/.AccessibilityScrapeService"
        val enabled = try {
            Settings.Secure.getInt(contentResolver, Settings.Secure.ACCESSIBILITY_ENABLED, 0) == 1
        } catch (_: Throwable) { false }
        if (!enabled) return false
        val services = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        return services.split(":").any {
            it.equals(expectedId, ignoreCase = true) || it.equals(expectedShort, ignoreCase = true)
        }
    }

    private fun openAccessibilitySettings() {
        try {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: Throwable) {}
    }

    private fun captureViaAccessibility(result: MethodChannel.Result) {
        AccessibilityScrapeService.reset()
        AccessibilityScrapeService.enabledScrape = true

        val opened = tryLaunchDeviceInfo()
        if (!opened) {
            AccessibilityScrapeService.enabledScrape = false
            result.success(null)
            return
        }

        val handler = Handler(Looper.getMainLooper())
        val deadline = System.currentTimeMillis() + 9000L
        val checker = object : Runnable {
            override fun run() {
                if (AccessibilityScrapeService.imei != null) {
                    AccessibilityScrapeService.enabledScrape = false
                    val map = mapOf(
                        "imei" to (AccessibilityScrapeService.imei ?: ""),
                        "imei2" to (AccessibilityScrapeService.imei2 ?: ""),
                        "eid" to (AccessibilityScrapeService.eid ?: ""),
                        "meid" to (AccessibilityScrapeService.meid ?: ""),
                        "serial" to (AccessibilityScrapeService.serial ?: ""),
                        "model" to (AccessibilityScrapeService.model ?: "")
                    )
                    bringSelfToFront()
                    result.success(map)
                    return
                }
                if (System.currentTimeMillis() > deadline) {
                    AccessibilityScrapeService.enabledScrape = false
                    bringSelfToFront()
                    result.success(null)
                    return
                }
                handler.postDelayed(this, 300L)
            }
        }
        handler.postDelayed(checker, 1500L)
    }

    private fun captureScreenshot(result: MethodChannel.Result) {
        if (pendingProjectionResult != null) {
            result.error("busy", "Capture already in progress", null)
            return
        }
        pendingProjectionResult = result
        ScreenCaptureService.reset()
        val mgr = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        try {
            startActivityForResult(mgr.createScreenCaptureIntent(), reqProjection)
        } catch (t: Throwable) {
            pendingProjectionResult = null
            result.error("unavailable", "MediaProjection unavailable: ${t.message}", null)
        }
    }

    @Deprecated("Override of deprecated API kept for compatibility with embedding Activity Result")
    @Suppress("OVERRIDE_DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != reqProjection) return
        val callback = pendingProjectionResult
        pendingProjectionResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            callback?.success(null)
            return
        }
        val svc = Intent(this, ScreenCaptureService::class.java)
            .putExtra(ScreenCaptureService.EXTRA_RESULT_CODE, resultCode)
            .putExtra(ScreenCaptureService.EXTRA_RESULT_DATA, data)
        try {
            ContextCompat.startForegroundService(this, svc)
        } catch (t: Throwable) {
            callback?.error("svc", "Could not start capture service: ${t.message}", null)
            return
        }

        tryLaunchDeviceInfo()

        val handler = Handler(Looper.getMainLooper())
        val deadline = System.currentTimeMillis() + 15000L
        val poller = object : Runnable {
            override fun run() {
                if (ScreenCaptureService.resultDone.get()) {
                    val err = ScreenCaptureService.resultError.get()
                    val path = ScreenCaptureService.resultPath.get()
                    bringSelfToFront()
                    if (err != null) {
                        callback?.error("capture", err, null)
                    } else {
                        callback?.success(path)
                    }
                    return
                }
                if (System.currentTimeMillis() > deadline) {
                    bringSelfToFront()
                    callback?.error("timeout", "Capture timed out", null)
                    return
                }
                handler.postDelayed(this, 300L)
            }
        }
        handler.postDelayed(poller, 500L)
    }

    private fun tryLaunchDeviceInfo(): Boolean {
        val candidates = listOf(
            Intent(Settings.ACTION_DEVICE_INFO_SETTINGS),
            Intent("android.settings.DEVICE_INFO_SETTINGS"),
            Intent(Settings.ACTION_SETTINGS)
        )
        for (intent in candidates) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                startActivity(intent)
                return true
            } catch (_: Throwable) {
                continue
            }
        }
        return false
    }

    private fun bringSelfToFront() {
        try {
            val intent = Intent(applicationContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        } catch (_: Throwable) {}
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
    }
}
