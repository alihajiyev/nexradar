package com.nexradar.app

/**
 * Decides which of the two bubble hosts is allowed to draw right now.
 *
 * The rule is simple and deliberately one-directional: when the accessibility
 * host is connected it wins, because its `TYPE_ACCESSIBILITY_OVERLAY` window is
 * the only one that survives the keyguard. The foreground-service host stays
 * alive either way — it owns the notification and keeps the process at foreground
 * priority, which is what stops Android from killing the location stream.
 */
object BubbleHost {

    /** Re-evaluates both hosts. Safe to call from any thread. */
    fun refresh() {
        if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) {
            refreshNow()
        } else {
            android.os.Handler(android.os.Looper.getMainLooper()).post { refreshNow() }
        }
    }

    private fun refreshNow() {
        NexRadarAccessibilityService.instance?.syncWindow()
        RadarOverlayService.instance?.syncWindow()
    }

    /** True when the lock-screen host is live and therefore owns the bubble. */
    fun lockHudOwnsBubble(): Boolean = NexRadarAccessibilityService.instance != null
}
