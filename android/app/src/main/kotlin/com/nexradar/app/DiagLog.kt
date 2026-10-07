package com.nexradar.app

import android.content.Context
import java.io.File
import java.util.Locale

/**
 * The flight recorder.
 *
 * Every other log in this app dies with the process: `Logcat` is unreadable
 * without a cable, and the engine's in-memory log is gone the moment Android
 * reaps the app. That is precisely the situation the driver complains about —
 * "the bubble was on screen but did nothing" — and it leaves nothing behind to
 * diagnose.
 *
 * So the interesting events of *both* layers (the Kotlin foreground service, the
 * accessibility host, the Dart radar pipeline) are appended to one small text
 * file in `filesDir`, and a heartbeat is written every few seconds while the
 * pipeline runs. Reading that file on the next launch answers the only question
 * that matters after a silent failure: **how long after I left did it actually
 * die?**
 *
 * Format — one event per line, `|`-separated, oldest first:
 *
 * ```
 * 1759839204123|18:53:24|hb|fx 41.2 km/s
 * 1759839211088|18:53:31|service|foreground started
 * ```
 *
 * The file is capped: once it grows past [maxLines] the oldest half is dropped,
 * so a long-running install can never fill the phone.
 */
object DiagLog {

    const val HEARTBEAT = "hb"

    private const val FILE_NAME = "session.log"
    private const val maxLines = 600
    private const val trimTo = 300

    private val lock = Any()

    @Volatile
    private var file: File? = null

    /** Lines appended since the file was last trimmed, to avoid re-reading it. */
    private var appended = 0

    private fun fileFor(context: Context): File? {
        file?.let { return it }
        synchronized(lock) {
            file?.let { return it }
            return runCatching {
                File(context.applicationContext.filesDir, FILE_NAME).also {
                    file = it
                    appended = countLines(it)
                }
            }.getOrNull()
        }
    }

    /**
     * Records one event. [name] is a short, stable tag (`service`, `lockHud`,
     * `engine`, `alarm`, …) so the log can be scanned by eye.
     */
    fun event(context: Context, name: String, detail: String? = null) {
        append(context, name, detail)
    }

    /**
     * "Still alive" marker. Written by the native service *and* by the Dart
     * pipeline, which is what makes it possible to tell a dead process from a
     * live process whose Dart isolate stopped ticking.
     */
    fun heartbeat(context: Context, detail: String? = null) {
        append(context, HEARTBEAT, detail)
    }

    private fun append(context: Context, name: String, detail: String?) {
        val target = fileFor(context) ?: return
        val now = System.currentTimeMillis()
        val line = "$now|${clock(now)}|$name|${detail.orEmpty().replace('\n', ' ')}"
        synchronized(lock) {
            runCatching {
                target.appendText(line + "\n")
                appended += 1
                if (appended > maxLines) trim(target)
            }
        }
    }

    /** All recorded lines, oldest first. */
    fun lines(context: Context): List<String> {
        val target = fileFor(context) ?: return emptyList()
        return synchronized(lock) {
            runCatching { target.readLines() }.getOrDefault(emptyList())
        }
    }

    fun clear(context: Context) {
        val target = fileFor(context) ?: return
        synchronized(lock) {
            runCatching { target.writeText("") }
            appended = 0
        }
    }

    /**
     * Wall clock of the newest heartbeat, or 0 when there is none. A gap between
     * this and "now" is the honest measure of how long the background pipeline
     * has been down.
     */
    fun lastHeartbeatMs(context: Context): Long {
        val stamp = lines(context).lastOrNull { line ->
            line.split('|').getOrNull(2) == HEARTBEAT
        } ?: return 0L
        return stamp.substringBefore('|').toLongOrNull() ?: 0L
    }

    /**
     * Marks the start of a new process. Called once by the application, so the
     * log always shows where one run ended and the next began.
     */
    fun beginSession(context: Context, detail: String) {
        val stack = lines(context)
        // Never let a session marker be evicted while it is still current: it is
        // the anchor every gap measurement is relative to.
        if (stack.size > maxLines) {
            val trimmed = stack.takeLast(trimTo)
            fileFor(context)?.let { target ->
                synchronized(lock) {
                    runCatching { target.writeText(trimmed.joinToString("\n") + "\n") }
                    appended = trimmed.size
                }
            }
        }
        event(context, "boot", "#${System.currentTimeMillis()} $detail")
    }

    private fun trim(target: File) {
        val kept = runCatching { target.readLines().takeLast(trimTo) }.getOrNull() ?: return
        runCatching { target.writeText(kept.joinToString("\n") + "\n") }
        appended = kept.size
    }

    private fun countLines(target: File): Int =
        runCatching {
            if (target.exists()) target.readLines().size else 0
        }.getOrDefault(0)

    private fun clock(at: Long): String =
        java.text.SimpleDateFormat("HH:mm:ss", Locale.US).format(java.util.Date(at))
}
