package dev.flutter.telecom.voip_call_engine_android

import android.os.Handler
import android.os.Looper
import java.util.ArrayDeque

/**
 * Thread-safe bounded ring buffer that stores native Telecom and AudioManager events
 * while the Flutter Engine is terminated or warming up on a cold-start FCM wake.
 */
object NativeEventRingBuffer {
    private const val MAX_CAPACITY = 128
    private val lock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val buffer = ArrayDeque<Map<String, Any?>>(MAX_CAPACITY)
    private var sequenceCounter: Int = 0
    private var isDartHandshakeComplete: Boolean = false
    private var liveDispatcher: ((Map<String, Any?>) -> Unit)? = null

    fun setLiveDispatcher(dispatcher: ((Map<String, Any?>) -> Unit)?) {
        synchronized(lock) {
            liveDispatcher = dispatcher
        }
    }

    fun emit(payload: Map<String, Any?>) {
        val enriched: MutableMap<String, Any?>
        val ready: Boolean
        val dispatcher: ((Map<String, Any?>) -> Unit)?

        synchronized(lock) {
            sequenceCounter += 1
            enriched = payload.toMutableMap()
            enriched["sequenceNumber"] = sequenceCounter
            if (!enriched.containsKey("timestampMs")) {
                enriched["timestampMs"] = System.currentTimeMillis()
            }

            ready = isDartHandshakeComplete
            dispatcher = liveDispatcher

            if (!ready) {
                if (buffer.size >= MAX_CAPACITY) {
                    buffer.removeFirst()
                }
                enriched["fromColdStartBuffer"] = true
                buffer.addLast(enriched)
                return
            }
        }

        if (dispatcher != null) {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                dispatcher(enriched)
            } else {
                mainHandler.post { dispatcher(enriched) }
            }
        }
    }

    fun markReadyAndDrain(): List<Map<String, Any?>> {
        synchronized(lock) {
            isDartHandshakeComplete = true
            val drained = ArrayList<Map<String, Any?>>(buffer)
            buffer.clear()
            return drained
        }
    }
}
