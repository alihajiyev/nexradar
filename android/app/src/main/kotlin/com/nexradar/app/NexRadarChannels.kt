package com.nexradar.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * All three platform channels, wired to the **engine** rather than to an
 * activity.
 *
 * That distinction is the whole point: the radar pipeline keeps running with no
 * UI on screen, and Dart still asks for `cacheDir`, `canInstallPackages` or the
 * next overlay `update` while the driver is in another app with the phone
 * locked. Handlers registered by [MainActivity] would vanish the moment the
 * activity was destroyed, leaving the headless engine unable to do anything.
 *
 * Everything here therefore takes an application context. The intents that
 * normally expect an activity (`ACTION_MANAGE_OVERLAY_PERMISSION`,
 * `ACTION_ACCESSIBILITY_SETTINGS`, the package installer) carry
 * `FLAG_ACTIVITY_NEW_TASK` so the system can start them from that context.
 */
object NexRadarChannels {

    const val METHOD = "nexradar/overlay"
    const val EVENT = "nexradar/overlay_events"
    const val UPDATE = "nexradar/update"

    private const val TAG = "NexRadarChannels"

    @Volatile
    private var methodChannel: MethodChannel? = null

    @Volatile
    private var wired = false

    fun wire(engine: FlutterEngine, context: Context) {
        if (wired) return
        synchronized(this) {
            if (wired) return
            val app = context.applicationContext
            val messenger = engine.dartExecutor.binaryMessenger

            val method = MethodChannel(messenger, METHOD).apply {
                setMethodCallHandler { call, result ->
                    try {
                        handleMethod(app, call, result)
                    } catch (t: Throwable) {
                        Log.e(TAG, "method ${call.method} failed", t)
                        result.error("NEXRADAR_ERROR", t.message, null)
                    }
                }
            }

            MethodChannel(messenger, UPDATE).setMethodCallHandler { call, result ->
                try {
                    handleUpdateMethod(app, call, result)
                } catch (t: Throwable) {
                    Log.e(TAG, "update ${call.method} failed", t)
                    result.error("NEXRADAR_ERROR", t.message, null)
                }
            }

            EventChannel(messenger, EVENT).setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                        OverlayBus.sink = events
                    }

                    override fun onCancel(arguments: Any?) {
                        OverlayBus.sink = null
                    }
                },
            )

            methodChannel = method
            wired = true
        }
    }

    /** Tells Dart the UI came back — used to re-read permission grants. */
    fun notifyResumed(context: Context) {
        methodChannel?.invokeMethod("onResumed", canOverlay(context))
    }

    // ------------------------------------------------------------------ overlay

    private fun handleMethod(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "isPermissionGranted" -> result.success(canOverlay(context))

            "requestPermission" -> {
                if (canOverlay(context)) {
                    result.success(true)
                    return
                }
                // The grant cannot be requested with a dialog: Android sends the
                // user to a dedicated settings page, so we answer `false` and let
                // Dart re-check on resume.
                start(context, overlaySettingsIntent(context))
                result.success(false)
            }

            "show" -> {
                // Either grant can carry the bubble: the overlay permission for
                // the normal window, or the accessibility grant for the window
                // that survives the keyguard.
                if (!canOverlay(context) && !lockHudEnabled(context)) {
                    result.success(false)
                    return
                }
                val args = asMap(call.arguments)
                RadarOverlayService.start(
                    context = context,
                    scale = (args["scale"] as? Number)?.toFloat() ?: 1f,
                    showRemaining = args["showRemaining"] as? Boolean ?: true,
                )
                result.success(true)
            }

            "hide" -> {
                RadarOverlayService.stop(context)
                result.success(true)
            }

            "update" -> {
                val payload = asMap(call.arguments)
                OverlayBus.pendingState = payload
                RadarOverlayService.update(payload)
                result.success(null)
            }

            "setScale" -> {
                val args = asMap(call.arguments)
                RadarOverlayService.setScale((args["scale"] as? Number)?.toFloat() ?: 1f)
                result.success(null)
            }

            "isRunning" -> result.success(RadarOverlayService.isRunning)

            // ------------------------------------------------ lock-screen HUD

            "lockHudEnabled" -> result.success(lockHudEnabled(context))

            "lockHudActive" -> result.success(NexRadarAccessibilityService.isConnected())

            "openLockHudSettings" -> {
                // Enabling an accessibility service is a user decision by
                // design: Android exposes it only through these settings.
                start(
                    context,
                    Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------ in-app update

    private fun handleUpdateMethod(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "installedVersion" -> {
                val info = context.packageManager.getPackageInfo(context.packageName, 0)
                result.success(
                    mapOf(
                        "versionName" to (info.versionName ?: "0.0.0"),
                        "versionCode" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                            info.longVersionCode
                        } else {
                            @Suppress("DEPRECATION") info.versionCode.toLong()
                        },
                    ),
                )
            }

            "cacheDir" -> result.success(context.cacheDir.absolutePath)

            "canInstallPackages" -> result.success(canInstallPackages(context))

            "openInstallPermissionSettings" -> {
                start(context, installPermissionIntent(context))
                result.success(null)
            }

            "installApk" -> {
                val path = asMap(call.arguments)["path"] as? String
                if (path.isNullOrBlank()) {
                    result.error("NEXRADAR_ERROR", "path is empty", null)
                    return
                }
                val file = File(path)
                if (!file.exists()) {
                    result.error("NEXRADAR_ERROR", "apk not found at $path", null)
                    return
                }
                if (!canInstallPackages(context)) {
                    // Send the driver to the one settings page that unlocks the
                    // system installer, then answer false so Dart can re-check.
                    start(context, installPermissionIntent(context))
                    result.success(false)
                    return
                }

                val uri = FileProvider.getUriForFile(
                    context,
                    "${context.packageName}.fileprovider",
                    file,
                )
                val install = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                start(context, install)
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------------ helpers

    private fun canOverlay(context: Context): Boolean = Settings.canDrawOverlays(context)

    private fun canInstallPackages(context: Context): Boolean =
        NexRadarDiagnostics.canInstallPackages(context)

    private fun overlaySettingsIntent(context: Context): Intent = Intent(
        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
        Uri.parse("package:${context.packageName}"),
    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    private fun installPermissionIntent(context: Context): Intent = Intent(
        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
        Uri.parse("package:${context.packageName}"),
    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    private fun start(context: Context, intent: Intent) {
        runCatching { context.startActivity(intent) }
            .onFailure { Log.w(TAG, "could not start ${intent.action}", it) }
    }

    /**
     * True when the driver has switched NexRadar on under Settings →
     * Accessibility. Shared with the diagnostics screen so the two can never
     * disagree about the same grant.
     */
    private fun lockHudEnabled(context: Context): Boolean =
        NexRadarDiagnostics.lockHudEnabled(context)

    private fun asMap(arguments: Any?): Map<String, Any?> {
        val map = arguments as? Map<*, *> ?: return emptyMap()
        return map.entries.associate { (key, value) -> key.toString() to value }
    }
}
