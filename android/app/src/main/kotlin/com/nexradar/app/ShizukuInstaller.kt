package com.nexradar.app

import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import rikka.shizuku.Shizuku
import java.io.BufferedReader
import java.io.InputStreamReader

/**
 * Silent updates, when the driver happens to have Shizuku.
 *
 * Android 12 and later removed every non-root way to install a package without
 * the system installer dialog: `REQUEST_INSTALL_PACKAGES` only unlocks the
 * package installer, it does not let an app replace itself. Shizuku closes that
 * gap by lending the app the shell's identity (the user starts Shizuku once,
 * either through ADB or with root), which is enough to run `pm install`.
 *
 * None of this is required. [isAvailable] answers false for the vast majority of
 * phones — no Shizuku installed, or the user never started it — and the updater
 * simply falls back to the system installer it has always used. That fallback is
 * the contract: this class can only ever make the update *quieter*, never
 * break it.
 *
 * The APK is streamed into `pm install -S <bytes>` over stdin rather than passed
 * as a path. `pm` runs as the shell user and cannot read the app's private cache
 * directory, so handing it a filename could never work.
 *
 * **The Shizuku artefacts are deliberately pinned to 12.1.0.** In 13.x the
 * client library made `newProcess` private and moved privileged work to a bound
 * user-service, which for a streamed install would mean shipping an AIDL service
 * and chunking 55 MB through Binder transactions. 12.1.0 speaks the same wire
 * protocol to any installed Shizuku server and keeps this to one readable
 * function. If the pin is ever lifted, this is the file that has to change — and
 * the fallback in [install] means nothing else would break.
 */
object ShizukuInstaller {

    private const val TAG = "NexRadarShizuku"

    /** Request code for the one-time Shizuku permission dialog. */
    const val REQUEST_CODE = 4712

    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var permissionListener: Shizuku.OnRequestPermissionResultListener? = null

    data class Result(val ok: Boolean, val detail: String)

    /** Is the Shizuku service running and reachable right now? */
    fun isAvailable(): Boolean = runCatching { Shizuku.pingBinder() }.getOrDefault(false)

    fun hasPermission(): Boolean {
        if (!isAvailable()) return false
        return runCatching {
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        }.getOrDefault(false)
    }

    /**
     * Asks for the Shizuku grant. The answer arrives on the main thread, so
     * [onResult] is always called there — the Dart side is already waiting.
     */
    fun requestPermission(onResult: (Boolean) -> Unit) {
        if (!isAvailable()) {
            onResult(false)
            return
        }
        runCatching {
            permissionListener?.let(Shizuku::removeRequestPermissionResultListener)
            val listener = Shizuku.OnRequestPermissionResultListener { requestCode, grantResult ->
                if (requestCode == REQUEST_CODE) {
                    onResult(grantResult == PackageManager.PERMISSION_GRANTED)
                }
            }
            permissionListener = listener
            Shizuku.addRequestPermissionResultListener(listener)
            Shizuku.requestPermission(REQUEST_CODE)
        }.onFailure {
            Log.w(TAG, "could not request the Shizuku grant", it)
            onResult(false)
        }
    }

    /**
     * Streams [apkPath] into `pm install` and reports what the shell said.
     *
     * Runs off the platform thread: the system channel handler must never block
     * while a 55 MB APK is copied through a pipe.
     */
    fun install(apkPath: String, onResult: (Result) -> Unit) {
        if (!hasPermission()) {
            onResult(Result(false, "Shizuku icazəsi yoxdur"))
            return
        }
        Thread {
            val result = runCatching { installBlocking(apkPath) }
                .getOrElse { t ->
                    Log.e(TAG, "silent install failed", t)
                    Result(false, t.message ?: "naməlum xəta")
                }
            main.post { onResult(result) }
        }.start()
    }

    private fun installBlocking(apkPath: String): Result {
        val file = java.io.File(apkPath)
        if (!file.exists()) return Result(false, "APK tapılmadı")

        val process = Shizuku.newProcess(
            arrayOf("pm", "install", "-r", "-t", "-S", file.length().toString()),
            null,
            null,
        )

        // Everything `pm` prints — including INSTALL_FAILED_* — arrives on these
        // two streams, so both are drained before the exit code is trusted.
        val output = StringBuilder()
        val drain = Thread {
            runCatching {
                BufferedReader(InputStreamReader(process.inputStream)).use { reader ->
                    reader.forEachLine { output.append(it).append('\n') }
                }
            }
        }
        drain.start()

        file.inputStream().use { input -> process.outputStream.use { input.copyTo(it) } }
        val exit = process.waitFor()
        drain.join(4000)

        val text = output.toString().trim()
        val ok = exit == 0 && !text.contains("Failure") && !text.contains("Error")
        return Result(ok, text.ifEmpty { "exit=$exit" })
    }
}
