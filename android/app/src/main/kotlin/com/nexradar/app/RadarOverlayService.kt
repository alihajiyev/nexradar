package com.nexradar.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import kotlin.math.roundToInt

/**
 * Keeps NexRadar alive while the app is in the background, the screen is off or
 * the phone is locked, and hosts the bubble whenever the accessibility host is
 * not around to do it.
 *
 * Three Android features are doing the heavy lifting here:
 *
 * 1. **Foreground service** — without it the system kills the process within
 *    seconds of the screen turning off, taking the bubble *and* the location
 *    stream with it.
 * 2. **`TYPE_APPLICATION_OVERLAY`** — lets the window float above whatever the
 *    driver is looking at (Yandex/Google Maps, Waze, the launcher…). This window
 *    is hidden by the keyguard and there is no flag that changes that, so on the
 *    lock screen the bubble is hosted by [NexRadarAccessibilityService] instead
 *    (see [BubbleWindow] for the layer-by-layer explanation).
 * 3. **A media panel** — the notification is a `MediaStyle` one backed by a live
 *    [MediaSession], which is what Android renders *on the lock screen* with
 *    working controls (see [LockScreenControls]). A plain ongoing notification
 *    can be filtered out by the keyguard; the media player cannot, and it is the
 *    one surface the driver can act on without unlocking.
 *
 * All numbers arrive from Dart as a tiny map and are handed to [BubbleWindow],
 * whose view does its own 60 FPS interpolation.
 */
class RadarOverlayService :
    Service(),
    SpeedBubbleView.Listener,
    LockScreenControls.Actions {

    private var window: BubbleWindow? = null

    private var scale = 1f
    private var showRemaining = true

    /** Whether this host's own window is on screen right now. */
    @Volatile
    private var bubbleAttached = false

    /** Last known payload, so the notification can be refreshed on demand. */
    @Volatile
    private var lastPayload: Map<String, Any?> = emptyMap()

    private var lastNotificationText = ""
    private var lastNotificationAt = 0L

    /** The lock-screen media panel: session, metadata and notification style. */
    private var lockScreen: LockScreenControls? = null

    /** Drives the 1 Hz countdown the panel prints while the silence window runs. */
    private val countdownHandler = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        scale = BubbleWindow.prefs(this).getFloat("scale", 1f)
        showRemaining = BubbleWindow.showRemaining(this)

        createNotificationChannel()
        // The session must exist before the first notification is built: the
        // MediaStyle carries its token, and that token is what promotes the card
        // into the lock screen's media player.
        lockScreen = LockScreenControls(this, this).also { it.start(openAppIntent()) }
        startForegroundCompat(buildNotification())
        instance = this
        isRunning = true
        watchScreenAndKeyguard()
        DiagLog.event(this, "service", "foreground started")

        // Make sure the Dart isolate is up. Normally it already is — the engine
        // is owned by the application — but after a process death Android
        // restarts this service on its own (START_STICKY), and asking for the
        // engine here is what brings the GPS stream, the alert ladder and the
        // bubble back to life without the driver opening the app.
        NexRadarApplication.of(this).flutterEngine()

        syncWindow()
        Log.i(TAG, "overlay service started")
    }

    /**
     * The user swiped NexRadar out of the recents list.
     *
     * The bubble must stay alive — that is the entire point of a background HUD —
     * but several OEM task-killers treat a removed task as "this app is done" and
     * reap the process a moment later. Re-deriving the foreground service from
     * here re-asserts it on those builds; on stock Android it is a no-op.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i(TAG, "task removed — bubble stays up")
        DiagLog.event(this, "service", "task swiped away")
        // Re-assert immediately from the service itself, so the record shows the
        // bubble was still alive at the instant the driver closed the app.
        DiagLog.heartbeat(this, "service alive after task removal")
        if (OverlayBus.overlayDesired) {
            runCatching {
                startForegroundService(Intent(this, RadarOverlayService::class.java))
            }.onFailure { Log.w(TAG, "could not re-assert the service", it) }
        }
        BubbleHost.refresh()
        super.onTaskRemoved(rootIntent)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopEverything()
                return START_NOT_STICKY
            }
            ACTION_ADD_RADAR -> {
                OverlayBus.emit("addRadar")
            }
            ACTION_PAUSE_WARNINGS -> setSilenced(true, fromUser = true)
            ACTION_RESUME_WARNINGS -> setSilenced(false, fromUser = true)
            ACTION_TOGGLE_VOICE -> OverlayBus.emit("toggleVoice")
            ACTION_UPDATE -> {
                intent.extras?.let { bundle ->
                    val payload = mutableMapOf<String, Any?>()
                    for (key in bundle.keySet()) {
                        payload[key] = bundle.get(key)
                    }
                    if (bundle.containsKey("scale")) {
                        scale = bundle.getFloat("scale", scale)
                    }
                    if (bundle.containsKey("showRemaining")) {
                        showRemaining = bundle.getBoolean("showRemaining", true)
                    }
                    applyPayload(payload)
                }
            }
            else -> {
                // Plain start/restart: honour the extras we were launched with
                // and replay the last known state so the bubble never blanks out
                // after a service restart.
                intent?.extras?.let { bundle ->
                    if (bundle.containsKey("scale")) scale = bundle.getFloat("scale", scale)
                    if (bundle.containsKey("showRemaining")) {
                        showRemaining = bundle.getBoolean("showRemaining", true)
                    }
                }
                window?.applyScale(scale)
                OverlayBus.pendingState?.let { applyPayload(it) }
            }
        }
        syncWindow()
        return START_STICKY
    }

    // ------------------------------------------------------------------ window

    /**
     * Attaches or detaches *this* host's window.
     *
     * Two rules decide it: the accessibility host always wins when it is alive
     * (its window is the one the keyguard cannot hide), and a window is only
     * worth attaching at all when nobody else is drawing.
     */
    fun syncWindow() {
        if (!isRunning) return
        val allowed = BubbleWindow.isDesired(this) &&
            !BubbleHost.lockHudOwnsBubble() &&
            Settings.canDrawOverlays(this)
        if (allowed) attachBubble() else detachBubble()
    }

    private fun attachBubble() {
        if (window?.attached == true) return

        val host = window ?: BubbleWindow(
            this,
            android.view.WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            this,
        ).also { window = it }

        host.applyScale(scale)
        host.pushState(mapOf("showRemaining" to showRemaining))
        host.attach()
        bubbleAttached = host.attached
        if (!host.attached) {
            Log.w(TAG, "overlay window refused; is SYSTEM_ALERT_WINDOW granted?")
            DiagLog.event(this, "overlay", "window refused — grant missing?")
        } else {
            DiagLog.event(this, "overlay", "window attached")
        }
    }

    private fun detachBubble() {
        window?.detach()
        bubbleAttached = false
    }

    private fun applyPayload(payload: Map<String, Any?>) {
        // Dart owns the silence window — it is the layer that beeps — so its
        // value is adopted here and mirrored into the process-wide bus, where the
        // accessibility host and the diagnostics screen can read it too.
        (payload["paused"] as? Boolean)?.let { adoptSilence(it) }
        (payload["pausedUntilMs"] as? Number)?.let { OverlayBus.silenceUntilMs = it.toLong() }

        val merged = OverlayBus.decorated(payload)
        merged["showRemaining"] = payload["showRemaining"] ?: showRemaining
        window?.pushState(merged)
        lastPayload = merged
        refreshNotification(merged)
    }

    // ------------------------------------------------------------ silence mode

    /**
     * Mirrors Dart's silence state without asking Dart again.
     *
     * Called on every payload, so it stays dumb: bookkeeping and, at most, the
     * start of the countdown ticker.
     */
    private fun adoptSilence(silenced: Boolean) {
        val changed = OverlayBus.silenced != silenced
        OverlayBus.silenced = silenced
        if (!silenced) OverlayBus.silenceUntilMs = 0L
        if (changed) scheduleCountdown()
    }

    /**
     * Applies a silence request that came from the lock-screen panel.
     *
     * The local flag flips immediately — the button must not wait for a round
     * trip through the Dart isolate — and the request is *also* forwarded to Dart,
     * which is the layer that actually mutes the announcements. Dart's value comes
     * back with the next payload and wins if the two ever disagree.
     */
    private fun setSilenced(silenced: Boolean, fromUser: Boolean) {
        OverlayBus.silenced = silenced
        if (!silenced) OverlayBus.silenceUntilMs = 0L
        scheduleCountdown()

        if (fromUser) {
            DiagLog.event(
                this,
                "lock",
                if (silenced) "sükut rejimi — kilid ekranından"
                else "sükut bitdi — kilid ekranından",
            )
            OverlayBus.emit(if (silenced) "pauseWarnings" else "resumeWarnings")
        }

        val merged = OverlayBus.decorated(lastPayload)
        lastPayload = merged
        window?.pushState(merged)
        refreshNotification(merged, force = true)
    }

    /** 1 Hz repaint while silenced: the panel prints the time left. */
    private val countdown = object : Runnable {
        override fun run() {
            if (!OverlayBus.silenced) return
            refreshNotification(lastPayload, force = true)
            countdownHandler.postDelayed(this, 1000L)
        }
    }

    private fun scheduleCountdown() {
        countdownHandler.removeCallbacks(countdown)
        if (OverlayBus.silenced) countdownHandler.postDelayed(countdown, 1000L)
    }

    // ------------------------------------------------- screen & keyguard watch

    /**
     * Records the screen and keyguard transitions a driver reports as "the app
     * closed itself".
     *
     * The keyguard hides every `TYPE_APPLICATION_OVERLAY` window, and a few OEM
     * window managers go further and drop the window entirely — the bubble then
     * never comes back after unlocking, which looks exactly like a crash. So the
     * unlock is treated as a signal to re-evaluate both hosts, and the file gets
     * one line per transition: the evidence a support report needs.
     */
    private fun watchScreenAndKeyguard() {
        runCatching {
            ContextCompat.registerReceiver(
                this,
                screenWatcher,
                IntentFilter().apply {
                    addAction(Intent.ACTION_SCREEN_OFF)
                    addAction(Intent.ACTION_SCREEN_ON)
                    addAction(Intent.ACTION_USER_PRESENT)
                },
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
        }.onFailure { Log.w(TAG, "screen watcher not registered", it) }
    }

    private val screenWatcher = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF ->
                    DiagLog.event(this@RadarOverlayService, "screen", "ekran bağlandı")

                Intent.ACTION_SCREEN_ON -> {
                    DiagLog.event(this@RadarOverlayService, "screen", "ekran açıldı")
                    BubbleHost.refresh()
                }

                Intent.ACTION_USER_PRESENT -> {
                    DiagLog.event(this@RadarOverlayService, "screen", "kilid açıldı")
                    syncWindow()
                    BubbleHost.refresh()
                }
            }
        }
    }

    // -------------------------------------------------------------- listeners

    override fun onDragBy(dx: Int, dy: Int) {
        window?.moveBy(dx, dy)
    }

    override fun onDragFinished() {
        window?.persistPosition()
        OverlayBus.emit("moved")
    }

    override fun onScaleCycled(scale: Float) {
        this.scale = scale
        window?.applyScale(scale)
        OverlayBus.emit("doubleTap", mapOf("scale" to scale))
    }

    /**
     * One tap on the bubble's "+" — and the lock-screen panel's next button.
     *
     * Both gestures mean the same thing ("there is a radar here, remember it"),
     * so they share one implementation instead of two that could drift apart.
     */
    override fun onReportRequested() {
        DiagLog.event(this, "overlay", "radar bildir tələbi")
        OverlayBus.emit("addRadar")
    }

    override fun onTapped() {
        OverlayBus.emit("tapped")
    }

    // ------------------------------------------------- lock-screen panel actions

    override fun onPauseRequested() = setSilenced(true, fromUser = true)

    override fun onResumeRequested() = setSilenced(false, fromUser = true)

    override fun onToggleVoiceRequested() {
        DiagLog.event(this, "lock", "səs — kilid ekranından")
        OverlayBus.emit("toggleVoice")
    }

    override fun onStopRequested() {
        DiagLog.event(this, "lock", "dayandırıldı — kilid ekranından")
        stopEverything()
    }

    /**
     * The one way this service is ever torn down.
     *
     * Every entry point — the notification's stop button, the lock-screen media
     * panel's stop button, and the app's own hide call — has to leave the *same*
     * record behind: the driver asked for this. That record is the persisted
     * "desired" flag, and it is what stops a later service restart (a reboot, an
     * update, a sticky restart after process death) from resurrecting a bubble he
     * deliberately killed — and, in the other direction, what lets the app tell
     * "he still wants the radar" apart from "he turned it off".
     */
    private fun stopEverything() {
        OverlayBus.overlayDesired = false
        BubbleWindow.setDesired(this, false)
        OverlayBus.requestStop()
        BubbleHost.refresh()
        stopSelf()
    }

    // ---------------------------------------------------------- notification

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "NexRadar xidməti",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Kilid ekranında sürət, limit və radara qalan məsafə"
            setShowBadge(false)
            enableVibration(false)
            // The lock screen card must stay readable: it is the surface the
            // driver sees without unlocking, next to the accessibility HUD.
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }

    /** "Tap the media card" intent: the dashboard, from anywhere. */
    private fun openAppIntent(): PendingIntent = PendingIntent.getActivity(
        this,
        1,
        Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        },
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /**
     * The lock-screen card.
     *
     * It is a **media** notification, and that is the whole trick: the media
     * player is the one surface Android always renders above the keyguard, and
     * the only one whose buttons the driver can press without unlocking. The
     * title carries the live speed, the session's artist line carries the limit
     * and the distance, and the artwork is the speed dial itself — see
     * [LockScreenControls].
     *
     * The plain notification layout stays as a fallback for the (theoretically
     * impossible, cheap to handle) case where the session failed to come up: the
     * numbers and the actions are then exactly what they always were.
     */
    private fun buildNotification(): Notification {
        val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT

        val addRadar = PendingIntent.getService(
            this,
            2,
            Intent(this, RadarOverlayService::class.java).setAction(ACTION_ADD_RADAR),
            flags,
        )

        val toggle = PendingIntent.getService(
            this,
            3,
            Intent(this, RadarOverlayService::class.java).setAction(
                if (OverlayBus.silenced) ACTION_RESUME_WARNINGS else ACTION_PAUSE_WARNINGS,
            ),
            flags,
        )

        val stop = PendingIntent.getService(
            this,
            4,
            Intent(this, RadarOverlayService::class.java).setAction(ACTION_STOP),
            flags,
        )

        val reportIcon = Icon.createWithResource(this, R.drawable.ic_nexradar_report)
        val stopIcon = Icon.createWithResource(this, R.drawable.ic_nexradar_stop)
        val toggleIcon = Icon.createWithResource(
            this,
            if (OverlayBus.silenced) R.drawable.ic_nexradar_play
            else R.drawable.ic_nexradar_pause,
        )

        val summary = summarise(lastPayload)

        val builder = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(summary.title)
            .setContentText(summary.text)
            .setSubText("NexRadar")
            .setSmallIcon(R.drawable.ic_nexradar_notification)
            .setColor(COLOR_ACCENT)
            .setContentIntent(openAppIntent())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            // Public = render the text on the lock screen even when the user has
            // "hide sensitive content" enabled for other apps.
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setLocalOnly(true)
            .addAction(Notification.Action.Builder(reportIcon, "Radar bildir", addRadar).build())
            .addAction(
                Notification.Action.Builder(
                    toggleIcon,
                    if (OverlayBus.silenced) "Sükutu aç" else "Sükut",
                    toggle,
                ).build(),
            )
            .addAction(Notification.Action.Builder(stopIcon, "Dayandır", stop).build())

        val panel = lockScreen
        if (panel != null && panel.isActive) {
            // MediaStyle needs the token of a live session and at least as many
            // notification actions as `setShowActionsInCompactView` refers to —
            // all three above are always present.
            builder
                .setStyle(panel.styleFor())
                .setCategory(Notification.CATEGORY_TRANSPORT)
            panel.artwork?.let { builder.setLargeIcon(it) }
            // Android 16 prints this one-liner in the status-bar chip and on the
            // lock screen: the fastest readable form of the current state.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA) {
                builder.setShortCriticalText(summary.snapshot.shortText)
            }
        } else {
            val style = Notification.InboxStyle().setBigContentTitle(summary.title)
            for (line in summary.lines) {
                style.addLine(line)
            }
            builder.setStyle(style).setCategory(Notification.CATEGORY_SERVICE)
        }

        // Note: `setSilent` is @SystemApi. The channel is IMPORTANCE_LOW with
        // sound and vibration disabled, which is the supported way to keep this
        // card quiet.
        return builder.build()
    }

    /** Throttled refresh so a 1 Hz payload stream cannot flood the notifier. */
    private fun refreshNotification(
        payload: Map<String, Any?> = lastPayload,
        force: Boolean = false,
    ) {
        val summary = summarise(payload)
        val signature =
            summary.title + "|" + summary.text + "|" + summary.lines.joinToString()
        // `force` is what the silence countdown needs: it re-renders the *same*
        // text with a smaller number, so only the rate limit below applies.
        if (!force && signature == lastNotificationText) return
        val now = SystemClock.elapsedRealtime()
        // A locked screen is refreshed at most twice a second: the distance is
        // the only value that moves that fast, and 500 ms is plenty for it.
        if (lastNotificationAt != 0L && now - lastNotificationAt < 500L) return
        lastNotificationAt = now
        lastNotificationText = signature

        // Publish the session metadata first: the notification reuses the artwork
        // that [LockScreenControls.update] has just (re)drawn.
        lockScreen?.update(summary.snapshot)

        val manager = getSystemService(NotificationManager::class.java) ?: return
        runCatching { manager.notify(NOTIFICATION_ID, buildNotification()) }
    }

    /**
     * One state → every view of it: the notification title and body, the expanded
     * lines, and the snapshot the lock-screen media panel prints.
     */
    private data class Summary(
        val title: String,
        val text: String,
        val lines: List<String>,
        val snapshot: LockScreenControls.Snapshot,
    )

    private fun summarise(payload: Map<String, Any?>): Summary {
        val unit = (payload["unit"] as? String) ?: "km/s"
        val mph = unit == "mph"
        val speed = (payload["speedKmh"] as? Number)?.toFloat()
        val limit = (payload["limit"] as? Number)?.toInt() ?: -1
        val distance = (payload["distanceMeters"] as? Number)?.toInt() ?: -1
        val status = (payload["status"] as? String) ?: SpeedBubbleView.STATUS_IDLE
        val temporary = payload["isTemporary"] as? Boolean ?: false
        val type = cameraTypeLabel(payload["cameraType"] as? String)

        val shownLimit = if (limit > 0 && mph) (limit / 1.609344f).roundToInt() else limit
        val shownSpeed = speed?.let { if (mph) it / 1.609344f else it }
        val speedText = shownSpeed?.let { "${it.roundToInt()} $unit" }

        // The silence window is process-wide state (it comes from Dart with the
        // payload), and the panel prints how long is left of it.
        val silenced = OverlayBus.silenced
        val remaining = if (silenced && OverlayBus.silenceUntilMs > 0L) {
            ((OverlayBus.silenceUntilMs - System.currentTimeMillis()) / 1000L)
                .toInt()
                .coerceAtLeast(0)
        } else {
            0
        }
        val silenceText = if (remaining > 0) {
            "Sükut · ${remaining / 60}:${(remaining % 60).toString().padStart(2, '0')} " +
                "sonra aktiv"
        } else {
            "Sükut rejimi aktivdir"
        }

        val marker = when {
            silenced -> "🔇 "
            status == SpeedBubbleView.STATUS_WARNING -> "⚠ "
            status == SpeedBubbleView.STATUS_APPROACHING -> "• "
            else -> ""
        }
        val title = if (speedText == null) "NexRadar aktivdir" else "$marker$speedText"

        val distanceText = when {
            distance < 0 -> "5 km-də radar yoxdur"
            distance >= 1000 -> String.format("%.1f km", distance / 1000f)
            else -> "$distance m"
        }

        val limitText = if (shownLimit > 0) "$shownLimit $unit" else "məlum deyil"

        val text = when {
            silenced -> "$silenceText · limit $limitText"
            distance < 0 -> "Limit $limitText · $distanceText"
            else -> "Limit $limitText · Radar $distanceText"
        }

        val lines = mutableListOf<String>()
        if (silenced) lines.add(silenceText)
        lines.add("Sürət: ${speedText ?: "—"}")
        lines.add("Limit: $limitText")
        lines.add("Radara məsafə: $distanceText")
        lines.add("Növ: ${if (temporary) "Sürücü bildirişi" else type}")

        return Summary(
            title = title,
            text = text,
            lines = lines,
            snapshot = LockScreenControls.Snapshot(
                title = title,
                detail = if (silenced) silenceText else "Limit $limitText · Radar $distanceText",
                shortText = if (silenced) "SÜKUT" else (speedText ?: ""),
                unit = unit,
                speed = shownSpeed?.roundToInt() ?: 0,
                limit = shownLimit,
                distanceMeters = distance,
                status = status,
                silenced = silenced,
                silenceRemainingSeconds = remaining,
            ),
        )
    }

    private fun cameraTypeLabel(wire: String?): String = when (wire) {
        "mobile" -> "Mobil YPX"
        "red_light" -> "İşıqfor radarı"
        "average_speed" -> "Orta sürət"
        "fixed" -> "Sabit radar"
        else -> "Radar"
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onDestroy() {
        detachBubble()
        countdownHandler.removeCallbacks(countdown)
        runCatching { unregisterReceiver(screenWatcher) }
        lockScreen?.stop()
        lockScreen = null
        OverlayBus.silenced = false
        OverlayBus.silenceUntilMs = 0L
        window = null
        isRunning = false
        bubbleAttached = false
        instance = null
        DiagLog.event(this, "service", "stopped")
        Log.i(TAG, "overlay service stopped")
        super.onDestroy()
    }

    companion object {
        private const val TAG = "RadarOverlayService"

        const val CHANNEL_ID = "nexradar_overlay"
        const val NOTIFICATION_ID = 4711

        /** Brand accent, used as the notification's colour chip. */
        private const val COLOR_ACCENT = 0xFF31F0A6.toInt()

        const val ACTION_UPDATE = "com.nexradar.app.UPDATE"
        const val ACTION_ADD_RADAR = "com.nexradar.app.ADD_RADAR"
        const val ACTION_STOP = "com.nexradar.app.STOP"

        /** Silence mode: mute the beeps and announcements for a bounded window. */
        const val ACTION_PAUSE_WARNINGS = "com.nexradar.app.PAUSE_WARNINGS"
        const val ACTION_RESUME_WARNINGS = "com.nexradar.app.RESUME_WARNINGS"

        /** Voice guidance off/on — the panel's "previous" slot. */
        const val ACTION_TOGGLE_VOICE = "com.nexradar.app.TOGGLE_VOICE"

        @Volatile
        var isRunning: Boolean = false
            private set

        @Volatile
        var instance: RadarOverlayService? = null
            private set

        /** True while this service's own overlay window is drawing. */
        fun isBubbleAttached(): Boolean = instance?.bubbleAttached == true

        /** True while the lock-screen media panel is published. */
        fun mediaPanelActive(): Boolean = instance?.lockScreen?.isActive == true

        /** Effective silence state: Dart's value, or the panel's last request. */
        fun silenceActive(): Boolean = OverlayBus.silenced

        /** Epoch millis when the silence window ends, 0 while warnings are live. */
        fun silenceUntilMs(): Long = OverlayBus.silenceUntilMs

        /**
         * Pushes a state payload straight into whichever host is drawing.
         *
         * Called roughly once a second from Dart, so it must stay cheap: two map
         * lookups and a view invalidate.
         */
        fun update(payload: Map<String, Any?>) {
            OverlayBus.pendingState = payload
            instance?.applyPayload(payload)
            // The accessibility host (the keyguard-surviving bubble) gets the same
            // state, silence flag included, so the two hosts can never disagree.
            NexRadarAccessibilityService.instance?.applyPayload(OverlayBus.decorated(payload))
        }

        fun setScale(scale: Float) {
            instance?.let {
                it.scale = scale
                it.onScaleCycled(scale)
            }
        }

        fun stop(context: Context) {
            OverlayBus.overlayDesired = false
            BubbleWindow.setDesired(context, false)
            BubbleHost.refresh()
            context.stopService(Intent(context, RadarOverlayService::class.java))
        }

        /**
         * Starts the foreground service. The *window* is optional — the service
         * also runs headless when only the accessibility host is drawing, and it
         * is the thing that keeps the process (and the GPS stream) alive.
         */
        fun start(
            context: Context,
            scale: Float = 1f,
            showRemaining: Boolean = true,
        ) {
            OverlayBus.overlayDesired = true
            BubbleWindow.setDesired(context, true)
            BubbleWindow.setShowRemaining(context, showRemaining)
            val intent = Intent(context, RadarOverlayService::class.java).apply {
                putExtra("scale", scale)
                putExtra("showRemaining", showRemaining)
            }
            context.startForegroundService(intent)
            BubbleHost.refresh()
        }

        /** Live dial scale, read by the settings screen. */
        fun currentScale(): Float = instance?.let { it.scale } ?: 1f
    }
}
