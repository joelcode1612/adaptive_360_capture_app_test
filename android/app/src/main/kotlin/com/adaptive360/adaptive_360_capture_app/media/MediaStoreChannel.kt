package com.adaptive360.adaptive_360_capture_app.media

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Saves a finished panorama into the phone's shared Pictures collection.
 *
 * The app already keeps a private copy under `app_flutter/ar_capture/...` and
 * an app-specific external copy under `Android/data/.../SiteWise360/...`.
 * Neither is visible in the Gallery, and the latter disappears when the app is
 * uninstalled. MediaStore is the only place a user can actually find the
 * panorama from the Photos app.
 *
 * On Android 10+ the insert is scoped-storage safe and needs no permission;
 * `IS_PENDING` hides the half-written file until the copy finishes. On older
 * releases it writes to the public Pictures directory, which needs
 * `WRITE_EXTERNAL_STORAGE` (declared with `maxSdkVersion="28"`).
 */
class MediaStoreChannel(private val context: Context) :
    MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "saveImage") {
            result.notImplemented()
            return
        }
        val source = call.argument<String>("sourcePath")
        val folder = call.argument<String>("folder") ?: "SiteWise360"
        val fileName = call.argument<String>("fileName") ?: "panorama.jpg"
        if (source.isNullOrBlank()) {
            result.error("bad_args", "sourcePath is required.", null)
            return
        }
        try {
            result.success(saveImage(File(source), folder, fileName))
        } catch (error: Exception) {
            result.error("save_failed", error.message ?: error.toString(), null)
        }
    }

    private fun saveImage(source: File, folder: String, fileName: String): String {
        if (!source.exists() || source.length() == 0L) {
            throw IllegalArgumentException("The source image is missing: ${source.path}")
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            saveViaMediaStore(source, folder, fileName)
        } else {
            saveToPublicPictures(source, folder, fileName)
        }
    }

    private fun saveViaMediaStore(
        source: File,
        folder: String,
        fileName: String,
    ): String {
        val relativePath = "${Environment.DIRECTORY_PICTURES}/$folder/"
        val resolver = context.contentResolver
        val collection = MediaStore.Images.Media.getContentUri(
            MediaStore.VOLUME_EXTERNAL_PRIMARY,
        )

        // Replace a previous copy of the same name instead of stacking
        // duplicates when the user regenerates a panorama.
        try {
            resolver.delete(
                collection,
                "${MediaStore.Images.Media.DISPLAY_NAME}=? AND " +
                    "${MediaStore.Images.Media.RELATIVE_PATH}=?",
                arrayOf(fileName, relativePath),
            )
        } catch (_: Exception) {
            // A failed cleanup must not stop the save; a duplicate is better
            // than no panorama.
        }

        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            put(MediaStore.Images.Media.RELATIVE_PATH, relativePath)
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("MediaStore refused the image insert.")
        try {
            resolver.openOutputStream(uri)?.use { output ->
                source.inputStream().use { input -> input.copyTo(output) }
            } ?: throw IllegalStateException("Could not open the MediaStore output.")
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return uri.toString()
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
    }

    @Suppress("DEPRECATION")
    private fun saveToPublicPictures(
        source: File,
        folder: String,
        fileName: String,
    ): String {
        val directory = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
            folder,
        )
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("Could not create ${directory.path}")
        }
        val target = File(directory, fileName)
        source.inputStream().use { input ->
            target.outputStream().use { output -> input.copyTo(output) }
        }
        return target.absolutePath
    }
}
