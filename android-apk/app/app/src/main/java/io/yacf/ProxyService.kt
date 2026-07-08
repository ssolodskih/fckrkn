package io.yacf

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Foreground service that owns the SOCKS5 listener via yacf.aar. START_STICKY so
 * Android restarts it if killed. Loopback listener on 127.0.0.1:1080 - other
 * apps (Telegram) connect there.
 */
class ProxyService : Service() {

    companion object {
        const val CHANNEL_ID = "yacf_proxy"
        const val NOTIF_ID = 1
        const val ACTION_STOP = "io.yacf.STOP"

        @Volatile
        var lastLog: String = ""
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        createChannel()
        startForegroundCompat(buildNotification("Starting…"))

        // Start the relay off the main thread; Yacf.start returns once listening.
        Thread {
            val url = Store.url(this)
            val token = Store.token(this)
            if (url.isNullOrEmpty() || token.isNullOrEmpty()) {
                update("No credentials - open the app")
                stopSelf()
                return@Thread
            }
            if (yacf.Yacf.running()) {
                update("Running on ${Store.LISTEN}")
                return@Thread
            }
            try {
                yacf.Yacf.start(url, token, Store.LISTEN, object : yacf.Logger {
                    override fun log(msg: String) {
                        lastLog = msg
                        // Surface "open ... -> sid" lines; skip noisy per-exchange lines.
                        if (msg.startsWith("open ") || msg.startsWith("yacfsocks ")) {
                            update(msg)
                        }
                    }
                })
                update("Running on ${Store.LISTEN}")
            } catch (e: Exception) {
                update("Failed: ${e.message}")
                stopSelf()
            }
        }.start()

        return START_STICKY
    }

    override fun onDestroy() {
        try {
            yacf.Yacf.stop()
        } catch (_: Exception) {
        }
        super.onDestroy()
    }

    private fun createChannel() {
        val mgr = getSystemService(NotificationManager::class.java)
        val ch = NotificationChannel(
            CHANNEL_ID,
            "yacfsocks proxy",
            NotificationManager.IMPORTANCE_LOW,
        ).apply { description = "SOCKS5 proxy status" }
        mgr.createNotificationChannel(ch)
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 1,
            Intent(this, ProxyService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("yacfsocks")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(0, "Stop", stop)
            .build()
    }

    private fun startForegroundCompat(n: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIF_ID, n)
        }
    }

    private fun update(text: String) {
        val mgr = getSystemService(NotificationManager::class.java)
        mgr.notify(NOTIF_ID, buildNotification(text))
    }
}
