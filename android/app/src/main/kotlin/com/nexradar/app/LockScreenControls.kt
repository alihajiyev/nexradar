package com.nexradar.app

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.SweepGradient
import android.graphics.Typeface
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Bundle
import android.os.SystemClock
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * The lock-screen panel.
 *
 * A plain ongoing notification is not enough on the lock screen: the driver
 * cannot *act* on it, and on several ROMs it is filtered out entirely by the
 * "hide notifications on the lock screen" setting. The surface a phone always
 * shows, and always lets the user act on, is the **media player** — the one
 * Spotify and every navigation app use to put their current state in front of
 * the keyguard.
 *
 * That surface is produced by two things, and this class owns both:
 *
 * 1. **A [MediaSession]** with live [MediaMetadata] and [PlaybackState]. The
 *    metadata is what the lock screen *prints*: the title is the current speed,
 *    the artist line is the limit and the distance to the next radar, and the
 *    album artwork is a bitmap of the speed dial — so the driver reads the same
 *    numbers on the keyguard that the bubble shows.
 * 2. **A `Notification.MediaStyle`** carrying that session's token. SystemUI
 *    links the two through `EXTRA_MEDIA_SESSION`, promotes the notification into
 *    the media player, and — this is the point of the whole exercise — renders
 *    its controls on the lock screen.
 *
 * No extra dependency is involved: `android.media.session.*`,
 * `Notification.MediaStyle`, `MediaMetadata` and `PlaybackState` are all
 * platform APIs well below our `minSdk` of 26, so the media panel works on every
 * device NexRadar installs on.
 *
 * ## What the buttons do
 *
 * SystemUI derives the button set from the session (see the platform docs: slot 1
 * comes from the [PlaybackState] state, slots 2 and 3 from the actions):
 *
 * | Slot | Icon | Action here |
 * |------|------|-------------|
 * | 1 | play / pause | **Sükut rejimi** — mute the beeps and announcements for a bounded window |
 * | 2 | previous | **Səs** — switch the voice guidance off/on |
 * | 3 | next | **Radar bildir** — report a radar at the current spot |
 * | overflow | stop | **Dayandır** — shut the bubble down |
 *
 * The pause slot is deliberately the *first* one: it is the only control a driver
 * reaches for while moving, and pausing warnings is exactly what a pause button
 * is expected to mean.
 *
 * ## Who owns the state
 *
 * Not this class. The pause flag lives in Dart (see `WarningSilence`), because
 * Dart is what actually makes the noise — the announcements and the beeps come
 * out of the radar engine. So a tap here is a *request*: [Actions] forwards it,
 * Dart applies it and pushes the effective value back with the next state
 * payload. The local flag is flipped optimistically so the button reacts in the
 * same frame the finger touched it, and the authoritative value lands a moment
 * later.
 */
class LockScreenControls(
    private val context: Context,
    private val actions: Actions,
) {

    /** Everything the driver can ask for from the lock screen. */
    interface Actions {
        /** Slot 1, pause: mute warnings for the silence window. */
        fun onPauseRequested()

        /** Slot 1, play: lift the silence now. */
        fun onResumeRequested()

        /** Slot 2: voice guidance off/on. */
        fun onToggleVoiceRequested()

        /** Slot 3: report a radar where the car is right now. */
        fun onReportRequested()

        /** Overflow / `onStop`: shut the bubble and the pipeline down. */
        fun onStopRequested()
    }

    /**
     * Everything the panel prints, already converted to display units by the
     * service — this class does no unit maths of its own, so the lock screen and
     * the bubble can never disagree about what "60" means.
     */
    data class Snapshot(
        /** `78 km/s`, `⚠ 78 km/s`, `NexRadar aktivdir`. */
        val title: String,
        /** `Limit 60 · Radar 340 m` or the silence countdown. */
        val detail: String,
        /** Short text for Android 16's ongoing-activity chip. */
        val shortText: String,
        val unit: String,
        /** Shown speed, in [unit]. */
        val speed: Int,
        /** Shown limit, or -1 when unknown. */
        val limit: Int,
        /** Metres to the nearest forward radar, or -1. */
        val distanceMeters: Int,
        /** `idle` | `approaching` | `warning`. */
        val status: String,
        /** True while the silence window is running. */
        val silenced: Boolean,
        /** Seconds left of the silence window, 0 when not silenced. */
        val silenceRemainingSeconds: Int,
    )

    @Volatile
    private var session: MediaSession? = null

    /** True while the media panel is published (used by diagnostics). */
    @Volatile
    var isActive: Boolean = false
        private set

    /**
     * The artwork of the currently published metadata, so the service can reuse
     * it as the notification's large icon instead of drawing a second bitmap.
     */
    @Volatile
    var artwork: Bitmap? = null
        private set

    private var artworkKey = ""
    private var stateKey = ""
    private var lastPushAt = 0L

    private val callback = object : MediaSession.Callback() {
        override fun onPlay() = actions.onResumeRequested()

        override fun onPause() = actions.onPauseRequested()

        override fun onSkipToPrevious() = actions.onToggleVoiceRequested()

        override fun onSkipToNext() = actions.onReportRequested()

        override fun onStop() = actions.onStopRequested()

        // The platform annotates `action` as non-null, so the override must
        // declare it non-null too — `String?` here does not compile.
        override fun onCustomAction(action: String, extras: Bundle?) {
            if (action == ACTION_STOP) actions.onStopRequested()
        }
    }

    // ---------------------------------------------------------------- lifecycle

    /**
     * Publishes the panel. [sessionActivity] is the "tap the card" intent; the
     * platform requires it to launch an activity.
     */
    fun start(sessionActivity: PendingIntent) {
        if (session != null) return
        val created = MediaSession(context, TAG)
        created.setSessionActivity(sessionActivity)
        created.setCallback(callback)
        val empty = Snapshot(
            title = "NexRadar aktivdir",
            // Until the first payload arrives there is no speed and no radar to
            // report, and the only truthful thing left to say is the one a driver
            // can act on: the phone has no fix yet.
            detail = "GPS gözlənilir",
            shortText = "",
            unit = "km/s",
            speed = 0,
            limit = -1,
            distanceMeters = -1,
            status = "idle",
            silenced = false,
            silenceRemainingSeconds = 0,
        )
        created.setMetadata(metadataFor(empty))
        created.setPlaybackState(playbackStateFor(empty))
        // An inactive session is ignored by SystemUI: nothing would appear on the
        // lock screen at all.
        created.isActive = true
        session = created
        isActive = true
    }

    fun stop() {
        val current = session
        session = null
        isActive = false
        artwork = null
        artworkKey = ""
        stateKey = ""
        lastPushAt = 0L
        runCatching {
            current?.isActive = false
            current?.release()
        }
    }

    /** The style the service attaches to its notification builder. */
    fun styleFor(): Notification.MediaStyle {
        val style = Notification.MediaStyle().setShowActionsInCompactView(0, 1, 2)
        session?.sessionToken?.let { style.setMediaSession(it) }
        return style
    }

    // ------------------------------------------------------------------ updates

    /**
     * Publishes a new snapshot.
     *
     * Throttled on purpose: the whole metadata (artwork included) is parceled to
     * SystemUI on every call, so a 1 Hz state stream must not turn into a 1 MB/s
     * stream of identical bitmaps. Only a change of the *printed* values, or a
     * full second of drift, triggers a push.
     */
    fun update(snapshot: Snapshot) {
        val session = session ?: return

        val key = "${snapshot.title}|${snapshot.detail}|${snapshot.silenced}|" +
            "${snapshot.status}|${snapshot.speed}|${snapshot.limit}|${snapshot.unit}"
        val now = SystemClock.elapsedRealtime()
        val changed = key != stateKey
        if (!changed && now - lastPushAt < REPEAT_INTERVAL_MS) return
        stateKey = key
        lastPushAt = now

        runCatching {
            session.setMetadata(metadataFor(snapshot))
            session.setPlaybackState(playbackStateFor(snapshot))
        }
    }

    /** Re-applies the previous snapshot, e.g. after a channel change. */
    fun refresh() {
        stateKey = ""
        lastPushAt = 0L
    }

    // ----------------------------------------------------------------- metadata

    private fun metadataFor(snapshot: Snapshot): MediaMetadata =
        MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, snapshot.title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, snapshot.detail)
            .putString(MediaMetadata.METADATA_KEY_ALBUM, "NexRadar")
            // The card's artwork is the speed dial itself, so the numbers are
            // readable from the keyguard even where SystemUI only prints one line.
            .putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, artworkFor(snapshot))
            .build()

    /**
     * Slot 1 is derived from the state, so "playing" must mean "warnings are
     * live" and "paused" must mean "silenced" — otherwise the button would lie.
     */
    private fun playbackStateFor(snapshot: Snapshot): PlaybackState {
        val actions = PlaybackState.ACTION_PLAY_PAUSE or
            PlaybackState.ACTION_SKIP_TO_PREVIOUS or
            PlaybackState.ACTION_SKIP_TO_NEXT
        return PlaybackState.Builder()
            .setActions(actions)
            .setState(
                if (snapshot.silenced) PlaybackState.STATE_PAUSED
                else PlaybackState.STATE_PLAYING,
                0L,
                if (snapshot.silenced) 0f else 1f,
            )
            // Custom actions land in the overflow slots of the media carousel.
            .addCustomAction(
                PlaybackState.CustomAction.Builder(
                    ACTION_STOP,
                    "Radarı dayandır",
                    R.drawable.ic_nexradar_stop,
                ).build(),
            )
            .build()
    }

    // ------------------------------------------------------------------ artwork

    private fun artworkFor(snapshot: Snapshot): Bitmap {
        val key = "${snapshot.speed}|${snapshot.limit}|${snapshot.status}|" +
            "${snapshot.silenced}|${snapshot.unit}"
        artwork?.let { existing -> if (key == artworkKey) return existing }

        val bitmap = drawDial(snapshot)
        artwork = bitmap
        artworkKey = key
        return bitmap
    }

    /**
     * The album art: the same dial the floating bubble draws, rasterised to
     * [ART_SIZE] px. Redrawn only when a printed number changes, never per frame.
     */
    private fun drawDial(snapshot: Snapshot): Bitmap {
        val size = ART_SIZE
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val s = size.toFloat()

        val accent = when {
            snapshot.silenced -> SILENCE_COLOR
            snapshot.status == "warning" -> WARNING_COLOR
            snapshot.status == "approaching" -> APPROACH_COLOR
            else -> ACCENT_COLOR
        }
        val idle = snapshot.status == "idle" && !snapshot.silenced

        val cx = s * 0.5f
        val cy = s * 0.42f
        val r = s * 0.355f

        val fill = Paint(Paint.ANTI_ALIAS_FLAG)
        val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
        }

        // ---- background ------------------------------------------------------
        fill.color = Color.parseColor("#070C0E")
        canvas.drawRect(0f, 0f, s, s, fill)

        fill.shader = RadialGradient(
            cx, cy, r * 1.45f,
            withAlpha(accent, if (idle) 34 else 74),
            Color.parseColor("#070C0E"),
            Shader.TileMode.CLAMP,
        )
        canvas.drawRect(0f, 0f, s, s, fill)
        fill.shader = null

        // ---- dial body -------------------------------------------------------
        fill.shader = RadialGradient(
            cx - r * 0.45f, cy - r * 0.60f, r * 1.9f,
            intArrayOf(
                mix(accent, Color.parseColor("#0A1215"), if (idle) 0.14f else 0.26f),
                Color.parseColor("#0A1215"),
                Color.parseColor("#060B0D"),
            ),
            floatArrayOf(0f, 0.55f, 1f),
            Shader.TileMode.CLAMP,
        )
        canvas.drawCircle(cx, cy, r, fill)
        fill.shader = null

        ring.strokeWidth = s * 0.006f
        ring.color = withAlpha(Color.WHITE, 30)
        canvas.drawCircle(cx, cy, r, ring)

        // ---- gauge arc -------------------------------------------------------
        val arcR = r * 0.80f
        val stroke = r * 0.155f
        val arcRect = RectF(cx - arcR, cy - arcR, cx + arcR, cy + arcR)
        val startAngle = 135f
        val sweepTotal = 270f

        ring.strokeWidth = stroke
        ring.color = withAlpha(Color.WHITE, 30)
        canvas.drawArc(arcRect, startAngle, sweepTotal, false, ring)

        val ceiling = when {
            snapshot.limit > 0 ->
                maxOf(snapshot.limit * 1.25f, if (snapshot.unit == "mph") 75f else 120f)
            snapshot.unit == "mph" -> 100f
            else -> 160f
        }
        val fraction = (snapshot.speed / ceiling).coerceIn(0f, 1f)
        if (fraction > 0.001f) {
            val sweep = SweepGradient(
                cx, cy,
                intArrayOf(mix(accent, Color.parseColor("#17242A"), 0.55f), accent, accent),
                floatArrayOf(0f, 0.55f, 1f),
            )
            Matrix().also {
                it.setRotate(startAngle, cx, cy)
                sweep.setLocalMatrix(it)
            }
            ring.shader = sweep
            canvas.drawArc(arcRect, startAngle, sweepTotal * fraction, false, ring)
            ring.shader = null

            val head = Math.toRadians((startAngle + sweepTotal * fraction).toDouble())
            val hx = cx + (cos(head) * arcR).toFloat()
            val hy = cy + (sin(head) * arcR).toFloat()
            fill.color = withAlpha(Color.WHITE, 235)
            canvas.drawCircle(hx, hy, stroke * 0.42f, fill)
        }

        // ---- limit marker ----------------------------------------------------
        if (snapshot.limit > 0) {
            val limitFraction = (snapshot.limit / ceiling).coerceIn(0f, 1f)
            val angle = Math.toRadians((startAngle + sweepTotal * limitFraction).toDouble())
            val dirX = cos(angle).toFloat()
            val dirY = sin(angle).toFloat()
            val inner = arcR - stroke * 0.72f
            val outer = arcR + stroke * 0.72f
            ring.strokeWidth = s * 0.011f
            ring.color = withAlpha(Color.WHITE, 230)
            canvas.drawLine(
                cx + dirX * inner, cy + dirY * inner,
                cx + dirX * outer, cy + dirY * outer,
                ring,
            )
        }

        // ---- speed + unit ----------------------------------------------------
        val number = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textAlign = Paint.Align.CENTER
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            color = Color.WHITE
            textSize = r * 0.86f
        }
        val offset = (number.descent() + number.ascent()) / 2f
        canvas.drawText(
            snapshot.speed.toString(),
            cx, cy - offset - r * 0.05f, number,
        )

        val label = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textAlign = Paint.Align.CENTER
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            textSize = r * 0.25f
        }

        // ---- limit sign ------------------------------------------------------
        val hasLimit = snapshot.limit > 0
        val signX = s * 0.175f
        val signY = s * 0.815f
        val signR = s * 0.115f
        if (hasLimit) {
            fill.color = withAlpha(Color.WHITE, 242)
            canvas.drawCircle(signX, signY, signR, fill)
            ring.strokeWidth = signR * 0.30f
            ring.color = Color.parseColor("#E12B3A")
            canvas.drawCircle(signX, signY, signR - signR * 0.15f, ring)

            val signText = snapshot.limit.toString()
            val sign = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                textAlign = Paint.Align.CENTER
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                color = Color.parseColor("#10171A")
                textSize = if (signText.length > 2) signR * 0.88f else signR * 1.12f
            }
            val signOffset = (sign.descent() + sign.ascent()) / 2f
            canvas.drawText(signText, signX, signY - signOffset, sign)
        }

        // ---- status chip -----------------------------------------------------
        val chipTop = s * 0.715f
        val chipBottom = s * 0.915f
        val chipLeft = if (hasLimit) s * 0.335f else s * 0.05f
        val chipRight = s * 0.955f
        val chipRect = RectF(chipLeft, chipTop, chipRight, chipBottom)
        val chipRadius = (chipBottom - chipTop) / 2f

        fill.color = if (idle) withAlpha(Color.parseColor("#17242A"), 235)
        else withAlpha(accent, 62)
        canvas.drawRoundRect(chipRect, chipRadius, chipRadius, fill)
        ring.strokeWidth = s * 0.004f
        ring.color = if (idle) withAlpha(Color.WHITE, 22) else withAlpha(accent, 120)
        canvas.drawRoundRect(chipRect, chipRadius, chipRadius, ring)

        label.color = if (idle) Color.parseColor("#9BABB0") else Color.WHITE
        label.textSize = (chipBottom - chipTop) * 0.44f
        val chipText = when {
            snapshot.silenced ->
                if (snapshot.silenceRemainingSeconds > 0) {
                    "SÜKUT " + clock(snapshot.silenceRemainingSeconds)
                } else {
                    "SÜKUT"
                }
            snapshot.distanceMeters < 0 -> if (snapshot.unit == "mph") "MPH" else "KM/S"
            snapshot.distanceMeters >= 1000 ->
                String.format("%.1f km", snapshot.distanceMeters / 1000f)
            else -> "${snapshot.distanceMeters} m"
        }
        val chipOffset = (label.descent() + label.ascent()) / 2f
        canvas.drawText(
            chipText,
            (chipLeft + chipRight) / 2f,
            (chipTop + chipBottom) / 2f - chipOffset,
            label,
        )

        // ---- unit under the number -------------------------------------------
        label.color = Color.parseColor("#8FA0A6")
        label.textSize = r * 0.25f
        canvas.drawText(
            if (snapshot.silenced) "SÜKUT" else snapshot.unit,
            cx, cy + r * 0.52f - (label.descent() + label.ascent()) / 2f, label,
        )

        return bitmap
    }

    private fun clock(seconds: Int): String {
        val safe = seconds.coerceAtLeast(0)
        return "${safe / 60}:${(safe % 60).toString().padStart(2, '0')}"
    }

    private fun mix(color: Int, other: Int, t: Float): Int =
        Color.rgb(
            (Color.red(color) * t + Color.red(other) * (1 - t)).roundToInt().coerceIn(0, 255),
            (Color.green(color) * t + Color.green(other) * (1 - t)).roundToInt().coerceIn(0, 255),
            (Color.blue(color) * t + Color.blue(other) * (1 - t)).roundToInt().coerceIn(0, 255),
        )

    private fun withAlpha(color: Int, alpha: Int): Int =
        Color.argb(
            alpha.coerceIn(0, 255),
            Color.red(color),
            Color.green(color),
            Color.blue(color),
        )

    companion object {
        private const val TAG = "NexRadarLockScreen"

        /** Custom action id for the overflow "stop" button. */
        const val ACTION_STOP = "com.nexradar.app.MEDIA_STOP"

        /** 256 px keeps the artwork under 256 KB per metadata push. */
        private const val ART_SIZE = 256

        /** Never push identical metadata more often than this. */
        private const val REPEAT_INTERVAL_MS = 1000L

        private val ACCENT_COLOR = Color.parseColor("#31F0A6")
        private val APPROACH_COLOR = Color.parseColor("#FFB531")
        private val WARNING_COLOR = Color.parseColor("#FF4D5E")
        private val SILENCE_COLOR = Color.parseColor("#7C8B93")
    }
}
