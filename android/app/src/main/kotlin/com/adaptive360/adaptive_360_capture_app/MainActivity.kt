package com.adaptive360.adaptive_360_capture_app

import com.adaptive360.adaptive_360_capture_app.ar.ArCoreCapturePlugin
import com.adaptive360.adaptive_360_capture_app.media.MediaStoreChannel
import com.adaptive360.adaptive_360_capture_app.sensors.RotationSensorChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var rotationChannel: EventChannel? = null
    private var mediaChannel: MethodChannel? = null

    /**
     * Registers the ARCore host and the 3DoF rotation sensor.
     *
     * The AR host ships inside this app rather than as a pub package, so the
     * generated plugin registrar does not know about it. Adding it here — before
     * the activity is attached — is also what lets it implement `ActivityAware`,
     * which it needs for ARCore's install request and for reading the display
     * rotation it feeds to `Session.setDisplayGeometry`.
     *
     * The rotation channel is the only sensor the sphere-follows-phone flow
     * needs: `TYPE_ROTATION_VECTOR` at roughly 50 Hz.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(ArCoreCapturePlugin())
        val channel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "adaptive360/rotation",
        )
        channel.setStreamHandler(RotationSensorChannel(applicationContext))
        rotationChannel = channel

        // Saves the finished panorama into the shared Pictures collection so
        // it appears in the phone's Gallery, not only in app-private storage.
        val media = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "adaptive360/media",
        )
        media.setMethodCallHandler(MediaStoreChannel(applicationContext))
        mediaChannel = media
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        rotationChannel?.setStreamHandler(null)
        rotationChannel = null
        mediaChannel?.setMethodCallHandler(null)
        mediaChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
