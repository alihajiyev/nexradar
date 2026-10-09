package com.nexradar.app

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Process-wide bridge between the native overlay (which runs in a foreground
 * service, possibly with the Flutter engine paused) and the Dart side.
 *
 * Two directions:
 *  * **Dart → native**: [pendingState] holds the newest payload so a service
 *    that starts *after* the first push still renders the right numbers.
 *  * **native → Dart**: [sink] is the EventChannel sink; everything is posted on
 *    the main looper because `EventSink.success` must be called from the thread
 *    the channel was created on.
 */
object OverlayBus {

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    var sink: EventChannel.EventSink? = null

    /** Latest payload pushed from Dart, replayed to a freshly started service. */
    @Volatile
    var pendingState: Map<String, Any?>? = null

    /** True while the user asked for the bubble (survives service restarts). */
    @Volatile
    var overlayDesired: Boolean = false

    /**
     * Silence mode — the driver muted the warnings on purpose, for a bounded
     * window ("Sükut rejimi").
     *
     * Process-wide because three different actors need the same answer: both
     * bubble hosts render it, the lock-screen media panel prints its countdown,
     * and the diagnostics screen reports it. The *decision* stays in Dart — it is
     * the layer that beeps — and arrives with the payload; a tap on the
     * lock-screen button updates this copy immediately and asks Dart to agree.
     */
    @Volatile
    var silenced: Boolean = false

    /** Epoch millis when the silence window ends, 0 while warnings are live. */
    @Volatile
    var silenceUntilMs: Long = 0L

    /**
     * Adds the silence state to a payload, so a window that renders it never has
     * to know where the value came from.
     *
     * Returns a mutable copy on purpose: the callers add their own keys to it
     * (the service appends the display preferences) and pushing a fresh map keeps
     * the payload Dart sent untouched.
     */
    fun decorated(payload: Map<String, Any?>): HashMap<String, Any?> {
        val merged = HashMap<String, Any?>(payload)
        merged["paused"] = silenced
        merged["pausedUntilMs"] = if (silenced) silenceUntilMs else 0L
        return merged
    }

    fun emit(payload: Map<String, Any?>) {
        mainHandler.post {
            try {
                sink?.success(payload)
            } catch (_: Throwable) {
                // The Flutter engine went away mid-flight; nothing to do.
            }
        }
    }

    fun emit(type: String, extras: Map<String, Any?> = emptyMap()) {
        emit(mapOf("type" to type) + extras)
    }

    /**
     * The overlay asks the Flutter side whether a stop was really requested.
     * Keeping the decision in one place (the service) avoids two sources of
     * truth for [overlayDesired].
     */
    fun requestStop() {
        overlayDesired = false
        emit("dismissed")
    }
}
