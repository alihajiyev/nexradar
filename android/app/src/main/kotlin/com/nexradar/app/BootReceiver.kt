package com.nexradar.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Brings the radar back after a reboot.
 *
 * A background-first HUD has one failure mode that no amount of foreground-
 * service code can survive: the phone restarts, and an app that only ever starts
 * its service from its own activity stays down until the driver remembers to
 * open it. Since the driver's whole reason for installing NexRadar is to *not*
 * think about it, the bubble would be missing exactly when a trip begins.
 *
 * Android allows a foreground service to be started from `BOOT_COMPLETED` (it is
 * one of the documented background-start exemptions), so the same path the
 * driver's tap uses runs here: start [RadarOverlayService], which asks the
 * application for the Flutter engine, which runs `main()` and resumes the
 * pipeline with no UI — the same `resumeInBackground()` the app uses after being
 * swiped away.
 *
 * Gated on "the driver had the bubble switched on", so an app that was turned off
 * is never resurrected behind his back.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON"
        ) {
            return
        }

        val desired = BubbleWindow.isDesired(context)
        DiagLog.event(context, "boot", "device booted · bubble desired=$desired")
        if (!desired) return

        runCatching { RadarOverlayService.start(context) }
            .onFailure { Log.w("NexRadarBoot", "could not restart the service", it) }
    }
}
