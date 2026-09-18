package com.apparence.camerawesome.cameraX

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.core.util.Consumer
import com.apparence.camerawesome.CamerawesomePlugin
import java.io.File
import java.util.Locale
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit

/**
 * Records one continuous capture as consecutive, complete mp4 files of at most
 * [segmentDurationMs] each, and reports every finished file through [emitter].
 *
 * Rollover is driven by the Status events of the active recording: the current
 * [Recording] is stopped and the next one is started right away on the same
 * [Recorder]. CameraX keeps the new recording pending until the previous file
 * is finalized, so the gap between two files is only the encoder restart
 * (typically 100-400 ms). A duration limit slightly above [segmentDurationMs]
 * is a safety net in case Status events stop arriving.
 *
 * Recordings are persistent so that rebinding the same [VideoCapture] (for
 * example when image analysis starts) does not end them. See
 * [CameraXState.updateLifecycle], which keeps the instance while this recorder
 * is active.
 *
 * Must be used from the main thread; [executor] must be the main executor.
 */
@SuppressLint("MissingPermission", "UnsafeOptInUsageError")
class SegmentedVideoRecorder(
    private val context: Context,
    private val videoCapture: VideoCapture<Recorder>,
    private val basePath: String,
    segmentDurationMs: Long,
    private val withAudio: Boolean,
    private val executor: Executor,
    private val emitter: VideoSegmentsStreamHandler,
) {
    private class Segment(val index: Int, val path: String) {
        var recording: Recording? = null
        var startedAtEpochMs: Long? = null
        var rolloverRequested = false
    }

    private val segmentNanos = TimeUnit.MILLISECONDS.toNanos(segmentDurationMs)
    private val durationLimitMs = segmentDurationMs + DURATION_LIMIT_MARGIN_MS
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Segments started but not finalized yet, by index. */
    private val openSegments = HashMap<Int, Segment>()
    private var currentIndex = -1
    private var startedCount = 0
    private var finalizedCount = 0

    /** Set when no further segment will be started (stop, error, interruption). */
    private var ending = false
    private var ended = false
    private var stopRequested = false
    private var anyUsable = false
    private val stopCallbacks = mutableListOf<(Boolean) -> Unit>()
    private val stopWatchdog = Runnable { onStopTimeout() }

    /// Consecutive segments killed before they produced any data (the camera
    /// was rebound while they were pending).
    private var abortedStartRetries = 0

    /** True until the last segment of this recording has been reported. */
    val isActive: Boolean
        get() = !ended

    /// Starts the first segment. Returns false when the recording could not
    /// be started at all (nothing is reported in that case).
    fun start(): Boolean {
        if (startSegment(0)) return true
        ending = true
        ended = true
        return false
    }

    /**
     * Stops the recording. [callback] receives true when at least one usable
     * segment was produced. The final segment event is emitted before
     * [callback] is invoked.
     */
    fun stop(callback: (Boolean) -> Unit) {
        if (ended) {
            callback(anyUsable)
            return
        }
        // Every caller is answered: stop can be requested more than once
        // (user stop, app backgrounded, camera disposed).
        stopCallbacks.add(callback)
        if (stopRequested) return
        stopRequested = true
        ending = true
        for (segment in openSegments.values) {
            segment.recording?.stop()
        }
        if (finalizedCount == startedCount) {
            // Nothing left to finalize (e.g. the last start failed).
            finish()
            return
        }
        mainHandler.postDelayed(stopWatchdog, STOP_TIMEOUT_MS)
    }

    private fun pathFor(index: Int): String {
        if (index == 0) return basePath
        val file = File(basePath)
        val extension = file.extension.ifEmpty { "mp4" }
        val stem = file.nameWithoutExtension
        return File(file.parentFile, String.format(Locale.US, "%s_%03d.%s", stem, index, extension)).path
    }

    /// Starts one segment. Returns false when CameraX refused to start it;
    /// no event is reported for a segment that never existed.
    private fun startSegment(index: Int): Boolean {
        val segment = Segment(index, pathFor(index))
        val recording = try {
            val outputOptions = FileOutputOptions.Builder(File(segment.path))
                .setDurationLimitMillis(durationLimitMs)
                .build()
            videoCapture.output
                .prepareRecording(context, outputOptions)
                .apply { if (withAudio) withAudioEnabled() }
                .asPersistentRecording()
                .start(executor, Consumer<VideoRecordEvent> { event -> onEvent(segment, event) })
        } catch (e: Exception) {
            Log.e(CamerawesomePlugin.TAG, "Could not start video segment $index", e)
            deleteQuietly(segment.path)
            return false
        }
        segment.recording = recording
        currentIndex = index
        startedCount++
        openSegments[index] = segment
        return true
    }

    private fun onEvent(segment: Segment, event: VideoRecordEvent) {
        when (event) {
            is VideoRecordEvent.Start -> {
                segment.startedAtEpochMs = System.currentTimeMillis()
                abortedStartRetries = 0
            }

            is VideoRecordEvent.Status -> {
                if (segment.index == currentIndex &&
                    !ending &&
                    !segment.rolloverRequested &&
                    event.recordingStats.recordedDurationNanos >= segmentNanos
                ) {
                    rollover(segment)
                }
            }

            is VideoRecordEvent.Finalize -> onFinalize(segment, event)
        }
    }

    private fun rollover(segment: Segment) {
        segment.rolloverRequested = true
        segment.recording?.stop()
        // Legal while the previous recording is stopping: the Recorder queues
        // this one and starts it as soon as the previous file is finalized.
        if (!startSegment(segment.index + 1)) {
            // Nothing follows this segment: its finalize ends the recording.
            ending = true
        }
    }

    private fun onFinalize(segment: Segment, event: VideoRecordEvent.Finalize) {
        openSegments.remove(segment.index)
        finalizedCount++
        segment.recording?.close()
        segment.recording = null

        val error = event.error
        val file = File(segment.path)
        val usable = file.exists() && file.length() > 0 && error in USABLE_ERRORS
        if (usable) {
            anyUsable = true
        } else {
            deleteQuietly(segment.path)
        }

        val durationLimitReached = error == VideoRecordEvent.Finalize.ERROR_DURATION_LIMIT_REACHED
        val isCurrent = segment.index == currentIndex

        // A segment that never produced data was killed before it started —
        // CameraX finalizes a pending recording when the camera is rebound
        // (image analysis start/stop, sensor or resolution change). Start the
        // same segment again instead of ending the recording.
        if (segment.startedAtEpochMs == null &&
            !stopRequested &&
            isCurrent &&
            !usable &&
            abortedStartRetries < MAX_ABORTED_START_RETRIES
        ) {
            abortedStartRetries++
            Log.w(
                CamerawesomePlugin.TAG,
                "Video segment ${segment.index} never started (${errorName(error)}); retrying"
            )
            if (startSegment(segment.index)) return
            abortedStartRetries = 0
        }

        var continueRecording = false
        val reason: String
        if (stopRequested) {
            reason = REASON_STOPPED
        } else if (!isCurrent || segment.rolloverRequested) {
            // A newer segment already took over.
            reason = if (durationLimitReached) REASON_DURATION_LIMIT else REASON_ROLLOVER
        } else if (durationLimitReached && !ending) {
            // Status-driven rollover was missed: continue from here.
            reason = REASON_DURATION_LIMIT
            continueRecording = true
        } else {
            // The recording ended without being asked to.
            ending = true
            reason = if (usable) REASON_INTERRUPTED else REASON_ERROR
        }
        if (continueRecording && !startSegment(segment.index + 1)) {
            ending = true
        }

        emitSegment(
            segment = segment,
            usable = usable,
            durationMs = TimeUnit.NANOSECONDS.toMillis(event.recordingStats.recordedDurationNanos),
            reason = reason,
            error = if (error == VideoRecordEvent.Finalize.ERROR_NONE || durationLimitReached) {
                null
            } else {
                "${errorName(error)}${event.cause?.message?.let { ": $it" } ?: ""}"
            },
        )
    }

    /**
     * Emits one segment event. The event is final when no other segment is
     * still open and no further segment will be started.
     */
    private fun emitSegment(
        segment: Segment,
        usable: Boolean,
        durationMs: Long,
        reason: String,
        error: String?,
    ) {
        val isFinal = !ended && ending && finalizedCount == startedCount
        emitter.emit(
            mapOf(
                "type" to "segment",
                "recordingId" to basePath,
                "sensorIndex" to 0,
                "index" to segment.index,
                "path" to segment.path,
                "startedAtEpochMs" to (segment.startedAtEpochMs ?: System.currentTimeMillis()),
                "durationMs" to durationMs,
                "bytes" to if (usable) File(segment.path).length() else 0L,
                "usable" to usable,
                "isFinal" to isFinal,
                "reason" to reason,
                "error" to error,
            )
        )
        if (isFinal) {
            finish()
        }
    }

    private fun finish() {
        if (ended) return
        ended = true
        mainHandler.removeCallbacks(stopWatchdog)
        val callbacks = stopCallbacks.toList()
        stopCallbacks.clear()
        for (callback in callbacks) {
            callback(anyUsable)
        }
    }

    private fun onStopTimeout() {
        if (ended) return
        Log.w(
            CamerawesomePlugin.TAG,
            "Segmented recording did not finalize within ${STOP_TIMEOUT_MS}ms",
        )
        for (segment in openSegments.values) {
            segment.recording?.close()
        }
        // Report the missing final event so listeners can complete. A late
        // finalize is still emitted, with isFinal=false.
        emitter.emit(
            mapOf(
                "type" to "segment",
                "recordingId" to basePath,
                "sensorIndex" to 0,
                "index" to currentIndex,
                "path" to pathFor(currentIndex),
                "startedAtEpochMs" to System.currentTimeMillis(),
                "durationMs" to 0L,
                "bytes" to 0L,
                "usable" to false,
                "isFinal" to true,
                "reason" to REASON_ERROR,
                "error" to "stop timeout",
            )
        )
        finish()
    }

    private fun deleteQuietly(path: String) {
        try {
            File(path).delete()
        } catch (e: Exception) {
            Log.w(CamerawesomePlugin.TAG, "Could not delete $path", e)
        }
    }

    private fun errorName(error: Int): String = when (error) {
        VideoRecordEvent.Finalize.ERROR_UNKNOWN -> "ERROR_UNKNOWN"
        VideoRecordEvent.Finalize.ERROR_FILE_SIZE_LIMIT_REACHED -> "ERROR_FILE_SIZE_LIMIT_REACHED"
        VideoRecordEvent.Finalize.ERROR_INSUFFICIENT_STORAGE -> "ERROR_INSUFFICIENT_STORAGE"
        VideoRecordEvent.Finalize.ERROR_SOURCE_INACTIVE -> "ERROR_SOURCE_INACTIVE"
        VideoRecordEvent.Finalize.ERROR_INVALID_OUTPUT_OPTIONS -> "ERROR_INVALID_OUTPUT_OPTIONS"
        VideoRecordEvent.Finalize.ERROR_ENCODING_FAILED -> "ERROR_ENCODING_FAILED"
        VideoRecordEvent.Finalize.ERROR_RECORDER_ERROR -> "ERROR_RECORDER_ERROR"
        VideoRecordEvent.Finalize.ERROR_NO_VALID_DATA -> "ERROR_NO_VALID_DATA"
        VideoRecordEvent.Finalize.ERROR_DURATION_LIMIT_REACHED -> "ERROR_DURATION_LIMIT_REACHED"
        VideoRecordEvent.Finalize.ERROR_RECORDING_GARBAGE_COLLECTED -> "ERROR_RECORDING_GARBAGE_COLLECTED"
        else -> "ERROR_$error"
    }

    companion object {
        /** Shortest accepted segment duration. */
        const val MIN_SEGMENT_DURATION_MS = 5_000L

        private const val DURATION_LIMIT_MARGIN_MS = 2_000L
        private const val STOP_TIMEOUT_MS = 6_000L
        private const val MAX_ABORTED_START_RETRIES = 3

        private const val REASON_ROLLOVER = "rollover"
        private const val REASON_STOPPED = "stopped"
        private const val REASON_DURATION_LIMIT = "durationLimit"
        private const val REASON_INTERRUPTED = "interrupted"
        private const val REASON_ERROR = "error"

        /** Finalize errors after which CameraX still leaves a playable file. */
        private val USABLE_ERRORS = setOf(
            VideoRecordEvent.Finalize.ERROR_NONE,
            VideoRecordEvent.Finalize.ERROR_FILE_SIZE_LIMIT_REACHED,
            VideoRecordEvent.Finalize.ERROR_INSUFFICIENT_STORAGE,
            VideoRecordEvent.Finalize.ERROR_SOURCE_INACTIVE,
            VideoRecordEvent.Finalize.ERROR_DURATION_LIMIT_REACHED,
        )
    }
}
