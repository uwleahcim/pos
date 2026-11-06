package org.chinasky.pos_app

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/// Shows over the lock screen and lights it up when brought up for a call (the full-screen notification,
/// or Answer on it), and hands what was tapped on a notification to the app's phone over the call channel.
class MainActivity : FlutterActivity() {
    private var calls: CallChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        calls = CallChannel(this, flutterEngine.dartExecutor.binaryMessenger).also { it.takeIntent(intent) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        calls?.takeIntent(intent)
    }

    override fun onDestroy() {
        calls?.close()
        calls = null
        super.onDestroy()
    }
}
