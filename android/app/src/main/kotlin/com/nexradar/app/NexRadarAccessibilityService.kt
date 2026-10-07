package com.nexradar.app

import android.accessibilityservice.AccessibilityService
import android.util.Log
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent

/**
 * The lock-screen HUD.
 *
 * This service exists for exactly one reason: **`TYPE_ACCESSIBILITY_OVERLAY` is
 * the only window type a normal app can use that the keyguard does not hide.**
 *
 * The window manager applies a keyguard policy to every window that
 * `WindowState.canBeHiddenByKeyguard()` accepts, which is every window whose
 * policy layer sits below the keyguard host layer (`TYPE_NOTIFICATION_SHADE`,
 * layer 17). `TYPE_APPLICATION_OVERLAY` is layer 11, so the bubble hosted by
 * [RadarOverlayService] disappears the moment the keyguard comes up — no flag
 * changes that. Accessibility overlays sit at layer 31, above the keyguard, and
 * are exempt, so the very same [SpeedBubbleView] renders on the lock screen
 * unchanged.
 *
 * It is opt-in: the driver enables "NexRadar" under Settings → Accessibility (a
 * two-tap, reversible grant), and the app deep-links there. Nothing here reads
 * the screen — [onAccessibilityEvent] is deliberately empty and the service
 * config declares `canRetrieveWindowContent="false"`.
 */
class NexRadarAccessibilityService : AccessibilityService(), SpeedBubbleView.Listener {

    private var window: BubbleWindow? = null

    /** Whether the lock-screen host's own window is on screen right now. */
    @Volatile
    private var bubbleAttached = false

    // --------------------------------------------------------------- lifecycle

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        syncWindow()
        BubbleHost.refresh()
        OverlayBus.emit("lockHud", mapOf("active" to true))
        DiagLog.event(this, "lockHud", "connected")
        Log.i(TAG, "lock-screen host connected")
    }

    /**
     * Re-evaluates the window against the driver's wishes. Called on a connect,
     * a disconnect and every time the bubble is shown/hidden from the app.
     */
    fun syncWindow() {
        if (BubbleWindow.isDesired(this)) attach() else detach()
    }

    private fun attach() {
        if (window != null) return
        val host = BubbleWindow(this, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY, this)
        window = host
        // A host that starts mid-drive must not show a blank dial for a second.
        OverlayBus.pendingState?.let { host.pushState(it) }
        host.attach()
        bubbleAttached = host.attached
        if (host.attached) {
            Log.i(TAG, "bubble attached over the keyguard")
            DiagLog.event(this, "lockHud", "bubble attached over the keyguard")
        } else {
            window = null
            DiagLog.event(this, "lockHud", "window refused")
        }
    }

    private fun detach() {
        window?.detach()
        window = null
        bubbleAttached = false
    }

    /** Feeds a payload into the lock-screen bubble. */
    fun applyPayload(payload: Map<String, Any?>) {
        window?.pushState(payload)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Intentionally empty: the HUD is a canvas, not a reader. Declaring the
        // service is the point, not the events.
    }

    override fun onInterrupt() {
        // Nothing to interrupt.
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        teardown()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        teardown()
        super.onDestroy()
    }

    private fun teardown() {
        detach()
        instance = null
        BubbleHost.refresh()
        OverlayBus.emit("lockHud", mapOf("active" to false))
        DiagLog.event(this, "lockHud", "disconnected")
        Log.i(TAG, "lock-screen host gone")
    }

    // ----------------------------------------------------- SpeedBubbleView taps

    override fun onDragBy(dx: Int, dy: Int) {
        window?.moveBy(dx, dy)
    }

    override fun onDragFinished() {
        window?.persistPosition()
    }

    override fun onScaleCycled(scale: Float) {
        window?.applyScale(scale)
        OverlayBus.emit("doubleTap", mapOf("scale" to scale))
    }

    override fun onReportRequested() {
        OverlayBus.emit("addRadar")
    }

    override fun onTapped() {
        OverlayBus.emit("tapped")
    }

    companion object {
        private const val TAG = "NexRadarLockHud"

        @Volatile
        var instance: NexRadarAccessibilityService? = null
            private set

        /** True while the accessibility host is alive and owns the bubble. */
        fun isConnected(): Boolean = instance != null

        /** True while its own window is drawing — the "host wins" question. */
        fun isBubbleAttached(): Boolean = instance?.bubbleAttached == true
    }
}
