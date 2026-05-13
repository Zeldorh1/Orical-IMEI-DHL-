package com.orical.imeitag

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.DisplayMetrics
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicReference

/**
 * Foreground service required for MediaProjection on Android Q+. Captures one
 * frame after a short delay (giving Settings → About time to render), encodes
 * it to JPEG in app-private cache, then signals completion via the static
 * AtomicReference that the MethodChannel handler polls.
 *
 * The captured file is in internal storage; the Flutter side OCRs it and
 * deletes it.
 */
class ScreenCaptureService : Service() {

    companion object {
        const val EXTRA_RESULT_CODE = "result_code"
        const val EXTRA_RESULT_DATA = "result_data"
        const val NOTIFICATION_ID = 4711
        const val CHANNEL_ID = "orical_capture_channel"

        val resultPath: AtomicReference<String?> = AtomicReference(null)
        val resultDone: AtomicReference<Boolean> = AtomicReference(false)
        val resultError: AtomicReference<String?> = AtomicReference(null)

        fun reset() {
            resultPath.set(null)
            resultDone.set(false)
            resultError.set(null)
        }
    }

    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        intent ?: run { stopSelf(); return START_NOT_STICKY }

        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
        val data = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(EXTRA_RESULT_DATA)
        }
        if (data == null) {
            failAndStop("Missing projection result data")
            return START_NOT_STICKY
        }

        val mgr = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        projection = mgr.getMediaProjection(resultCode, data)
        if (projection == null) {
            failAndStop("Could not obtain MediaProjection")
            return START_NOT_STICKY
        }

        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getRealMetrics(metrics)
        val width = metrics.widthPixels
        val height = metrics.heightPixels
        val density = metrics.densityDpi

        imageReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        try {
            virtualDisplay = projection!!.createVirtualDisplay(
                "OricalCapture",
                width, height, density,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                imageReader!!.surface,
                null, null
            )
        } catch (t: Throwable) {
            failAndStop("createVirtualDisplay failed: ${t.message}")
            return START_NOT_STICKY
        }

        Handler(Looper.getMainLooper()).postDelayed({
            captureOnce(width, height)
        }, 1800L)

        return START_NOT_STICKY
    }

    private fun captureOnce(width: Int, height: Int) {
        val reader = imageReader ?: run {
            failAndStop("ImageReader missing")
            return
        }
        var image: Image? = null
        try {
            image = reader.acquireLatestImage()
            if (image == null) {
                failAndStop("No frame available")
                return
            }
            val bitmap = imageToBitmap(image, width, height)
            val out = File(cacheDir, "orical_capture_${System.currentTimeMillis()}.jpg")
            FileOutputStream(out).use { fos ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 95, fos)
            }
            bitmap.recycle()
            resultPath.set(out.absolutePath)
            resultDone.set(true)
        } catch (t: Throwable) {
            failAndStop("capture failed: ${t.message}")
            return
        } finally {
            try { image?.close() } catch (_: Throwable) {}
            cleanupOnly()
            stopSelf()
        }
    }

    private fun imageToBitmap(image: Image, width: Int, height: Int): Bitmap {
        val planes = image.planes
        val buffer: ByteBuffer = planes[0].buffer
        val pixelStride = planes[0].pixelStride
        val rowStride = planes[0].rowStride
        val rowPadding = rowStride - pixelStride * width
        val bmp = Bitmap.createBitmap(width + rowPadding / pixelStride, height, Bitmap.Config.ARGB_8888)
        bmp.copyPixelsFromBuffer(buffer)
        return if (rowPadding == 0) bmp else Bitmap.createBitmap(bmp, 0, 0, width, height)
    }

    private fun failAndStop(message: String) {
        resultError.set(message)
        resultDone.set(true)
        cleanupOnly()
        stopSelf()
    }

    private fun cleanupOnly() {
        try { virtualDisplay?.release() } catch (_: Throwable) {}
        try { imageReader?.close() } catch (_: Throwable) {}
        try { projection?.stop() } catch (_: Throwable) {}
        virtualDisplay = null
        imageReader = null
        projection = null
    }

    override fun onDestroy() {
        cleanupOnly()
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Capturing device info")
            .setContentText("One screenshot will be taken and OCRed offline. No data leaves the device.")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
        return builder.build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            val ch = NotificationChannel(
                CHANNEL_ID,
                "Device info capture",
                NotificationManager.IMPORTANCE_LOW
            )
            nm.createNotificationChannel(ch)
        }
    }
}
