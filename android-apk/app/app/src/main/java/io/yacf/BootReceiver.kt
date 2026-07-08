package io.yacf

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat

/**
 * Starts the proxy on boot if credentials are stored and autostart is enabled.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (Store.hasCreds(context) && Store.autostart(context)) {
            ContextCompat.startForegroundService(
                context,
                Intent(context, ProxyService::class.java),
            )
        }
    }
}
