package com.nexradar.app

import android.content.Context
import android.content.SharedPreferences
import android.graphics.PixelFormat
import android.graphics.Point
import android.os.Build
import android.util.Log
import android.view.Gravity
import android.view.WindowManager
import kotlin.math.abs

/**
 * Owns the floating bubble window and everything that has to agree between its
 * two possible hosts.
 *
 * There are exactly two ways to put a bubble on an Android screen, and NexRadar
 * uses both:
 *
 * | Host | Window type | Shows over the lock screen |
 * |------|-------------|----------------------------|
 * | [RadarOverlayService] | `TYPE_APPLICATION_OVERLAY` | no |
 * | [NexRadarAccessibilityService] | `TYPE_ACCESSIBILITY_OVERLAY` | yes |
 *
 * The window manager hides every window whose policy layer sits below the
 * keyguard host — `TYPE_APPLICATION_OVERLAY` is layer 11, the keyguard host is
 * layer 17 — and the `FLAG_SHOW_WHEN_LOCKED` escape hatch only re-enables a
 * window while the keyguard is already *occluded* by an activity. So an overlay
 * permission alone can never reach the lock screen; the accessibility window
 * (layer 31, above the keyguard and exempt from the keyguard policy) can.
 *
 * Both hosts therefore share this class: one window, one persisted position, one
 * scale, one payload — whichever host is currently active renders it. The
 * window is always exactly the size of the dial; a full-screen overlay would
 * swallow every touch on the phone.
 */
class BubbleWindow(
    private val context: Context,
    private val windowType: Int,
    listener: SpeedBubbleView.Listener,
) {

    private val windowManager =
        context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val prefs: SharedPreferences = prefs(context)

    val view: SpeedBubbleView = SpeedBubbleView(context).apply {
        this.listener = listener
    }

    private var params: WindowManager.LayoutParams? = null

    /** True while the window is on screen. */
    var attached = false
        private set

    var scaleFactor: Float = prefs.getFloat(KEY_SCALE, 1f)
        private set

    private var x = prefs.getInt(KEY_X, UNSET)
    private var y = prefs.getInt(KEY_Y, UNSET)

    init {
        view.scaleFactor = scaleFactor
    }

    // --------------------------------------------------------------- lifecycle

    fun attach() {
        if (attached) return

        val size = view.windowSize
        val screen = screenBounds()
        val startX = if (x == UNSET) screen.x - size - dp(12f).toInt() else x
        val startY = if (y == UNSET) dp(64f).toInt() else y

        val layout = WindowManager.LayoutParams(
            size,
            size,
            windowType,
            FLAGS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            this.x = clamp(startX, 0, screen.x - size)
            this.y = clamp(startY, 0, screen.y - size)
            windowAnimations = 0
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }

        runCatching { windowManager.addView(view, layout) }
            .onFailure {
                Log.e(TAG, "addView failed for $windowType", it)
                return
            }

        params = layout
        x = layout.x
        y = layout.y
        attached = true
    }

    fun detach() {
        if (!attached) return
        runCatching { windowManager.removeView(view) }
        params = null
        attached = false
    }

    // --------------------------------------------------------------- geometry

    /** Moves the window by a drag delta, clamped to the visible screen. */
    fun moveBy(dx: Int, dy: Int) {
        val layout = params ?: return
        val size = view.windowSize
        val screen = screenBounds()
        layout.x = clamp(layout.x + dx, 0, screen.x - size)
        layout.y = clamp(layout.y + dy, 0, screen.y - size)
        runCatching { windowManager.updateViewLayout(view, layout) }
        x = layout.x
        y = layout.y
    }

    /** Resizes the dial, keeping its centre pinned so it does not jump. */
    fun applyScale(scale: Float) {
        val clamped = scale.coerceIn(0.6f, 1.8f)
        if (abs(clamped - scaleFactor) < 0.001f) return

        val oldSize = view.windowSize
        scaleFactor = clamped
        view.scaleFactor = clamped
        prefs.edit().putFloat(KEY_SCALE, clamped).apply()

        val layout = params ?: return
        val newSize = view.windowSize
        val screen = screenBounds()
        val shift = (oldSize - newSize) / 2
        layout.width = newSize
        layout.height = newSize
        layout.x = clamp(layout.x + shift, 0, screen.x - newSize)
        layout.y = clamp(layout.y + shift, 0, screen.y - newSize)
        runCatching { windowManager.updateViewLayout(view, layout) }
        x = layout.x
        y = layout.y
    }

    fun persistPosition() {
        prefs.edit().putInt(KEY_X, x).putInt(KEY_Y, y).apply()
    }

    fun pushState(payload: Map<String, Any?>) {
        view.pushState(payload)
    }

    // ------------------------------------------------------------------ utils

    private fun screenBounds(): Point {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = windowManager.currentWindowMetrics.bounds
            return Point(bounds.width(), bounds.height())
        }
        @Suppress("DEPRECATION")
        val point = Point()
        windowManager.defaultDisplay.getSize(point)
        return point
    }

    private fun dp(value: Float): Float = value * context.resources.displayMetrics.density

    private fun clamp(value: Int, min: Int, max: Int): Int = when {
        max < min -> min
        value < min -> min
        value > max -> max
        else -> value
    }

    companion object {
        private const val TAG = "BubbleWindow"

        private const val PREFS = "nexradar_overlay"
        private const val KEY_X = "x"
        private const val KEY_Y = "y"
        private const val KEY_SCALE = "scale"
        private const val KEY_SHOW_REMAINING = "show_remaining"
        private const val KEY_DESIRED = "desired"

        /** "not placed yet" marker for the persisted position. */
        private const val UNSET = -1

        /**
         * `FLAG_NOT_FOCUSABLE` keeps the bubble out of the input/focus stack, so
         * the app underneath still owns the IME and the back key.
         *
         * `FLAG_SHOW_WHEN_LOCKED` is best-effort only: on AOSP it cannot lift a
         * window above the keyguard (see the class comment), but several OEM
         * window managers honour it anyway, so it stays as a free extra.
         */
        private const val FLAGS =
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED or
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED

        fun prefs(context: Context): SharedPreferences =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        /** True while the driver asked for the bubble (survives restarts). */
        fun isDesired(context: Context): Boolean =
            prefs(context).getBoolean(KEY_DESIRED, false)

        fun setDesired(context: Context, desired: Boolean) {
            prefs(context).edit().putBoolean(KEY_DESIRED, desired).apply()
        }

        fun showRemaining(context: Context): Boolean =
            prefs(context).getBoolean(KEY_SHOW_REMAINING, true)

        fun setShowRemaining(context: Context, value: Boolean) {
            prefs(context).edit().putBoolean(KEY_SHOW_REMAINING, value).apply()
        }
    }
}
