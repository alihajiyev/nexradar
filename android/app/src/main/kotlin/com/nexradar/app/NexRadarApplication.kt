package com.nexradar.app

import android.app.Application
import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Holds the one Flutter engine this process will ever create.
 *
 * NexRadar is background-first: the bubble, the GPS stream and the alert ladder
 * all live in the Dart isolate, which must keep running when the activity is
 * gone — the driver swipes the task away, the screen locks, another app comes to
 * the front. A `FlutterActivity`-owned engine dies with its host, which is
 * exactly the bug where the bubble stayed on screen as a frozen widget: the
 * native foreground service survived, the Dart side did not.
 *
 * So the engine is owned here instead and handed to whoever needs it:
 *
 * * [MainActivity] attaches its view to it through `provideFlutterEngine` and
 *   explicitly does *not* destroy it on the way out;
 * * [RadarOverlayService] simply asks for it, which is also how a sticky service
 *   restart (process death) brings the whole radar pipeline back to life.
 *
 * `FlutterEngine(context)` registers the generated plugins itself, so geolocator,
 * sqflite, TTS and the rest are available headless too.
 */
class NexRadarApplication : Application() {

    @Volatile
    private var engine: FlutterEngine? = null

    override fun onCreate() {
        super.onCreate()
        // The first line of every session. After a silent background death, the
        // distance between this timestamp and the last heartbeat in the file is
        // the entire answer to "how long did it keep working?".
        DiagLog.beginSession(
            this,
            "process ${android.os.Process.myPid()} · " +
                "${Build.MANUFACTURER} ${Build.MODEL} · API ${Build.VERSION.SDK_INT}",
        )
    }

    /** Creates the engine on first use and runs `main()` exactly once. */
    fun flutterEngine(): FlutterEngine = engine ?: synchronized(this) {
        engine ?: createEngine().also { engine = it }
    }

    private fun createEngine(): FlutterEngine {
        val created = FlutterEngine(this)
        // Channels are wired to the engine, not to an activity, so a method call
        // from Dart works even with no UI on screen.
        NexRadarChannels.wire(created, applicationContext)
        NexRadarDiagnostics.wire(created, applicationContext)
        DiagLog.event(applicationContext, "engine", "dart entrypoint started")
        created.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
        )
        return created
    }

    companion object {
        fun of(context: Context): NexRadarApplication =
            context.applicationContext as NexRadarApplication
    }
}
