package io.yacf

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.view.View
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat

/**
 * Single-screen UI: paste a setup code (or raw URL + token), toggle the proxy
 * ON/OFF, tick autostart-on-boot. Credentials persist in EncryptedSharedPreferences.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var codeField: EditText
    private lateinit var urlField: EditText
    private lateinit var tokenField: EditText
    private lateinit var status: TextView
    private lateinit var toggle: Button
    private lateinit var autostart: CheckBox

    private val notifPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    @SuppressLint("SetTextI18n")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val pad = (16 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
        }

        root.addView(TextView(this).apply {
            text = "yacfsocks"
            textSize = 22f
        })
        root.addView(TextView(this).apply {
            text = "Paste the setup code, or enter URL + token, then tap ON. " +
                "Point Telegram at SOCKS5 ${Store.LISTEN}."
            setPadding(0, pad / 2, 0, pad)
        })

        codeField = EditText(this).apply { hint = "Setup code (base64)" }
        root.addView(codeField)

        root.addView(TextView(this).apply {
            text = "- or -"
            setPadding(0, pad / 2, 0, pad / 2)
        })
        urlField = EditText(this).apply { hint = "FUNCTION_URL" }
        tokenField = EditText(this).apply { hint = "TOKEN" }
        root.addView(urlField)
        root.addView(tokenField)

        autostart = CheckBox(this).apply {
            text = "Autostart on boot"
            isChecked = Store.autostart(this@MainActivity)
            setOnCheckedChangeListener { _, on -> Store.setAutostart(this@MainActivity, on) }
        }
        root.addView(autostart)

        toggle = Button(this).apply {
            setOnClickListener { onToggle() }
        }
        root.addView(toggle)

        status = TextView(this).apply { setPadding(0, pad, 0, 0) }
        root.addView(status)

        setContentView(root)

        // Prefill from stored creds.
        Store.url(this)?.let { urlField.setText(it) }
        Store.token(this)?.let { tokenField.setText(it) }

        requestNotifPermission()
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun onToggle() {
        if (yacf.Yacf.running()) {
            stopService(Intent(this, ProxyService::class.java))
            status.text = "Stopping…"
            toggle.postDelayed({ refresh() }, 400)
            return
        }
        // Resolve credentials: setup code wins, else raw fields.
        val code = codeField.text.toString().trim()
        val creds = if (code.isNotEmpty()) Store.decodeSetupCode(code) else null
        val (url, token) = when {
            creds != null -> creds
            urlField.text.isNotBlank() && tokenField.text.isNotBlank() ->
                urlField.text.toString().trim() to tokenField.text.toString().trim()
            code.isNotEmpty() -> {
                toast("Bad setup code")
                return
            }
            else -> {
                toast("Enter a setup code or URL + token")
                return
            }
        }
        Store.save(this, url, token)
        promptBatteryExemption()
        ContextCompat.startForegroundService(this, Intent(this, ProxyService::class.java))
        status.text = "Starting…"
        toggle.postDelayed({ refresh() }, 600)
    }

    @SuppressLint("SetTextI18n")
    private fun refresh() {
        val running = yacf.Yacf.running()
        toggle.text = if (running) "OFF" else "ON"
        status.text = when {
            running && ProxyService.lastLog.isNotEmpty() -> "Running - ${ProxyService.lastLog}"
            running -> "Running on ${Store.LISTEN}"
            Store.hasCreds(this) -> "Stopped"
            else -> "Not configured"
        }
    }

    private fun requestNotifPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            notifPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    private fun promptBatteryExemption() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (!pm.isIgnoringBatteryOptimizations(packageName)) {
            try {
                startActivity(
                    Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                        .setData(Uri.parse("package:$packageName")),
                )
            } catch (_: Exception) {
            }
        }
    }

    private fun toast(m: String) = Toast.makeText(this, m, Toast.LENGTH_SHORT).show()
}
