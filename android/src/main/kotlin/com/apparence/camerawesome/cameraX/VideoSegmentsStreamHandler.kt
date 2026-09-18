package com.apparence.camerawesome.cameraX

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Sends finished video segments to Dart on `camerawesome/video_segments`.
 *
 * Events are always delivered on the main thread, in the order they were
 * emitted. Events emitted while Dart is not listening are kept (up to
 * [MAX_PENDING_EVENTS]) and replayed when a listener subscribes, so a segment
 * finalized while the Flutter side is briefly detached is not lost.
 */
class VideoSegmentsStreamHandler : EventChannel.StreamHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private val pending = ArrayDeque<Map<String, Any?>>()

    fun emit(event: Map<String, Any?>) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            deliver(event)
        } else {
            mainHandler.post { deliver(event) }
        }
    }

    private fun deliver(event: Map<String, Any?>) {
        val currentSink = sink
        if (currentSink != null) {
            currentSink.success(event)
            return
        }
        if (pending.size >= MAX_PENDING_EVENTS) {
            pending.removeFirst()
        }
        pending.addLast(event)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        if (events == null) return
        while (pending.isNotEmpty()) {
            events.success(pending.removeFirst())
        }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    companion object {
        const val CHANNEL_NAME = "camerawesome/video_segments"
        private const val MAX_PENDING_EVENTS = 64
    }
}
