import Foundation
import PushKit

/// Coordinates `PKPushRegistry` registration and guarantees zero-crash iOS 13+ VoIP push handling
/// by reporting the incoming call to `CallKitCoordinator` synchronously before the PushKit
/// completion handler returns.
public final class PushKitCoordinator: NSObject, PKPushRegistryDelegate {
    private let eventBuffer: NativeEventRingBuffer
    private let callKitCoordinator: CallKitCoordinator
    private var voipRegistry: PKPushRegistry?
    public private(set) var currentVoipTokenHex: String?

    public init(
        eventBuffer: NativeEventRingBuffer,
        callKitCoordinator: CallKitCoordinator
    ) {
        self.eventBuffer = eventBuffer
        self.callKitCoordinator = callKitCoordinator
        super.init()
    }

    public func registerForVoipPushes() {
        if voipRegistry != nil { return }
        let registry = PKPushRegistry(queue: DispatchQueue.main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.voipRegistry = registry
    }

    // MARK: - PKPushRegistryDelegate

    public func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }
        let tokenHex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        self.currentVoipTokenHex = tokenHex

        #if DEBUG
        let env = "sandbox"
        #else
        let env = "production"
        #endif

        eventBuffer.emit([
            "type": "voipPushTokenUpdated",
            "token": tokenHex,
            "environment": env
        ])
    }

    public func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        guard type == .voIP else { return }
        self.currentVoipTokenHex = nil
        eventBuffer.emit([
            "type": "voipPushTokenUpdated",
            "token": "",
            "environment": "invalidated"
        ])
    }

    public func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }

        let dict = payload.dictionaryPayload
        let customData = (dict["voip"] as? [String: Any]) ?? (dict as? [String: Any]) ?? [:]

        let callId = (customData["callId"] as? String) ?? UUID().uuidString.lowercased()
        let callerName = (customData["callerName"] as? String) ?? "Incoming Call"
        let handleValue = (customData["handleValue"] as? String) ?? callerName
        let handleType = (customData["handleType"] as? String) ?? "generic"
        let hasVideo = (customData["hasVideo"] as? Bool) ?? false
        let isGhostCancel = (customData["action"] as? String) == "cancel" ||
                            (customData["isCancelled"] as? Bool) == true

        let requestMap: [String: Any] = [
            "callId": callId,
            "callerName": callerName,
            "hasVideo": hasVideo,
            "handle": [
                "type": handleType,
                "value": handleValue
            ],
            "capabilities": [
                "supportsHold": true,
                "supportsMute": true,
                "supportsDtmf": true,
                "supportsGrouping": false,
                "supportsVideo": hasVideo
            ]
        ]

        // CRITICAL: Must invoke reportNewIncomingCall synchronously inside this callback!
        callKitCoordinator.reportIncomingCallSynchronously(
            requestMap: requestMap,
            reportedViaPushKit: true,
            isGhostCancelCall: isGhostCancel
        ) { _ in
            completion()
        }
    }
}
