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
