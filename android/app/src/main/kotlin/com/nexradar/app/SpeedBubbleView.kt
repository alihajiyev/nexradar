package com.nexradar.app

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.SweepGradient
import android.graphics.Typeface
import android.view.Choreographer
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * The floating bubble.
 *
 * Two hard-won details shape this class:
 *
 * 1. **The window is full-screen.** `FLAG_SHOW_WHEN_LOCKED` — the flag that lets
 *    a window sit above the keyguard — is documented to apply only to *"the
 *    top-most full-screen window"*. A 124 dp bubble is not full-screen, which is
 *    exactly why the bubble never appeared on the lock screen. The host window is
 *    therefore `MATCH_PARENT` and this view draws the bubble at [bubbleX]/
 *    [bubbleY] inside it.
 * 2. **Touches outside the bubble must fall through.** A full-screen, touchable
 *    overlay would otherwise swallow every tap on the phone. [onTouchEvent]
 *    returns `false` unless the down event landed on the bubble or its "+"
 *    hotspot, which lets the system deliver the gesture to the app underneath.
 *
 * Rendering runs on a [Choreographer] callback so the needle keeps gliding at
 * 60 FPS while the Flutter engine is paused — the normal state of affairs with
 * the screen locked in a pocket.
 */
class SpeedBubbleView(context: Context) : View(context), Choreographer.FrameCallback {

    interface Listener {
        /** Live pixel offset while the user is dragging. */
        fun onDrag(x: Int, y: Int)

        /** Final resting offset — persisted by the service. */
        fun onDragFinished(x: Int, y: Int)

        /** Double tap: cycle between compact and expanded. */
        fun onScaleCycled(scale: Float)

        /** The "+" hotspot was tapped: report a mobile unit here. */
        fun onReportRequested()

        /** A plain single tap (used by the service for haptics/logging). */
        fun onTapped()
    }

    var listener: Listener? = null

    // ------------------------------------------------------------------ state
    private var targetSpeed = 0f
    private var displaySpeed = 0f
    private var status = STATUS_IDLE
    private var limit = -1
    private var distance = -1
    private var bearingDelta = BEARING_UNKNOWN
    private var showRemaining = true
    private var unitLabel = "km/s"
    private var hasFix = true

    /** Bubble top-left inside the full-screen window. */
    var bubbleX = 0
        private set
    var bubbleY = 0
        private set

    /** 1.0 = default size; 0.78 = compact; 1.3 = expanded. */
    var scaleFactor = 1f
        set(value) {
            val clamped = value.coerceIn(0.6f, 1.8f)
            if (abs(clamped - field) > 0.001f) {
                val old = bubbleRect()
                field = clamped
                clampIntoWindow()
                invalidate(old.union(bubbleRect()))
            }
        }

    // -------------------------------------------------------------- animation
    private var lastFrameNanos = 0L
    private var blinkPhase = 0f
    private var animating = false

    // ---------------------------------------------------------------- dragging
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private var dragActive = false
    private var gestureOwned = false
    private var downRawX = 0f
    private var downRawY = 0f
    private var lastTapAt = 0L

    // ------------------------------------------------------------------ paints
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
    }
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.NORMAL)
    }
    private val signPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val signTextPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        color = Color.BLACK
    }
    private val plusPaint = Paint(Paint.ANTI_ALIAS_FLAG)

    /** Scratch rects so per-frame drawing allocates nothing. */
    private val scratch = RectF()

    // ------------------------------------------------------------------- size
    private val baseSizeDp = 136f

    private fun dp(value: Float): Float = value * resources.displayMetrics.density

    /** Side of the bubble in pixels. */
    val pixelSize: Int get() = (dp(baseSizeDp) * scaleFactor).toInt()

    private fun bubbleRect(): Rect {
        val s = pixelSize
        return Rect(bubbleX, bubbleY, bubbleX + s, bubbleY + s)
    }

    // ------------------------------------------------ geometry (unit square)
    private fun centerX(s: Float): Float = s * 0.5f
    private fun centerY(s: Float): Float = s * 0.415f
    private fun radius(s: Float): Float = s * 0.355f

    private fun limitSignCenterX(s: Float): Float = s * 0.175f

    private fun limitSignCenterY(s: Float): Float = s * 0.815f

    private fun limitSignRadius(s: Float): Float = s * 0.115f

    /** Everything the user can grab, in view coordinates. */
    private fun hitsBubble(x: Float, y: Float): Boolean {
        val s = pixelSize.toFloat()
        val cx = bubbleX + centerX(s)
        val cy = bubbleY + centerY(s)
        val r = radius(s) * 1.12f
        if (hypot(x - cx, y - cy) <= r) return true

        val px = bubbleX + plusCenterX(s)
        val py = bubbleY + plusCenterY(s)
        return hypot(x - px, y - py) <= plusRadius(s) * 1.5f
    }

    private fun plusCenterX(s: Float): Float = s * 0.90f

    private fun plusCenterY(s: Float): Float = s * 0.115f

    private fun plusRadius(s: Float): Float = s * 0.105f

    // ------------------------------------------------------------------ layout
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (bubbleX == 0 && bubbleY == 0) {
            // First layout: park it in the upper-right, clear of the status bar.
            bubbleX = (w - pixelSize - dp(12f)).toInt().coerceAtLeast(0)
            bubbleY = dp(64f).toInt()
        }
        clampIntoWindow()
    }

    private fun clampIntoWindow() {
        val s = pixelSize
        val maxX = (width - s).coerceAtLeast(0)
        val maxY = (height - s).coerceAtLeast(0)
        if (bubbleX > maxX) bubbleX = maxX
        if (bubbleY > maxY) bubbleY = maxY
        if (bubbleX < 0) bubbleX = 0
        if (bubbleY < 0) bubbleY = 0
    }

    fun moveTo(x: Int, y: Int) {
        setPositionInternal(x, y)
    }

    private fun setPositionInternal(x: Int, y: Int) {
        val old = bubbleRect()
        bubbleX = x
        bubbleY = y
        clampIntoWindow()
        invalidate(old.union(bubbleRect()))
    }

    // ------------------------------------------------------------------ input

    /** Feeds a decoded payload coming from Dart. */
    fun pushState(payload: Map<String, Any?>) {
        val speed = (payload["speedKmh"] as? Number)?.toFloat()
        if (speed != null) targetSpeed = speed.coerceIn(0f, 320f)

        status = (payload["status"] as? String) ?: STATUS_IDLE
        limit = (payload["limit"] as? Number)?.toInt() ?: -1
        distance = (payload["distanceMeters"] as? Number)?.toInt() ?: -1
        bearingDelta = (payload["bearingDelta"] as? Number)?.toInt() ?: BEARING_UNKNOWN
        showRemaining = payload["showRemaining"] as? Boolean ?: showRemaining
        unitLabel = (payload["unit"] as? String) ?: unitLabel
        hasFix = payload["hasFix"] as? Boolean ?: hasFix

        val fresh = displaySpeed == 0f && targetSpeed > 0f
        if (fresh) displaySpeed = targetSpeed

        startAnimatingIfNeeded()
    }

    /** Jumps the needle without smoothing (first fix after a start/restart). */
    fun snapSpeed(kmh: Float) {
        targetSpeed = kmh
        displaySpeed = kmh
        startAnimatingIfNeeded()
    }

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        if (visibility != VISIBLE) {
            animating = false
            Choreographer.getInstance().removeFrameCallback(this)
        } else {
            startAnimatingIfNeeded()
        }
    }

    // --------------------------------------------------------------- animation

    private fun startAnimatingIfNeeded() {
        if (animating || windowVisibility != VISIBLE) return

        val speedBusy = abs(targetSpeed - displaySpeed) > 0.15f
        if (!speedBusy && status != STATUS_WARNING) {
            displaySpeed = targetSpeed
            invalidate()
            return
        }
        animating = true
        lastFrameNanos = 0L
        Choreographer.getInstance().postFrameCallback(this)
    }

    /**
     * One frame. The exponential filter is identical to the Dart
     * `SpeedInterpolator`, so the bubble and the in-app gauge never disagree.
     */
    override fun doFrame(frameTimeNanos: Long) {
        if (!animating) return

        val dt = if (lastFrameNanos == 0L) 1f / 60f
        else min((frameTimeNanos - lastFrameNanos) / 1_000_000_000f, 0.25f)
        lastFrameNanos = frameTimeNanos

        val tau = 0.42f
        val alpha = 1f - exp(-dt / tau)
        displaySpeed += (targetSpeed - displaySpeed) * alpha

        val settled = abs(targetSpeed - displaySpeed) < 0.05f
        if (settled) displaySpeed = targetSpeed

        blinkPhase = if (status == STATUS_WARNING) {
            (blinkPhase + dt * 1.6f) % 1f
        } else {
            0f
        }

        invalidate(bubbleRect())

        // Keep the loop alive only while something is actually moving: a
        // finished interpolation with no blinking costs zero CPU.
        if (settled && status != STATUS_WARNING) {
            animating = false
            return
        }
        Choreographer.getInstance().postFrameCallback(this)
    }

    override fun onDetachedFromWindow() {
        animating = false
        Choreographer.getInstance().removeFrameCallback(this)
        super.onDetachedFromWindow()
    }

    // ----------------------------------------------------------------- drawing

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        val s = min(pixelSize, min(width, height)).toFloat()
        if (s <= 0) return

        canvas.save()
        canvas.translate(bubbleX.toFloat(), bubbleY.toFloat())

        val cx = centerX(s)
        val cy = centerY(s)
        val r = radius(s)

        val accent = when (status) {
            STATUS_WARNING -> Color.parseColor("#FF4D5E")
            STATUS_APPROACHING -> Color.parseColor("#FFB531")
            else -> Color.parseColor("#31F0A6")
        }
        val idle = status == STATUS_IDLE
        val warn = status == STATUS_WARNING
        val flash = if (warn) 0.35f + 0.65f * abs(sin(blinkPhase * Math.PI.toFloat())) else 1f

        // ---- ambient glow ----------------------------------------------------
        fillPaint.style = Paint.Style.FILL
        fillPaint.shader = RadialGradient(
            cx, cy, r * 1.30f,
            withAlpha(accent, if (idle) 26 else (56 * flash).toInt().coerceIn(24, 96)),
            withAlpha(accent, 0),
            Shader.TileMode.CLAMP,
        )
        canvas.drawCircle(cx, cy, r * 1.30f, fillPaint)

        // ---- glass body ------------------------------------------------------
        fillPaint.shader = RadialGradient(
            cx - r * 0.45f, cy - r * 0.60f, r * 1.9f,
            intArrayOf(
                mix(accent, 0xFF0A1215.toInt(), if (idle) 0.14f else 0.26f),
                0xFF0A1215.toInt(),
                0xFF060B0D.toInt(),
            ),
            floatArrayOf(0f, 0.55f, 1f),
            Shader.TileMode.CLAMP,
        )
        canvas.drawCircle(cx, cy, r, fillPaint)
        fillPaint.shader = null

        ringPaint.strokeWidth = dp(1.2f)
        ringPaint.color = withAlpha(Color.WHITE, 26)
        canvas.drawCircle(cx, cy, r, ringPaint)

        // ---- state ring ------------------------------------------------------
        if (!idle) {
            ringPaint.strokeWidth = dp(2.5f)
            ringPaint.color = withAlpha(accent, if (warn) (90 + 150 * flash).toInt() else 178)
            canvas.drawCircle(cx, cy, r, ringPaint)
        }

        // ---- bezel ticks -----------------------------------------------------
        val tickBase = r * 1.02f
        for (i in 0..27) {
            val major = i % 4 == 0
            val angle = Math.toRadians((135.0 + 270.0 * i / 27.0))
            val inner = tickBase
            val outer = tickBase + r * (if (major) 0.10f else 0.055f)
            ringPaint.strokeWidth = if (major) dp(1.6f) else dp(1.1f)
            ringPaint.color = withAlpha(Color.WHITE, if (major) 70 else 32)
            canvas.drawLine(
                cx + (cos(angle) * inner).toFloat(),
                cy + (sin(angle) * inner).toFloat(),
                cx + (cos(angle) * outer).toFloat(),
                cy + (sin(angle) * outer).toFloat(),
                ringPaint,
            )
        }

        // ---- gauge arc -------------------------------------------------------
        val arcR = r * 0.80f
        val arcRect = RectF(cx - arcR, cy - arcR, cx + arcR, cy + arcR)
        val stroke = r * 0.155f
        val startAngle = 135f
        val sweepTotal = 270f

        ringPaint.strokeWidth = stroke
        ringPaint.color = withAlpha(Color.WHITE, 28)
        canvas.drawArc(arcRect, startAngle, sweepTotal, false, ringPaint)

        val shownSpeed = if (unitLabel == "mph") displaySpeed / 1.609344f else displaySpeed
        val referenceLimit = if (limit > 0) {
            if (unitLabel == "mph") limit / 1.609344f else limit.toFloat()
        } else {
            0f
        }
        val ceiling = if (referenceLimit > 0f) {
            maxOf(referenceLimit * 1.25f, if (unitLabel == "mph") 75f else 120f)
        } else {
            if (unitLabel == "mph") 100f else 160f
        }
        val fraction = (shownSpeed / ceiling).coerceIn(0f, 1f)

        if (fraction > 0.001f) {
            val gradient = SweepGradient(
                cx, cy,
                intArrayOf(mix(accent, 0xFF17242A.toInt(), 0.55f), withAlpha(accent, 217), accent),
                floatArrayOf(0f, 0.55f, 1f),
            )
            Matrix().also {
                it.setRotate(startAngle, cx, cy)
                gradient.setLocalMatrix(it)
            }
            ringPaint.shader = gradient
            // Soft halo pass first (no blur filter: cheap and looks the same).
            canvas.drawArc(arcRect, startAngle, sweepTotal * fraction, false,
                Paint(ringPaint).apply {
                    shader = null
                    strokeWidth = stroke * 1.9f
                    color = withAlpha(accent, if (warn) 51 else 31)
                })
            canvas.drawArc(arcRect, startAngle, sweepTotal * fraction, false, ringPaint)
            ringPaint.shader = null

            val headAngle = Math.toRadians((startAngle + sweepTotal * fraction).toDouble())
            val hx = cx + (cos(headAngle) * arcR).toFloat()
            val hy = cy + (sin(headAngle) * arcR).toFloat()
            fillPaint.color = withAlpha(accent, 77)
            canvas.drawCircle(hx, hy, stroke * 0.62f, fillPaint)
            fillPaint.color = withAlpha(Color.WHITE, 235)
            canvas.drawCircle(hx, hy, stroke * 0.40f, fillPaint)
        }

        // ---- limit marker ----------------------------------------------------
        if (referenceLimit > 0f) {
            val limitFraction = (referenceLimit / ceiling).coerceIn(0f, 1f)
            val angle = Math.toRadians((startAngle + sweepTotal * limitFraction).toDouble())
            val dirX = cos(angle).toFloat()
            val dirY = sin(angle).toFloat()
            val inner = arcR - stroke * 0.72f
            val outer = arcR + stroke * 0.72f
            ringPaint.strokeWidth = dp(2.6f)
            ringPaint.color = withAlpha(Color.WHITE, 230)
            canvas.drawLine(cx + dirX * inner, cy + dirY * inner, cx + dirX * outer, cy + dirY * outer, ringPaint)
        }

        // ---- bearing blip ----------------------------------------------------
        // Where the radar sits relative to the car's nose: 0° = straight up.
        if (bearingDelta != BEARING_UNKNOWN && distance >= 0) {
            val angle = Math.toRadians((bearingDelta - 90).toDouble())
            val bx = cx + (cos(angle) * (r * 1.16f)).toFloat()
            val by = cy + (sin(angle) * (r * 1.16f)).toFloat()
            fillPaint.color = withAlpha(Color.parseColor("#060B0D"), 220)
            canvas.drawCircle(bx, by, r * 0.088f, fillPaint)
            fillPaint.color = withAlpha(accent, 235)
            canvas.drawCircle(bx, by, r * 0.068f, fillPaint)
        }

        // ---- speed number ----------------------------------------------------
        textPaint.color = if (hasFix) Color.WHITE else withAlpha(Color.WHITE, 110)
        textPaint.textSize = r * 0.86f
        val speedText = shownSpeed.roundToInt().toString()
        val speedOffset = (textPaint.descent() + textPaint.ascent()) / 2f
        canvas.drawText(speedText, cx, cy - speedOffset - r * 0.05f, textPaint)

        labelPaint.color = Color.parseColor("#8FA0A6")
        labelPaint.textSize = r * 0.25f
        labelPaint.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        val unitOffset = (labelPaint.descent() + labelPaint.ascent()) / 2f
        canvas.drawText(unitLabel, cx, cy + r * 0.52f - unitOffset, labelPaint)

        // ---- limit sign ------------------------------------------------------
        val hasLimit = limit > 0
        if (hasLimit) {
            val sx = limitSignCenterX(s)
            val sy = limitSignCenterY(s)
            val sr = limitSignRadius(s)
            fillPaint.color = withAlpha(Color.WHITE, 242)
            canvas.drawCircle(sx, sy, sr, fillPaint)
            ringPaint.strokeWidth = sr * 0.30f
            ringPaint.color = Color.parseColor("#E12B3A")
            canvas.drawCircle(sx, sy, sr - sr * 0.15f, ringPaint)
            signTextPaint.color = Color.parseColor("#10171A")
            val limitText = if (unitLabel == "mph") (limit / 1.609344f).roundToInt().toString() else limit.toString()
            signTextPaint.textSize = if (limitText.length > 2) sr * 0.88f else sr * 1.12f
            val signOffset = (signTextPaint.descent() + signTextPaint.ascent()) / 2f
            canvas.drawText(limitText, sx, sy - signOffset, signTextPaint)
        }

        // ---- distance chip ---------------------------------------------------
        val chipTop = s * 0.715f
        val chipBottom = s * 0.915f
        val chipLeft = if (hasLimit) s * 0.335f else s * 0.05f
        val chipRight = s * 0.955f
        scratch.set(chipLeft, chipTop, chipRight, chipBottom)
        val chipRadius = (chipBottom - chipTop) / 2f

        fillPaint.color = if (idle) withAlpha(0xFF17242A.toInt(), 235) else withAlpha(accent, 62)
        canvas.drawRoundRect(scratch, chipRadius, chipRadius, fillPaint)
        ringPaint.strokeWidth = dp(1f)
        ringPaint.color = if (idle) withAlpha(Color.WHITE, 22) else withAlpha(accent, 120)
        canvas.drawRoundRect(scratch, chipRadius, chipRadius, ringPaint)

        labelPaint.color = if (idle) Color.parseColor("#9BABB0") else Color.WHITE
        labelPaint.textSize = (chipBottom - chipTop) * 0.44f
        labelPaint.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        val chipText = distanceText()
        val chipCenterY = (chipTop + chipBottom) / 2f -
            (labelPaint.descent() + labelPaint.ascent()) / 2f
        canvas.drawText(chipText, (chipLeft + chipRight) / 2f, chipCenterY, labelPaint)

        // ---- "+ report radar" hotspot ----------------------------------------
        val pcx = plusCenterX(s)
        val pcy = plusCenterY(s)
        val pr = plusRadius(s)
        fillPaint.shader = LinearGradient(
            pcx - pr, pcy - pr, pcx + pr, pcy + pr,
            Color.parseColor("#31F0A6"), Color.parseColor("#0EBE7C"),
            Shader.TileMode.CLAMP,
        )
        canvas.drawCircle(pcx, pcy, pr, fillPaint)
        fillPaint.shader = null
        textPaint.color = Color.parseColor("#032014")
        textPaint.textSize = pr * 1.35f
        val plusOffset = (textPaint.descent() + textPaint.ascent()) / 2f
        canvas.drawText("+", pcx, pcy - plusOffset, textPaint)

        canvas.restore()
    }

    /** "3.2 km" / "320 m" / the unit when the horizon is empty. */
    private fun distanceText(): String {
        if (distance < 0) return if (unitLabel == "mph") "MPH" else "KM/S"
        if (!showRemaining && limit > 0) return if (unitLabel == "mph") "MPH" else "KM/S"
        return if (distance >= 1000) {
            String.format("%.1f km", distance / 1000f)
        } else {
            "$distance m"
        }
    }

    private fun mix(color: Int, other: Int, t: Float): Int =
        Color.rgb(
            (Color.red(color) * t + Color.red(other) * (1 - t)).toInt().coerceIn(0, 255),
            (Color.green(color) * t + Color.green(other) * (1 - t)).toInt().coerceIn(0, 255),
            (Color.blue(color) * t + Color.blue(other) * (1 - t)).toInt().coerceIn(0, 255),
        )

    private fun withAlpha(color: Int, alpha: Int): Int =
        Color.argb(
            alpha.coerceIn(0, 255),
            Color.red(color),
            Color.green(color),
            Color.blue(color),
        )

    // ------------------------------------------------------------------ touches

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                // Anything outside the bubble belongs to the app underneath —
                // remember that the window is full-screen.
                if (!hitsBubble(event.x, event.y)) {
                    gestureOwned = false
                    return false
                }
                gestureOwned = true
                dragActive = false
                downRawX = event.rawX
                downRawY = event.rawY
                return true
            }

            MotionEvent.ACTION_MOVE -> {
                if (!gestureOwned) return false
                val dx = event.rawX - downRawX
                val dy = event.rawY - downRawY
                if (!dragActive && (abs(dx) > touchSlop || abs(dy) > touchSlop)) {
                    dragActive = true
                }
                if (dragActive) {
                    setPositionInternal(bubbleX + dx.toInt(), bubbleY + dy.toInt())
                    downRawX = event.rawX
                    downRawY = event.rawY
                }
                return true
            }

            MotionEvent.ACTION_UP -> {
                if (!gestureOwned) return false
                gestureOwned = false
                if (dragActive) {
                    dragActive = false
                    listener?.onDragFinished(bubbleX, bubbleY)
                    return true
                }
                handleTap(event.x, event.y)
                return true
            }

            MotionEvent.ACTION_CANCEL -> {
                gestureOwned = false
                dragActive = false
                return true
            }
        }
        return false
    }

    private fun handleTap(x: Float, y: Float) {
        val s = pixelSize.toFloat()
        val pcx = bubbleX + plusCenterX(s)
        val pcy = bubbleY + plusCenterY(s)
        if (hypot(x - pcx, y - pcy) <= plusRadius(s) * 1.6f) {
            listener?.onReportRequested()
            return
        }

        val now = System.currentTimeMillis()
        if (now - lastTapAt <= 320L) {
            lastTapAt = 0L
            val next = when {
                scaleFactor < 0.9f -> 1f
                scaleFactor < 1.15f -> 1.3f
                else -> 0.78f
            }
            listener?.onScaleCycled(next)
            return
        }
        lastTapAt = now
        listener?.onTapped()
    }

    companion object {
        const val STATUS_IDLE = "idle"
        const val STATUS_APPROACHING = "approaching"
        const val STATUS_WARNING = "warning"

        /** Sentinel for "we do not know where the radar is yet". */
        const val BEARING_UNKNOWN = -999
    }
}
