import Foundation

/// Thread-safe FIFO ring buffer that stores native PushKit, CallKit, and AVAudioSession
/// events when the Flutter Engine is terminated or still warming up.
///
/// Once the Dart side invokes `initializeAndDrainColdStartBuffer`, all buffered events
/// are returned in strict chronological order and live streaming is activated.
public final class NativeEventRingBuffer {
    private let lock = NSLock()
    private let capacity: Int
    private var buffer: [[String: Any]] = []
    private var sequenceCounter: Int = 0
    private var isDartHandshakeComplete: Bool = false
    private var liveDispatcher: (([String: Any]) -> Void)?

    public init(capacity: Int = 128) {
        self.capacity = max(16, capacity)
    }

    /// Configures the live dispatcher callback used once Dart has completed initialization.
    public func setLiveDispatcher(_ dispatcher: @escaping ([String: Any]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.liveDispatcher = dispatcher
    }

    /// Enqueues a native event or dispatches it immediately on the main thread if Dart is ready.
    public func emit(_ payload: [String: Any]) {
        lock.lock()
        sequenceCounter += 1
        var enriched = payload
        enriched["sequenceNumber"] = sequenceCounter
        if enriched["timestampMs"] == nil {
            enriched["timestampMs"] = Int64(Date().timeIntervalSince1970 * 1000)
        }

        let ready = isDartHandshakeComplete
        let dispatcher = liveDispatcher

        if !ready {
            if buffer.count >= capacity {
                buffer.removeFirst()
            }
            enriched["fromColdStartBuffer"] = true
            buffer.append(enriched)
            lock.unlock()
            return
        }
        lock.unlock()

        if let dispatcher = dispatcher {
            if Thread.isMainThread {
                dispatcher(enriched)
            } else {
                DispatchQueue.main.async {
                    dispatcher(enriched)
                }
            }
        }
    }

    /// Marks the Dart isolate as ready and atomically drains all buffered cold-start events.
    public func markReadyAndDrain() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        isDartHandshakeComplete = true
        let drained = buffer
        buffer.removeAll(keepingCapacity: true)
        return drained
    }
}
