package com.nexradar.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.WindowManager

/**
 * Keeps the floating bubble alive while the app is in the background, the
 * screen is off, or the phone is locked.
 *
 * Four Android features are doing the heavy lifting here:
 *
 * 1. **Foreground service** — without it the system kills the process within
 *    seconds of the screen turning off, taking the bubble with it.
 * 2. **`TYPE_APPLICATION_OVERLAY`** — lets the window float above whatever the
 *    driver is looking at (Yandex/Google Maps, Waze, the launcher…).
 * 3. **A full-screen window.** `FLAG_SHOW_WHEN_LOCKED` is documented to apply
 *    only to *"the top-most full-screen window"*, so the host window is
 *    `MATCH_PARENT` and [SpeedBubbleView] draws the bubble inside it at an
 *    offset. That is what makes the bubble survive the keyguard. Touches outside
 *    the bubble fall through to the app underneath (see `onTouchEvent`).
 * 4. **A public, live notification.** Even when a OEM blocks third-party
 *    overlays above a *secure* keyguard, the ongoing card still shows the speed,
 *    the limit and the live distance on the lock screen.
 *
 * All numbers arrive from Dart as a tiny map and are handed to
 * [SpeedBubbleView], which does its own 60 FPS interpolation.
 */
class RadarOverlayService : Service(), SpeedBubbleView.Listener {

    private var windowManager: WindowManager? = null
    private var bubbleView: SpeedBubbleView? = null
    private var layoutParams: WindowManager.LayoutParams? = null

    private var positionX = UNSET
    private var positionY = UNSET
    private var scale = 1f
    private var showRemaining = true

    /** Last known payload, so the notification can be refreshed on demand. */
    @Volatile
    private var lastPayload: Map<String, Any?> = emptyMap()

    private var lastNotificationText = ""
    private var lastNotificationAt = 0L

    private lateinit var prefs: android.content.SharedPreferences

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        positionX = prefs.getInt(KEY_X, UNSET)
        positionY = prefs.getInt(KEY_Y, UNSET)
        scale = prefs.getFloat(KEY_SCALE, 1f)
        showRemaining = prefs.getBoolean(KEY_SHOW_REMAINING, true)

        createNotificationChannel()
        startForegroundCompat(buildNotification())
        instance = this
        isRunning = true
        attachBubble()
        Log.i(TAG, "overlay service started")
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
                bubbleView?.scaleFactor = scale
                OverlayBus.pendingState?.let { applyPayload(it) }
            }
        }
        if (bubbleView == null) attachBubble()
        return START_STICKY
    }

    // ------------------------------------------------------------------ window

    private fun attachBubble() {
        if (bubbleView != null) return
        if (!Settings.canDrawOverlays(this)) {
            Log.w(TAG, "no SYSTEM_ALERT_WINDOW grant — stopping")
            stopSelf()
            return
        }

        val manager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        windowManager = manager

        val view = SpeedBubbleView(this).apply {
            this.scaleFactor = scale
            listener = this@RadarOverlayService
        }
        bubbleView = view

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                // Without NOT_TOUCH_MODAL the full-screen window would swallow
                // every gesture in the system.
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                // The flag that puts this window above the keyguard. It only
                // works because this window is full-screen.
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = 0
            y = 0
            windowAnimations = 0
        }
        layoutParams = params

        view.pushState(mapOf("showRemaining" to showRemaining))

        runCatching { manager.addView(view, params) }
            .onFailure {
                Log.e(TAG, "addView failed", it)
                bubbleView = null
                stopSelf()
                return
            }

        // Restore the bubble's place inside the (now full-screen) window. On a
        // first run the view has already parked itself in a sane corner.
        view.post {
            if (positionX != UNSET && positionY != UNSET) {
                view.moveTo(positionX, positionY)
            } else {
                persistPosition(view.bubbleX, view.bubbleY)
            }
        }
    }

    private fun detachBubble() {
        val view = bubbleView ?: return
        runCatching { windowManager?.removeView(view) }
        bubbleView = null
        layoutParams = null
    }

    private fun applyPayload(payload: Map<String, Any?>) {
        val merged = HashMap<String, Any?>(payload)
        merged["showRemaining"] = payload["showRemaining"] ?: showRemaining
        bubbleView?.pushState(merged)
        lastPayload = merged
        refreshNotification(merged)
    }

    private fun persistPosition(x: Int, y: Int) {
        positionX = x
        positionY = y
        prefs.edit().putInt(KEY_X, x).putInt(KEY_Y, y).apply()
    }

    // -------------------------------------------------------------- listeners

    override fun onDrag(x: Int, y: Int) {
        // The view owns its own position inside the full-screen window, so
        // dragging needs no window layout update at all.
    }

    override fun onDragFinished(x: Int, y: Int) {
        persistPosition(x, y)
        OverlayBus.emit("moved", mapOf("x" to x, "y" to y))
    }

    override fun onScaleCycled(scale: Float) {
        this.scale = scale
        prefs.edit().putFloat(KEY_SCALE, scale).apply()
        bubbleView?.scaleFactor = scale
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
            description = "Floating sürət göstəricisi və radar xəbərdarlığı"
            setShowBadge(false)
            enableVibration(false)
            // The lock screen card must stay readable: it is the fallback when
            // an OEM refuses to draw third-party overlays over a secure keyguard.
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }

    /**
     * The lock-screen card. Title carries the live speed, the body carries the
     * limit and the remaining distance — the three numbers the driver asked to
     * see without unlocking.
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
        val builder = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(summary.first)
            .setContentText(summary.second)
            .setSubText("NexRadar")
            .setStyle(Notification.BigTextStyle().bigText(summary.second))
            .setSmallIcon(R.drawable.ic_nexradar_notification)
            .setContentIntent(openApp)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            // Public = render the text on the lock screen even when the user
            // has "hide sensitive content" enabled for other apps.
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setLocalOnly(true)
            .addAction(Notification.Action.Builder(icon, "Radar bildir", addRadar).build())
            .addAction(Notification.Action.Builder(icon, "Dayandır", stop).build())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setSilent(true)
        }
        return builder.build()
    }

    /** Throttled refresh so a 1 Hz payload stream cannot flood the notifier. */
    private fun refreshNotification(payload: Map<String, Any?>) {
        val summary = summarise(payload)
        val signature = summary.first + "|" + summary.second
        if (signature == lastNotificationText) return
        val now = SystemClock.elapsedRealtime()
        if (lastNotificationAt != 0L && now - lastNotificationAt < 850L) return
        lastNotificationAt = now
        lastNotificationText = signature

        val manager = getSystemService(NotificationManager::class.java) ?: return
        runCatching { manager.notify(NOTIFICATION_ID, buildNotification()) }
    }

    /** `("132 km/s", "Limit 80 · Radar 320 m · Mobil YPX")` */
    private fun summarise(payload: Map<String, Any?>): Pair<String, String> {
        val unit = (payload["unit"] as? String) ?: "km/s"
        val mph = unit == "mph"
        val speed = (payload["speedKmh"] as? Number)?.toFloat()
        val limit = (payload["limit"] as? Number)?.toInt() ?: -1
        val distance = (payload["distanceMeters"] as? Number)?.toInt() ?: -1
        val status = (payload["status"] as? String) ?: SpeedBubbleView.STATUS_IDLE
        val temporary = payload["isTemporary"] as? Boolean ?: false
        val type = cameraTypeLabel(payload["cameraType"] as? String)

        val speedValue = speed?.let {
            val shown = if (mph) it / 1.609344f else it
            shown.roundToInt().toString()
        }
        val title = when (speedValue) {
            null -> "NexRadar aktivdir"
            else -> {
                val prefix = when (status) {
                    SpeedBubbleView.STATUS_WARNING -> "⚠ "
                    SpeedBubbleView.STATUS_APPROACHING -> "• "
                    else -> ""
                }
                "$prefix$speedValue $unit"
            }
        }

        if (distance < 0) {
            return title to "5 km daxilində radar yoxdur"
        }

        val parts = mutableListOf<String>()
        if (limit > 0) {
            val shownLimit = if (mph) (limit / 1.609344f).roundToInt() else limit
            parts.add("Limit $shownLimit")
        }
        parts.add(
            if (distance >= 1000) {
                "Radar ${String.format("%.1f", distance / 1000f)} km"
            } else {
                "Radar $distance m"
            },
        )
        if (temporary) parts.add("Sürücü bildirişi") else parts.add(type)
        return title to parts.joinToString(" · ")
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
        isRunning = false
        instance = null
        Log.i(TAG, "overlay service stopped")
        super.onDestroy()
    }

    companion object {
        private const val TAG = "RadarOverlayService"

        const val CHANNEL_ID = "nexradar_overlay"
        const val NOTIFICATION_ID = 4711

        const val ACTION_UPDATE = "com.nexradar.app.UPDATE"
        const val ACTION_ADD_RADAR = "com.nexradar.app.ADD_RADAR"
        const val ACTION_STOP = "com.nexradar.app.STOP"

        private const val PREFS = "nexradar_overlay"
        private const val KEY_X = "x"
        private const val KEY_Y = "y"
        private const val KEY_SCALE = "scale"
        private const val KEY_SHOW_REMAINING = "show_remaining"

        /** "not placed yet" marker for the persisted bubble position. */
        private const val UNSET = -1

        @Volatile
        var isRunning: Boolean = false
            private set

        @Volatile
        var instance: RadarOverlayService? = null
            private set

        /** Pushes a state payload straight into the running bubble. */
        fun update(payload: Map<String, Any?>) {
            OverlayBus.pendingState = payload
            instance?.applyPayload(payload)
        }

        fun setScale(scale: Float) {
            instance?.let {
                it.scale = scale
                it.onScaleCycled(scale)
            }
        }

        fun stop(context: Context) {
            OverlayBus.overlayDesired = false
            context.stopService(Intent(context, RadarOverlayService::class.java))
        }

        fun start(
            context: Context,
            scale: Float = 1f,
            showRemaining: Boolean = true,
        ) {
            if (!Settings.canDrawOverlays(context)) return
            OverlayBus.overlayDesired = true
            val intent = Intent(context, RadarOverlayService::class.java).apply {
                putExtra("scale", scale)
                putExtra("showRemaining", showRemaining)
            }
            context.startForegroundService(intent)
        }
    }

    /** Kept public so MainActivity can read the persisted scale. */
    fun currentScale(): Float = scale
}
