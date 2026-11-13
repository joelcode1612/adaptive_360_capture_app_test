package com.adaptive360.adaptive_360_capture_app.ar

import android.app.Activity
import android.os.Handler
import android.os.Looper
import com.google.ar.core.ArCoreApk
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * The Flutter side of the ARCore host.
 *
 * ## Why a native host rather than an AR Flutter plugin
 *
 * Section 1 needs four things at once: an arbitrary world-space raycast (not
 * just a screen-tap hit test), anchors created at the raycast hit, a fresh live
 * camera pose at 15 Hz, and a photograph taken *through* the running session —
 * because ARCore holds the camera exclusively and CameraX cannot open it at the
 * same time. No maintained Flutter AR package exposes all four, and the ones
 * that come closest render through Sceneform, which would mean replacing the two
 * shipped `.glb` assets with a second, different model pipeline.
 *
 * So this host is a plain `MethodChannel` + `EventChannel` + Flutter `Texture`.
 * ARCore supplies the session, the planes, the anchors, the pose, the projection
 * matrices and the camera image; the mesh it draws is the very same geometry the
 * Dart GLB parser produces from the shipped assets.
 */
class ArCoreCapturePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // A delayed Flutter main isolate must not turn into an unbounded queue of
    // old poses. Ordinary poses coalesce, but tracking-continuity boundaries
    // must arrive in order: Dart needs to see a loss/recovery before it may use
    // a later TRACKING pose for guidance or capture.
    private val poseDeliveryLock = Any()
    private var pendingPoseEvent: Map<String, Any?>? = null
    private var poseDeliveryQueued = false
    private var poseDeliveryGeneration = 0L
    private var listenerGeneration = 0L

    private var textureRegistry: TextureRegistry? = null
    private var appContext: android.content.Context? = null
    private var activity: Activity? = null

    private var controller: ArCoreSessionController? = null

    // ── FlutterPlugin ────────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        textureRegistry = binding.textureRegistry
        channel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        channel?.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel?.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    synchronized(poseDeliveryLock) {
                        eventSink = events
                        listenerGeneration++
                    }
                }

                override fun onCancel(arguments: Any?) {
                    synchronized(poseDeliveryLock) {
                        eventSink = null
                        pendingPoseEvent = null
                        poseDeliveryQueued = false
                        // A previously queued main-thread delivery belongs to
                        // the cancelled listener and must not leak into a new
                        // subscription.
                        poseDeliveryGeneration++
                        listenerGeneration++
                    }
                }
            },
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        controller?.dispose()
        controller = null
        channel?.setMethodCallHandler(null)
        channel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        eventSink = null
        textureRegistry = null
        appContext = null
    }

    // ── ActivityAware ────────────────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    // ── MethodChannel ────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkAvailability" -> result.success(requireControllerOrNull()?.checkAvailability() ?: run {
                val ctx = appContext
                if (ctx == null) {
                    result.error("no_context", "The plugin has no application context.", null)
                    return
                }
                // The controller owns one AR thread; availability is a binder
                // call that needs no session, so it can be answered directly.
                ArCoreAvailabilityProbe.probe(ctx)
            })

            "requestInstall" -> {
                val act = activity
                if (act == null) {
                    result.error("no_activity", "No activity is attached.", null)
                    return
                }
                val status = try {
                    ArCoreApk.getInstance().requestInstall(act, true)
                } catch (e: Exception) {
                    result.error("install_failed", "$e", null)
                    return
                }
                result.success(
                    mapOf(
                        "installed" to (status == ArCoreApk.InstallStatus.INSTALLED),
                        "status" to status.name,
                    ),
                )
            }

            "start" -> {
                val registry = textureRegistry
                val ctx = appContext
                if (registry == null || ctx == null) {
                    result.error("not_attached", "The plugin is not attached to an engine.", null)
                    return
                }
                val withPlanes = call.argument<Boolean>("planes") ?: true
                val width = call.argument<Int>("width") ?: 1
                val height = call.argument<Int>("height") ?: 1
                val rotation = call.argument<Int>("rotation") ?: currentRotation()
                val existing = controller
                if (existing != null) {
                    existing.resize(width, height)
                    existing.setDisplayRotation(rotation)
                    // The Dart host reads capabilities (cameraImage in
                    // particular) from every start, not just the first. The
                    // reuse path used to answer with only an id, so a second
                    // caller believed stills were unsupported.
                    val value = HashMap<String, Any?>(existing.capabilities())
                    value["textureId"] = existing.textureId
                    value["reused"] = true
                    // The mode that claims an existing controller must also
                    // receive its requested plane configuration. In particular,
                    // opening the markerless 26-target flow after another AR
                    // workflow must not inherit plane finding from that owner.
                    value["planes"] = withPlanes
                    existing.setPlaneDetection(withPlanes) { configured ->
                        if (configured.errorCode != null) {
                            result.error(
                                configured.errorCode,
                                configured.errorMessage,
                                null,
                            )
                            return@setPlaneDetection
                        }
                        // A caller that starts while the previous owner has the
                        // session paused gets a camera, not a frozen texture. The
                        // world origin is kept either way.
                        if (existing.isPaused) {
                            existing.resume { outcome ->
                                if (outcome.errorCode != null) {
                                    result.error(
                                        outcome.errorCode,
                                        outcome.errorMessage,
                                        null,
                                    )
                                } else {
                                    result.success(value)
                                }
                            }
                        } else {
                            result.success(value)
                        }
                    }
                    return
                }
                val entry = registry.createSurfaceTexture()
                val created = ArCoreSessionController(ctx, entry, ::deliverEvent)
                controller = created
                created.start(withPlanes, rotation, width, height) { outcome ->
                    if (outcome.errorCode != null) {
                        // Dispose the half-built controller before letting go
                        // of it: closing the session, tearing down EGL, ending
                        // the AR thread and releasing the texture entry.
                        created.dispose()
                        if (controller === created) controller = null
                        result.error(outcome.errorCode, outcome.errorMessage, null)
                    } else {
                        val value = HashMap<String, Any?>(outcome.value ?: emptyMap())
                        value["textureId"] = created.textureId
                        result.success(value)
                    }
                }
            }

            "stop" -> {
                val existing = controller
                if (existing == null) {
                    result.success(null)
                    return
                }
                existing.stop {
                    existing.dispose()
                    controller = null
                    result.success(null)
                }
            }

            "pause" -> {
                val existing = controller
                if (existing == null) {
                    result.error("no_session", "No AR session is running.", null)
                    return
                }
                existing.pause { outcome -> answer(result, outcome) }
            }

            "resume" -> {
                val existing = controller
                if (existing == null) {
                    result.error("no_session", "No AR session is running.", null)
                    return
                }
                existing.resume { outcome -> answer(result, outcome) }
            }

            "resize" -> {
                controller?.resize(
                    call.argument<Int>("width") ?: 1,
                    call.argument<Int>("height") ?: 1,
                )
                // Flutter delivers a resize for orientation, multi-window and
                // display-density changes. Refresh ARCore's display geometry
                // from Android at the same boundary so its camera texture and
                // projection use the same physical viewport as Flutter.
                controller?.setDisplayRotation(currentRotation())
                result.success(null)
            }

            "setDisplayRotation" -> {
                controller?.setDisplayRotation(call.argument<Int>("rotation") ?: 0)
                result.success(null)
            }

            "setPlaneDetection" -> {
                val existing = controller
                if (existing == null) {
                    result.error("no_session", "No AR session is running.", null)
                    return
                }
                existing.setPlaneDetection(call.argument<Boolean>("enabled") ?: true) { outcome ->
                    answer(result, outcome)
                }
            }

            "setMesh" -> {
                val id = call.argument<String>("id") ?: "target"
                val positions = toFloatArray(call.argument<Any?>("positions"))
                val colors = toFloatArray(call.argument<Any?>("colors"))
                if (positions == null || colors == null) {
                    result.error("bad_mesh", "Mesh payload was missing or not a Float32List.", null)
                    return
                }
                controller?.setMesh(id, positions, colors)
                result.success(null)
            }

            "setScene" -> {
                controller?.setScene(parseScene(call.argument<List<Map<String, Any?>>>("draws")))
                result.success(null)
            }

            "probeDirections" -> {
                val existing = controller
                if (existing == null) {
                    result.error("no_session", "No AR session is running.", null)
                    return
                }
                val origin = (call.argument<List<Double>>("origin") ?: emptyList())
                    .map { it.toFloat() }
                    .toFloatArray()
                val directions = (call.argument<List<Double>>("directions") ?: emptyList())
                    .map { it.toFloat() }
                    .toFloatArray()
                if (origin.size != 3 || directions.size % 3 != 0) {
                    result.error(
                        "bad_args",
                        "origin needs 3 values and directions a multiple of 3.",
                        null,
                    )
                    return
                }
                existing.probeDirections(
                    origin = origin,
                    directions = directions,
                    maxDistanceM = (call.argument<Double>("maxDistanceM") ?: 8.0).toFloat(),
                ) { outcome -> answer(result, outcome) }
            }

            "raycast" -> {
                val existing = controller
                if (existing == null) {
                    result.error("no_session", "No AR session is running.", null)
                    return
                }
                val origin = floatArrayOf(
                    (call.argument<Double>("ox") ?: 0.0).toFloat(),
                    (call.argument<Double>("oy") ?: 0.0).toFloat(),
                    (call.argument<Double>("oz") ?: 0.0).toFloat(),
                )
                val direction = floatArrayOf(
                    (call.argument<Double>("dx") ?: 0.0).toFloat(),
                    (call.argument<Double>("dy") ?: 0.0).toFloat(),
                    (call.argument<Double>("dz") ?: 1.0).toFloat(),
                )
                existing.raycast(
                    ArCoreSessionController.RaycastSpec(
                        origin = origin,
                        direction = direction,
                        maxDistanceM = (call.argument<Double>("maxDistanceM") ?: 8.0).toFloat(),
                        surface = call.argument<String>("surface") ?: "plane",
                    ),
                ) { outcome ->
                    // A miss is a normal answer, not an error: the caller turns
                    // it into "scan this surface", never into a guessed anchor.
                    if (outcome.errorCode != null) {
                        result.error(outcome.errorCode, outcome.errorMessage, null)
                    } else {
                        result.success(outcome.value)
                    }
                }
            }

            "createAnchor" -> {
                val existing = controller
                if (existing == null) {
                    result.error("no_session", "No AR session is running.", null)
                    return
                }
                existing.createAnchor(
                    pose = floatArrayOf(
                        (call.argument<Double>("px") ?: 0.0).toFloat(),
                        (call.argument<Double>("py") ?: 0.0).toFloat(),
                        (call.argument<Double>("pz") ?: 0.0).toFloat(),
                        (call.argument<Double>("qx") ?: 0.0).toFloat(),
                        (call.argument<Double>("qy") ?: 0.0).toFloat(),
                        (call.argument<Double>("qz") ?: 0.0).toFloat(),
                        (call.argument<Double>("qw") ?: 1.0).toFloat(),
                    ),
                    planeKey = call.argument<String>("trackableKey"),
                ) { outcome -> answer(result, outcome) }
            }

            "refreshAnchor" -> {
                val existing = controller
                val id = call.argument<String>("id")
                if (existing == null || id == null) {
                    result.success(null)
                    return
                }
                existing.refreshAnchor(id) { outcome ->
                    if (outcome.errorCode != null) result.success(null) else answer(result, outcome)
                }
            }

            "detachAnchor" -> {
                controller?.detachAnchor(call.argument<String>("id") ?: "")
                result.success(null)
            }

            "setActiveAnchor" -> {
                controller?.setActiveAnchor(call.argument<String>("id")) { outcome ->
                    answer(result, outcome)
                }
                if (controller == null) result.success(null)
            }

            "rescan" -> {
                val existing = controller
                if (existing == null) {
                    result.error("no_session", "No AR session is running.", null)
                    return
                }
                existing.rescan { outcome -> answer(result, outcome) }
            }

            "takeStill" -> {
                val existing = controller
                if (existing == null) {
                    result.error("no_session", "No AR session is running.", null)
                    return
                }
                existing.takeStill(call.argument<Int>("quality") ?: 95) { outcome ->
                    if (outcome.errorCode != null) {
                        result.error(outcome.errorCode, outcome.errorMessage, null)
                    } else {
                        result.success(outcome.value)
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun answer(result: MethodChannel.Result, outcome: ArOutcome) {
        if (outcome.errorCode != null) {
            result.error(outcome.errorCode, outcome.errorMessage, null)
        } else {
            result.success(outcome.value)
        }
    }

    private fun requireControllerOrNull(): ArCoreSessionController? = controller

    /**
     * Reads a `Float32List` from the message codec.
     *
     * `StandardMessageCodec` hands a `Float32List` to Android as a
     * `java.nio.FloatBuffer`, and a plain `List` when Dart sent one, so both
     * shapes are accepted rather than assumed.
     */
    private fun toFloatArray(value: Any?): FloatArray? = when (value) {
        is java.nio.FloatBuffer -> {
            val out = FloatArray(value.remaining())
            value.get(out)
            out
        }
        is List<*> -> FloatArray(value.size) { i ->
            (value.getOrNull(i) as? Number)?.toFloat() ?: 0f
        }
        is FloatArray -> value
        else -> null
    }

    /** Guarantees four components so a short payload cannot silently rotate. */
    private fun paddedQuaternion(source: FloatArray?): FloatArray {
        if (source == null || source.size < 4) return floatArrayOf(0f, 0f, 0f, 1f)
        return floatArrayOf(source[0], source[1], source[2], source[3])
    }

    private fun currentRotation(): Int = try {
        @Suppress("DEPRECATION")
        activity?.windowManager?.defaultDisplay?.rotation ?: 0
    } catch (_: Exception) {
        0
    }

    private fun deliverEvent(event: Map<String, Any?>) {
        val isPose = event["type"] == "pose"
        val isContinuityBoundary =
            event["trackingTransition"] == true ||
                event["trackingContinuityBroken"] == true
        if (!isPose || isContinuityBoundary) {
            deliverOrdered(event)
            return
        }

        val generation: Long
        synchronized(poseDeliveryLock) {
            pendingPoseEvent = event
            if (poseDeliveryQueued) return
            poseDeliveryQueued = true
            generation = poseDeliveryGeneration
        }
        mainHandler.post {
            val pending = synchronized(poseDeliveryLock) {
                // An ordered event or a stream cancellation invalidated this
                // coalesced delivery.  Never let it overtake that boundary.
                if (generation != poseDeliveryGeneration) {
                    null
                } else {
                    poseDeliveryQueued = false
                    pendingPoseEvent.also { pendingPoseEvent = null }
                }
            }
            pending?.let { eventSink?.success(it) }
        }
    }

    /**
     * Delivers a recovery boundary without letting a previously coalesced pose
     * overtake it.  The generation invalidates the callback already queued for
     * that old pose; a subsequent ordinary pose queues after this main-thread
     * post and therefore remains ordered behind the boundary.
     */
    private fun deliverOrdered(event: Map<String, Any?>) {
        val listener: Long
        synchronized(poseDeliveryLock) {
            pendingPoseEvent = null
            poseDeliveryQueued = false
            poseDeliveryGeneration++
            listener = listenerGeneration
        }
        mainHandler.post {
            val sink = synchronized(poseDeliveryLock) {
                // A listener can be cancelled and recreated before this
                // main-thread callback runs. Do not inject an old session's
                // tracking boundary into the new subscription. Multiple
                // ordered boundaries intentionally share this listener token,
                // so PAUSED then TRACKING still arrive in order.
                if (listener == listenerGeneration) eventSink else null
            }
            sink?.success(event)
        }
    }

    private fun parseScene(raw: List<Map<String, Any?>>?): List<ArCoreSessionController.DrawSpec> {
        if (raw == null) return emptyList()
        val out = ArrayList<ArCoreSessionController.DrawSpec>(raw.size)
        for (item in raw) {
            val anchorId = item["anchorId"] as? String ?: continue
            val rotation = paddedQuaternion(toFloatArray(item["localRotation"]))
            // The engine's model matrix, when Dart sent one. Length-checked so a
            // truncated array falls back to the quaternion path rather than
            // producing a malformed transform.
            val modelMatrix = toFloatArray(item["modelMatrix"])
                ?.takeIf { it.size == 16 }
            out.add(
                ArCoreSessionController.DrawSpec(
                    meshId = item["meshId"] as? String ?: "target",
                    anchorId = anchorId,
                    localRotation = rotation,
                    scale = (item["scale"] as? Number)?.toFloat() ?: 1f,
                    offsetX = (item["offsetX"] as? Number)?.toFloat() ?: 0f,
                    offsetY = (item["offsetY"] as? Number)?.toFloat() ?: 0f,
                    offsetZ = (item["offsetZ"] as? Number)?.toFloat() ?: 0f,
                    tintR = (item["tintR"] as? Number)?.toFloat() ?: 1f,
                    tintG = (item["tintG"] as? Number)?.toFloat() ?: 1f,
                    tintB = (item["tintB"] as? Number)?.toFloat() ?: 1f,
                    tintA = (item["tintA"] as? Number)?.toFloat() ?: 1f,
                    useTint = item["useTint"] as? Boolean ?: false,
                    opacity = (item["opacity"] as? Number)?.toFloat() ?: 1f,
                    requireTracking = item["requireTracking"] as? Boolean ?: true,
                    modelMatrix = modelMatrix,
                    useModelTranslation = item["useModelTranslation"] as? Boolean ?: false,
                ),
            )
        }
        return out
    }

    internal object ArCoreAvailabilityProbe {
        fun probe(context: android.content.Context): Map<String, Any?> {
            val availability = try {
                ArCoreApk.getInstance().checkAvailability(context)
            } catch (e: Exception) {
                return mapOf(
                    "supported" to false,
                    "serviceInstalled" to false,
                    "reason" to "ARCore availability could not be checked: ${e.message}",
                )
            }
            return mapOf(
                "supported" to availability.isSupported,
                "serviceInstalled" to (availability == ArCoreApk.Availability.SUPPORTED_INSTALLED),
                "reason" to if (availability.isSupported) {
                    null
                } else {
                    "This device does not support ARCore."
                },
            )
        }
    }

    companion object {
        const val METHOD_CHANNEL = "adaptive360/arcore"
        const val EVENT_CHANNEL = "adaptive360/arcore/events"
    }
}
