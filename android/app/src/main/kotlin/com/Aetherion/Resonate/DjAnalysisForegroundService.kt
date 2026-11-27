package com.Aetherion.Resonate

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock

/**
 * Keeps the app process eligible to continue its serial, non-playback DJ
 * library analysis while the Activity is backgrounded. The Dart scanner owns
 * the work and persists each track before advancing; this service only
 * supplies Android's foreground execution priority and a bounded CPU wake lock.
 */
class DjAnalysisForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private val handler = Handler(Looper.getMainLooper())
    private var lastHeartbeatMs = 0L
    private val watchdog = object : Runnable {
        override fun run() {
            val idleFor = SystemClock.elapsedRealtime() - lastHeartbeatMs
            if (idleFor >= WATCHDOG_TIMEOUT_MS) {
                stopSelf()
            } else {
                handler.postDelayed(this, WATCHDOG_INTERVAL_MS)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        runningInstance = this
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        acquireWakeLock()
        refreshHeartbeat()
        return START_NOT_STICKY
    }

    private fun refreshHeartbeat() {
        lastHeartbeatMs = SystemClock.elapsedRealtime()
        handler.removeCallbacks(watchdog)
        handler.postDelayed(watchdog, WATCHDOG_INTERVAL_MS)
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "Resonate:DJLibraryAnalysis",
        ).apply {
            setReferenceCounted(false)
            // The heartbeat watchdog releases this lock if the Dart scanner
            // disappears without sending its normal stop request.
            acquire()
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("Resonate library analysis")
            .setContentText("Preparing DJ track intelligence in the background")
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(pendingIntent)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "DJ library analysis",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Visible while Resonate analyses library tracks for DJ features"
                setShowBadge(false)
            },
        )
    }

    override fun onDestroy() {
        handler.removeCallbacks(watchdog)
        if (runningInstance === this) runningInstance = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val CHANNEL_ID = "resonate_dj_library_analysis"
        private const val NOTIFICATION_ID = 4817
        private const val WATCHDOG_INTERVAL_MS = 60L * 1000L
        private const val WATCHDOG_TIMEOUT_MS = 30L * 60L * 1000L

        @Volatile
        private var runningInstance: DjAnalysisForegroundService? = null

        fun heartbeat(): Boolean {
            val service = runningInstance ?: return false
            service.refreshHeartbeat()
            return true
        }

        fun stop(context: android.content.Context) {
            context.stopService(Intent(context, DjAnalysisForegroundService::class.java))
        }
    }
}
