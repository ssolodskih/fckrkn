package io.yacf

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Credential + settings store backed by EncryptedSharedPreferences, so the
 * function URL and token never sit in plaintext on the device.
 */
object Store {
    private const val FILE = "yacf_secure"
    private const val K_URL = "function_url"
    private const val K_TOKEN = "token"
    private const val K_AUTOSTART = "autostart"

    const val LISTEN = "127.0.0.1:1080"

    private fun prefs(ctx: Context): SharedPreferences {
        val key = MasterKey.Builder(ctx)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        return EncryptedSharedPreferences.create(
            ctx,
            FILE,
            key,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    fun save(ctx: Context, url: String, token: String) {
        prefs(ctx).edit().putString(K_URL, url).putString(K_TOKEN, token).apply()
    }

    fun url(ctx: Context): String? = prefs(ctx).getString(K_URL, null)
    fun token(ctx: Context): String? = prefs(ctx).getString(K_TOKEN, null)
    fun hasCreds(ctx: Context): Boolean = !url(ctx).isNullOrEmpty() && !token(ctx).isNullOrEmpty()

    fun autostart(ctx: Context): Boolean = prefs(ctx).getBoolean(K_AUTOSTART, false)
    fun setAutostart(ctx: Context, on: Boolean) {
        prefs(ctx).edit().putBoolean(K_AUTOSTART, on).apply()
    }

    /**
     * Parse a pasted setup code = base64("FUNCTION_URL|TOKEN") - the same format
     * android/make-code.sh emits. Returns (url, token) or null if it doesn't
     * decode to that shape.
     */
    fun decodeSetupCode(code: String): Pair<String, String>? {
        return try {
            val decoded = String(Base64.decode(code.trim(), Base64.DEFAULT))
            val i = decoded.indexOf('|')
            if (i <= 0 || i == decoded.length - 1) return null
            val url = decoded.substring(0, i).trim()
            val token = decoded.substring(i + 1).trim()
            if (url.isEmpty() || token.isEmpty()) null else url to token
        } catch (e: Exception) {
            null
        }
    }
}
