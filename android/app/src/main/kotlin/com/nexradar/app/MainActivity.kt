package com.nexradar.app

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Flutter host + the native side of the floating bubble.
 *
 * Responsibilities beyond the usual `FlutterActivity`:
 *
 * * **Lock screen.** `setShowWhenLocked(true)` lets the dashboard itself render
 *   over the keyguard. The *bubble* uses a different mechanism: it is hosted by
 *   [NexRadarAccessibilityService], because a `TYPE_APPLICATION_OVERLAY` window
 *   is always hidden once the keyguard is up.
 * * **Platform channels.** `nexradar/overlay` is the control surface
 *   (permissions, show/hide, state push), `nexradar/overlay_events` carries taps
 *   made *on the bubble* back into Dart, and `nexradar/update` drives in-app
 *   updates from GitHub Releases.
 */
class MainActivity : FlutterActivity(), EventChannel.StreamHandler {

    private var methodChannel: MethodChannel? = null
    private var updateChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyLockScreenFlags()
    }

    private fun applyLockScreenFlags() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            // Deliberately *not* setTurnScreenOn(true): waking the panel on every
            // GPS tick would drain the battery. The bubble appears as soon as the
            // driver lights the screen themselves.
            setTurnScreenOn(false)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED)
        }
        // Keep the dashboard readable while it is in the foreground.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).apply {
            setMethodCallHandler { call, result ->
                try {
                    handleMethod(call.method, call.arguments, result)
                } catch (t: Throwable) {
                    Log.e(TAG, "method ${call.method} failed", t)
                    result.error("NEXRADAR_ERROR", t.message, null)
                }
            }
        }

        updateChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            UPDATE_CHANNEL,
        ).apply {
            setMethodCallHandler { call, result ->
                try {
                    handleUpdateMethod(call.method, call.arguments, result)
                } catch (t: Throwable) {
                    Log.e(TAG, "update method ${call.method} failed", t)
                    result.error("NEXRADAR_ERROR", t.message, null)
                }
            }
        }

        eventChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENT_CHANNEL,
        ).apply {
            setStreamHandler(this@MainActivity)
        }
    }

    // ------------------------------------------------------------ in-app update

    /**
     * The self-hosted update path. NexRadar is distributed as a GitHub Release
     * APK, so the Dart side downloads the file from the release and hands the
     * local path back here, where the system installer takes over.
     */
    private fun handleUpdateMethod(method: String, arguments: Any?, result: MethodChannel.Result) {
        when (method) {
            "installedVersion" -> {
                val info = packageManager.getPackageInfo(packageName, 0)
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

            "cacheDir" -> result.success(cacheDir.absolutePath)

            "canInstallPackages" -> result.success(canRequestPackageInstalls())

            "openInstallPermissionSettings" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName"),
                        ),
                    )
                }
                result.success(null)
            }

            "installApk" -> {
                val args = asMap(arguments)
                val path = args["path"] as? String
                if (path.isNullOrBlank()) {
                    result.error("NEXRADAR_ERROR", "path is empty", null)
                    return
                }
                val file = File(path)
                if (!file.exists()) {
                    result.error("NEXRADAR_ERROR", "apk not found at $path", null)
                    return
                }
                if (!canRequestPackageInstalls()) {
                    // Send the driver to the one settings page that unlocks the
                    // system installer, then answer false so Dart can re-check.
                    startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName"),
                        ),
                    )
                    result.success(false)
                    return
                }

                val uri = FileProvider.getUriForFile(
                    this,
                    "$packageName.fileprovider",
                    file,
                )
                val install = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(install)
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    private fun canRequestPackageInstalls(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    private fun handleMethod(method: String, arguments: Any?, result: MethodChannel.Result) {
        when (method) {
            "isPermissionGranted" -> result.success(canOverlay())

            "requestPermission" -> {
                if (canOverlay()) {
                    result.success(true)
                    return
                }
                // The grant cannot be requested with a dialog: Android sends the
                // user to a dedicated settings page, so we answer `false` and let
                // Dart re-check on resume.
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:$packageName"),
                    ),
                )
                result.success(false)
            }

            "show" -> {
                // Either grant can carry the bubble: the overlay permission for
                // the normal window, or the accessibility grant for the window
                // that survives the keyguard.
                if (!canOverlay() && !lockHudEnabled()) {
                    result.success(false)
                    return
                }
                val args = asMap(arguments)
                RadarOverlayService.start(
                    context = this,
                    scale = (args["scale"] as? Number)?.toFloat() ?: 1f,
                    showRemaining = args["showRemaining"] as? Boolean ?: true,
                )
                result.success(true)
            }

            "hide" -> {
                RadarOverlayService.stop(this)
                result.success(true)
            }

            // ------------------------------------------------ lock-screen HUD

            "lockHudEnabled" -> result.success(lockHudEnabled())

            "lockHudActive" -> result.success(NexRadarAccessibilityService.isConnected())

            "openLockHudSettings" -> {
                // Enabling an accessibility service is a user decision by
                // design: Android exposes it only through these settings.
                runCatching {
                    startActivity(
                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                }
                result.success(null)
            }

            "update" -> {
                val payload = asMap(arguments)
                OverlayBus.pendingState = payload
                RadarOverlayService.update(payload)
                result.success(null)
            }

            "setScale" -> {
                val args = asMap(arguments)
                RadarOverlayService.setScale((args["scale"] as? Number)?.toFloat() ?: 1f)
                result.success(null)
            }

            "isRunning" -> result.success(RadarOverlayService.isRunning)

            else -> result.notImplemented()
        }
    }

    private fun canOverlay(): Boolean = Settings.canDrawOverlays(this)

    /**
     * True when the driver has switched NexRadar on under Settings →
     * Accessibility. Both switches matter: the per-service grant and the master
     * toggle, because an off master toggle keeps the service unbound.
     */
    private fun lockHudEnabled(): Boolean {
        val master = Settings.Secure.getInt(
            contentResolver,
            Settings.Secure.ACCESSIBILITY_ENABLED,
            0,
        ) == 1
        if (!master) return false

        val expected = ComponentName(this, NexRadarAccessibilityService::class.java)
        val enabled = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false
        return enabled.split(':')
            .any { it.equals(expected.flattenToString(), ignoreCase = true) }
    }

    private fun asMap(arguments: Any?): Map<String, Any?> {
        val map = arguments as? Map<*, *> ?: return emptyMap()
        return map.entries.associate { (key, value) -> key.toString() to value }
    }

    override fun onResume() {
        super.onResume()
        // The user may be coming back from the "display over other apps" or the
        // accessibility page: re-evaluate both hosts so a fresh grant is used
        // immediately instead of on the next app launch.
        BubbleHost.refresh()
        if (BubbleWindow.isDesired(this) && !RadarOverlayService.isRunning) {
            RadarOverlayService.start(this)
        }
        methodChannel?.invokeMethod("onResumed", canOverlay())
        OverlayBus.emit("lockHud", mapOf("active" to NexRadarAccessibilityService.isConnected()))
    }

    override fun onDestroy() {
        eventChannel?.setStreamHandler(null)
        methodChannel?.setMethodCallHandler(null)
        updateChannel?.setMethodCallHandler(null)
        super.onDestroy()
    }

    // ---------------------------------------------------------- EventChannel

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        OverlayBus.sink = events
    }

    override fun onCancel(arguments: Any?) {
        OverlayBus.sink = null
    }

    companion object {
        private const val TAG = "MainActivity"
        const val CHANNEL = "nexradar/overlay"
        const val EVENT_CHANNEL = "nexradar/overlay_events"
        const val UPDATE_CHANNEL = "nexradar/update"
    }
}
