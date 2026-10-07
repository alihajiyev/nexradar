package com.nexradar.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
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
 * 3. **A public, live notification** — the three numbers the driver wants (speed,
 *    limit, distance) on the lock screen even before the lock-screen HUD has been
 *    enabled.
 *
 * All numbers arrive from Dart as a tiny map and are handed to [BubbleWindow],
 * whose view does its own 60 FPS interpolation.
 */
class RadarOverlayService : Service(), SpeedBubbleView.Listener {

    private var window: BubbleWindow? = null

    private var scale = 1f
    private var showRemaining = true

    /** Last known payload, so the notification can be refreshed on demand. */
    @Volatile
    private var lastPayload: Map<String, Any?> = emptyMap()

    private var lastNotificationText = ""
    private var lastNotificationAt = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        scale = BubbleWindow.prefs(this).getFloat("scale", 1f)
        showRemaining = BubbleWindow.showRemaining(this)

        createNotificationChannel()
        startForegroundCompat(buildNotification())
        instance = this
        isRunning = true

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
                OverlayBus.requestStop()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_ADD_RADAR -> {
                OverlayBus.emit("addRadar")
            }
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
        if (!host.attached) {
            Log.w(TAG, "overlay window refused; is SYSTEM_ALERT_WINDOW granted?")
        }
    }

    private fun detachBubble() {
        window?.detach()
    }

    private fun applyPayload(payload: Map<String, Any?>) {
        val merged = HashMap<String, Any?>(payload)
        merged["showRemaining"] = payload["showRemaining"] ?: showRemaining
        window?.pushState(merged)
        lastPayload = merged
        refreshNotification(merged)
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

    override fun onReportRequested() {
        OverlayBus.emit("addRadar")
    }

    override fun onTapped() {
        OverlayBus.emit("tapped")
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

    /**
     * The lock-screen card. The title carries the live speed, the body carries
     * the limit, the remaining distance and the camera type — the numbers the
     * driver asked to see without unlocking the phone.
     */
    private fun buildNotification(): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            1,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val addRadar = PendingIntent.getService(
            this,
            2,
            Intent(this, RadarOverlayService::class.java).setAction(ACTION_ADD_RADAR),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val stop = PendingIntent.getService(
            this,
            3,
            Intent(this, RadarOverlayService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val icon = android.graphics.drawable.Icon.createWithResource(
            this,
            R.drawable.ic_nexradar_notification,
        )

        val summary = summarise(lastPayload)
        val style = Notification.InboxStyle()
            .setBigContentTitle(summary.first)
        for (line in summary.third) {
            style.addLine(line)
        }

        val builder = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(summary.first)
            .setContentText(summary.second)
            .setSubText("NexRadar")
            .setStyle(style)
            .setSmallIcon(R.drawable.ic_nexradar_notification)
            .setColor(COLOR_ACCENT)
            .setContentIntent(openApp)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            // Public = render the text on the lock screen even when the user has
            // "hide sensitive content" enabled for other apps.
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setLocalOnly(true)
            .addAction(Notification.Action.Builder(icon, "Radar bildir", addRadar).build())
            .addAction(Notification.Action.Builder(icon, "Dayandır", stop).build())
        // Note: `setSilent` is @SystemApi. The channel is IMPORTANCE_LOW with
        // sound and vibration disabled, which is the supported way to keep this
        // card quiet.
        return builder.build()
    }

    /** Throttled refresh so a 1 Hz payload stream cannot flood the notifier. */
    private fun refreshNotification(payload: Map<String, Any?>) {
        val summary = summarise(payload)
        val signature = summary.first + "|" + summary.second + "|" + summary.third.joinToString()
        if (signature == lastNotificationText) return
        val now = SystemClock.elapsedRealtime()
        // A locked screen is refreshed at most twice a second: the distance is
        // the only value that moves that fast, and 500 ms is plenty for it.
        if (lastNotificationAt != 0L && now - lastNotificationAt < 500L) return
        lastNotificationAt = now
        lastNotificationText = signature

        val manager = getSystemService(NotificationManager::class.java) ?: return
        runCatching { manager.notify(NOTIFICATION_ID, buildNotification()) }
    }

    /**
     * Three views of the same state: a one-line title, a one-line summary for the
     * collapsed card, and the lines the driver sees on the lock screen.
     */
    private fun summarise(payload: Map<String, Any?>): Triple<String, String, List<String>> {
        val unit = (payload["unit"] as? String) ?: "km/s"
        val mph = unit == "mph"
        val speed = (payload["speedKmh"] as? Number)?.toFloat()
        val limit = (payload["limit"] as? Number)?.toInt() ?: -1
        val distance = (payload["distanceMeters"] as? Number)?.toInt() ?: -1
        val status = (payload["status"] as? String) ?: SpeedBubbleView.STATUS_IDLE
        val temporary = payload["isTemporary"] as? Boolean ?: false
        val type = cameraTypeLabel(payload["cameraType"] as? String)

        val shownLimit = if (limit > 0 && mph) (limit / 1.609344f).roundToInt() else limit
        val speedText = speed?.let {
            val shown = if (mph) it / 1.609344f else it
            "${shown.roundToInt()} $unit"
        }

        val title = when (speedText) {
            null -> "NexRadar aktivdir"
            else -> {
                val prefix = when (status) {
                    SpeedBubbleView.STATUS_WARNING -> "⚠ "
                    SpeedBubbleView.STATUS_APPROACHING -> "• "
                    else -> ""
                }
                "$prefix$speedText"
            }
        }

        val distanceText = when {
            distance < 0 -> "5 km-də radar yoxdur"
            distance >= 1000 -> String.format("%.1f km", distance / 1000f)
            else -> "$distance m"
        }

        val limitText = if (shownLimit > 0) "$shownLimit $unit" else "məlum deyil"

        val lines = mutableListOf(
            "Sürət: ${speedText ?: "—"}",
            "Limit: $limitText",
            "Radara məsafə: $distanceText",
            "Növ: ${if (temporary) "Sürücü bildirişi" else type}",
        )

        val summary = if (distance < 0) {
            "Limit $limitText · $distanceText"
        } else {
            "Limit $limitText · Radar $distanceText"
        }
        return Triple(title, summary, lines)
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
        window = null
        isRunning = false
        instance = null
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

        @Volatile
        var isRunning: Boolean = false
            private set

        @Volatile
        var instance: RadarOverlayService? = null
            private set

        /**
         * Pushes a state payload straight into whichever host is drawing.
         *
         * Called roughly once a second from Dart, so it must stay cheap: two map
         * lookups and a view invalidate.
         */
        fun update(payload: Map<String, Any?>) {
            OverlayBus.pendingState = payload
            instance?.applyPayload(payload)
            NexRadarAccessibilityService.instance?.applyPayload(payload)
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
