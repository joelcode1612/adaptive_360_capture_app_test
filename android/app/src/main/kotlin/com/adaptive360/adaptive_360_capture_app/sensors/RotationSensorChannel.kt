package com.adaptive360.adaptive_360_capture_app.sensors

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import io.flutter.plugin.common.EventChannel

/**
 * The device rotation quaternion, as the 3DoF sphere architecture consumes it.
 *
 * `TYPE_ROTATION_VECTOR` is Android's fused orientation sensor: accelerometer,
 * gyroscope and (where present) magnetometer combined by the platform into one
 * unit quaternion. It is deliberately preferred over integrating the gyroscope
 * in Dart, because heading drift accumulated across a full 360° sweep would
 * rotate the target sphere away from the room it was anchored to.
 *
 * The stream carries `[x, y, z, w]` doubles. `SENSOR_DELAY_GAME` is roughly
 * 50 Hz — enough for a 5° alignment cone at normal turning speed, and half the
 * rate of a 60 FPS render loop so the UI is never waiting on the sensor.
 */
class RotationSensorChannel(private val context: Context) :
    EventChannel.StreamHandler,
    SensorEventListener {

    private var sink: EventChannel.EventSink? = null
    private var sensorManager: SensorManager? = null
    private var rotationSensor: Sensor? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        val manager = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
        sensorManager = manager
        val sensor = manager?.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
        if (manager == null || sensor == null) {
            events?.error(
                "no_rotation_sensor",
                "This device has no rotation vector sensor, so the sphere " +
                    "cannot follow the phone.",
                null,
            )
            return
        }
        rotationSensor = sensor
        manager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_GAME)
    }

    override fun onCancel(arguments: Any?) {
        sensorManager?.unregisterListener(this)
        sensorManager = null
        rotationSensor = null
        sink = null
    }

    override fun onSensorChanged(event: SensorEvent?) {
        if (event == null || event.sensor.type != Sensor.TYPE_ROTATION_VECTOR) return
        val values = event.values
        if (values.size < 4) return
        sink?.success(
            listOf(
                values[0].toDouble(),
                values[1].toDouble(),
                values[2].toDouble(),
                values[3].toDouble(),
            ),
        )
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        // The quaternion is used as reported; accuracy changes do not need a
        // separate event because a degraded estimate still points the sphere.
    }
}
