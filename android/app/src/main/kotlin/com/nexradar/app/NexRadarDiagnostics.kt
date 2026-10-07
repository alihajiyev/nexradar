package com.nexradar.app

import android.app.usage.UsageStatsManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The health report for the whole process, plus the read/write door to the
 * [DiagLog] flight recorder.
 *
 * Nothing here is inferred: every value is asked of the system directly, so the
 * diagnostics screen can tell a driver *why* the bubble is not doing its job
 * instead of guessing. The interesting ones are the silent failures that have no
 * visible symptom — a revoked overlay grant, a disabled notification channel, a
 * missing background-location permission, an OEM battery manager that has put
 * the app into a restricted standby bucket. Each of them looks exactly like "the
 * app is broken" from the driver's seat.
 */
object NexRadarDiagnostics {

    const val CHANNEL = "nexradar/diagnostics"

    private const val TAG = "NexRadarDiagnostics"

    fun wire(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "log" -> {
                            DiagLog.event(
                                app,
                                call.argument<String>("name") ?: "dart",
                                call.argument<String>("detail"),
                            )
                            result.success(null)
                        }

                        "heartbeat" -> {
                            DiagLog.heartbeat(app, call.argument<String>("detail"))
                            result.success(null)
                        }

                        "read" -> result.success(DiagLog.lines(app))

                        "clear" -> {
                            DiagLog.clear(app)
                            result.success(null)
                        }

                        "state" -> result.success(state(app))

                        "openBatterySettings" -> {
                            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                .let { intent -> runCatching { app.startActivity(intent) } }
                            result.success(null)
                        }

                        "openNotificationSettings" -> {
                            val intent =
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                        .putExtra(Settings.EXTRA_APP_PACKAGE, app.packageName)
                                } else {
                                    Intent("android.settings.APP_NOTIFICATION_SETTINGS")
                                        .putExtra("app_package", app.packageName)
                                        .putExtra("app_uid", app.applicationInfo.uid)
                                }
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            runCatching { app.startActivity(intent) }
                            result.success(null)
                        }

                        else -> result.notImplemented()
                    }
                } catch (t: Throwable) {
                    Log.e(TAG, "diagnostics ${call.method} failed", t)
                    result.error("NEXRADAR_ERROR", t.message, null)
                }
            }
    }

    // --------------------------------------------------------------- the report

    private fun state(context: Context): Map<String, Any?> = mapOf(
        // --- the process itself -----------------------------------------------
        "deviceModel" to "${Build.MANUFACTURER} ${Build.MODEL}",
        "androidSdk" to Build.VERSION.SDK_INT,
        "androidRelease" to Build.VERSION.RELEASE,
        "processUptimeMs" to SystemClock.elapsedRealtime(),
        "sessionStartedAt" to System.currentTimeMillis(),

        // --- the two hosts of the bubble --------------------------------------
        "serviceRunning" to RadarOverlayService.isRunning,
        "bubbleAttached" to RadarOverlayService.isBubbleAttached(),
        "lockHudConnected" to NexRadarAccessibilityService.isConnected(),
        "lockHudAttached" to NexRadarAccessibilityService.isBubbleAttached(),
        "host" to when {
            NexRadarAccessibilityService.isBubbleAttached() -> "accessibility"
            RadarOverlayService.isBubbleAttached() -> "overlay"
            else -> "none"
        },

        // --- grants that silently disable the background ----------------------
        "overlayGranted" to Settings.canDrawOverlays(context),
        "lockHudEnabled" to lockHudEnabled(context),
        "notificationsEnabled" to NotificationManagerCompat.from(context).areNotificationsEnabled(),
        "installGranted" to canInstallPackages(context),
        "batteryOptimized" to isBatteryOptimized(context),
        "standbyBucket" to standbyBucket(context),
        "fineLocationGranted" to granted(context, android.Manifest.permission.ACCESS_FINE_LOCATION),
        "backgroundLocationGranted" to granted(
            context,
            android.Manifest.permission.ACCESS_BACKGROUND_LOCATION,
        ),
        "notificationPermissionGranted" to if (Build.VERSION.SDK_INT >= 33) {
            granted(context, android.Manifest.permission.POST_NOTIFICATIONS)
        } else {
            true
        },

        // --- how long ago the pipeline last proved it was alive ---------------
        "lastHeartbeatMs" to DiagLog.lastHeartbeatMs(context),
    )

    // ------------------------------------------------------------------ helpers

    private fun granted(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * True when the driver has switched NexRadar on under Settings →
     * Accessibility. Both switches matter: the per-service grant *and* the
     * master toggle, because an off master toggle keeps the service unbound.
     */
    fun lockHudEnabled(context: Context): Boolean {
        val master = Settings.Secure.getInt(
            context.contentResolver,
            Settings.Secure.ACCESSIBILITY_ENABLED,
            0,
        ) == 1
        if (!master) return false

        val expected = ComponentName(context, NexRadarAccessibilityService::class.java)
        val enabled = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false
        return enabled.split(':')
            .any { it.equals(expected.flattenToString(), ignoreCase = true) }
    }

    fun canInstallPackages(context: Context): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    private fun isBatteryOptimized(context: Context): Boolean {
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            ?: return false
        return !power.isIgnoringBatteryOptimizations(context.packageName)
    }

    /**
     * `5` = `RESTRICTED_BUCKET`, `45` = `NEVER`. Both mean the OEM power manager
     * has decided this app may not run in the background, which no amount of
     * foreground-service code can override.
     */
    private fun standbyBucket(context: Context): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val usage = context.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
            usage?.appStandbyBucket ?: -1
        } else {
            -1
        }

    /** Convenience for the settings deep-link in [NexRadarChannels]. */
    fun overlaySettingsIntent(context: Context): Intent = Intent(
        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
        Uri.parse("package:${context.packageName}"),
    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
}
