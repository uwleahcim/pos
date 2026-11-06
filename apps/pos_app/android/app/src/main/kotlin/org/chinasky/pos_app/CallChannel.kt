package org.chinasky.pos_app

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// The device's part in calls on Android, for the app's phone (lib/call_screen.dart): the foreground service
/// that keeps the app alive with the screen off while the phone is on or a desk phone is linked, the
/// full-screen notification that lights a locked screen for a call (with Answer and Decline), the notification
/// for a desk-phone pick-up, and what the person still has to allow. Android has no push here: the app itself
/// rings and answers; the notification's buttons come back to it as `answer` and `end`.
class CallChannel(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "org.chinasky.pos/calls")
    private val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private var ready = false
    private val pending = ArrayList<Pair<String, Map<String, Any?>>>()

    init {
        channel.setMethodCallHandler(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CALLS, "Calls", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "An incoming call on the restaurant's line"
                    setSound(null, null) // the app rings itself
                    enableVibration(true)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                }
            )
            manager.createNotificationChannel(
                NotificationChannel(POPS, "Desk phone pick-ups", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "A desk phone linked to this screen picked up"
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                }
            )
        }
    }

    fun close() = channel.setMethodCallHandler(null)

    /// What a tap on a notification asked for, carried in the intent that brought the activity up.
    fun takeIntent(intent: Intent?) {
        val id = intent?.getStringExtra("id") ?: ""
        when (intent?.action) {
            ACTION_ANSWER -> send("answer", mapOf("id" to id))
            ACTION_END -> send("end", mapOf("id" to id))
            ACTION_OPENED -> send("opened", emptyMap())
        }
        intent?.action = null // taken once
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id") ?: ""
        when (call.method) {
            "ready" -> {
                ready = true
                val queued = ArrayList(pending)
                pending.clear()
                for ((method, args) in queued) send(method, args)
                result.success(null)
            }
            "keepAwake" -> {
                PhoneService.set(activity, call.argument<Boolean>("on") ?: false)
                result.success(null)
            }
            "incoming" -> {
                showIncoming(id, call.argument<String>("number") ?: "", call.argument<String>("name") ?: "")
                result.success(null)
            }
            "answer", "end" -> {
                // the app acts itself on Android; the notification's buttons come back the same way
                send(call.method, mapOf("id" to id))
                result.success(null)
            }
            "connected" -> {
                showOnCall(id)
                result.success(null)
            }
            "ended" -> {
                manager.cancel(CALL_NOTIFICATION)
                result.success(null)
            }
            "wake" -> {
                showPop(call.argument<String>("title") ?: "", call.argument<String>("body") ?: "")
                result.success(null)
            }
            "readiness" -> result.success(readiness())
            "prepare" -> {
                prepare()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun send(method: String, args: Map<String, Any?>) {
        if (!ready) {
            pending.add(method to args)
            return
        }
        activity.runOnUiThread { channel.invokeMethod(method, args) }
    }

    // --- notifications ---------------------------------------------------------------------------------------

    private fun builder(channelId: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(activity, channelId)
        else @Suppress("DEPRECATION") Notification.Builder(activity)

    private fun toActivity(action: String, id: String, code: Int): PendingIntent {
        val intent = Intent(activity, MainActivity::class.java)
            .setAction(action)
            .putExtra("id", id)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(activity, code, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /// A call rings: a full-screen notification lights a locked screen and brings the app up (its banner shows
    /// the call); with the screen on, a heads-up notification with Answer and Decline.
    private fun showIncoming(id: String, number: String, name: String) {
        val who = listOf(pretty(number), name).filter { it.isNotEmpty() }.joinToString(" · ").ifEmpty { "Restaurant line" }
        val notification = builder(CALLS)
            .setSmallIcon(android.R.drawable.stat_sys_phone_call)
            .setContentTitle("Incoming call")
            .setContentText(who)
            .setCategory(Notification.CATEGORY_CALL)
            .setPriority(Notification.PRIORITY_MAX)
            .setOngoing(true)
            .setAutoCancel(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(toActivity(ACTION_OPENED, id, 1))
            .setFullScreenIntent(toActivity(ACTION_OPENED, id, 2), true)
            .addAction(Notification.Action.Builder(null, "Answer", toActivity(ACTION_ANSWER, id, 3)).build())
            .addAction(Notification.Action.Builder(null, "Decline", toActivity(ACTION_END, id, 4)).build())
            .build()
        manager.notify(CALL_NOTIFICATION, notification)
    }

    private fun showOnCall(id: String) {
        val notification = builder(CALLS)
            .setSmallIcon(android.R.drawable.stat_sys_phone_call)
            .setContentTitle("On a call")
            .setContentText("Restaurant line")
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(toActivity(ACTION_OPENED, id, 1))
            .addAction(Notification.Action.Builder(null, "Hang up", toActivity(ACTION_END, id, 4)).build())
            .build()
        manager.notify(CALL_NOTIFICATION, notification)
    }

    /// A desk phone linked to this screen picked up: the screen lights up and the app comes up with the order;
    /// when it cannot (the system keeps the app in the background), the notification says so and a tap opens it.
    private fun showPop(title: String, body: String) {
        val notification = builder(POPS)
            .setSmallIcon(android.R.drawable.stat_sys_phone_call)
            .setContentTitle(title)
            .setContentText(body)
            .setCategory(Notification.CATEGORY_CALL)
            .setPriority(Notification.PRIORITY_MAX)
            .setAutoCancel(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(toActivity(ACTION_OPENED, "", 5))
            .setFullScreenIntent(toActivity(ACTION_OPENED, "", 6), true)
            .build()
        manager.notify(POP_NOTIFICATION, notification)
    }

    // --- what the person still has to allow -------------------------------------------------------------------

    private fun readiness(): Map<String, Boolean> {
        val power = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
        return mapOf(
            "notifications" to manager.areNotificationsEnabled(),
            "fullScreen" to fullScreenAllowed(),
            "battery" to power.isIgnoringBatteryOptimizations(activity.packageName),
        )
    }

    private fun fullScreenAllowed(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) manager.canUseFullScreenIntent() else true

    /// Asks with the system's own dialogs: notifications (Android 13+), then no battery limits; the full-screen
    /// permission (Android 14+) is a settings page, opened when the rest is allowed.
    private fun prepare() {
        val power = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !manager.areNotificationsEnabled()) {
            activity.requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 7)
            return
        }
        if (!power.isIgnoringBatteryOptimizations(activity.packageName)) {
            activity.startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${activity.packageName}"))
            )
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && !manager.canUseFullScreenIntent()) {
            activity.startActivity(
                Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:${activity.packageName}"))
            )
        }
    }

    private fun pretty(number: String): String {
        var digits = number.filter { it.isDigit() }
        if (digits.length == 11 && digits.startsWith("1")) digits = digits.substring(1)
        if (digits.length != 10) return number
        return "(${digits.substring(0, 3)}) ${digits.substring(3, 6)}-${digits.substring(6)}"
    }

    companion object {
        const val CALLS = "calls"
        const val POPS = "pops"
        const val CALL_NOTIFICATION = 11
        const val POP_NOTIFICATION = 12
        const val ACTION_ANSWER = "org.chinasky.pos.ANSWER"
        const val ACTION_END = "org.chinasky.pos.END"
        const val ACTION_OPENED = "org.chinasky.pos.OPENED"
    }
}
