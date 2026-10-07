package com.nexradar.app

import android.content.Context
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * The dashboard's host — and deliberately *not* the engine's owner.
 *
 * NexRadar has to keep working with no UI on screen, so the Dart isolate lives
 * in the engine owned by [NexRadarApplication] and this activity merely attaches
 * a view to it. Two consequences worth spelling out:
 *
 * * the platform channels are wired in [NexRadarChannels] against the engine, not
 *   here, so they survive this activity being destroyed;
 * * `shouldDestroyEngineWithHost()` stays `false`, which is already the default
 *   for a host-provided engine. Without that, swiping NexRadar out of the recents
 *   list would tear down the isolate and leave the floating bubble on screen as a
 *   frozen widget — the bug that made the whole background feature useless.
 *
 * `setShowWhenLocked(true)` lets the dashboard itself render over the keyguard.
 * The *bubble* uses a different mechanism: it is hosted by
 * [NexRadarAccessibilityService], because a `TYPE_APPLICATION_OVERLAY` window is
 * always hidden once the keyguard is up.
 */
class MainActivity : FlutterActivity() {

    override fun provideFlutterEngine(context: Context): FlutterEngine =
        NexRadarApplication.of(context).flutterEngine()

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyLockScreenFlags()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Nothing to wire: the engine and its channels were created in
        // NexRadarApplication, which is where they outlive this activity.
        super.configureFlutterEngine(flutterEngine)
        Log.i(TAG, "dashboard attached to the shared engine")
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

    override fun onResume() {
        super.onResume()
        // The user may be coming back from the "display over other apps" or the
        // accessibility page: re-evaluate both hosts so a fresh grant is used
        // immediately instead of on the next app launch.
        BubbleHost.refresh()
        if (BubbleWindow.isDesired(this) && !RadarOverlayService.isRunning) {
            RadarOverlayService.start(this)
        }
        NexRadarChannels.notifyResumed(this)
        OverlayBus.emit("lockHud", mapOf("active" to NexRadarAccessibilityService.isConnected()))
    }

    companion object {
        private const val TAG = "MainActivity"
    }
}
