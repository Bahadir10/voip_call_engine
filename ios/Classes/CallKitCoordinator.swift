import AVFoundation
import CallKit
import Foundation

/// Manages `CXProvider` and `CXCallController` interactions for iOS CallKit.
public final class CallKitCoordinator: NSObject, CXProviderDelegate {
    private let eventBuffer: NativeEventRingBuffer
    private let audioCoordinator: AudioSessionCoordinator
    private let callController = CXCallController()
    private var provider: CXProvider?
    private var activeCallUuids = Set<UUID>()

    public init(
        eventBuffer: NativeEventRingBuffer,
        audioCoordinator: AudioSessionCoordinator
    ) {
        self.eventBuffer = eventBuffer
        self.audioCoordinator = audioCoordinator
        super.init()
        configureProvider(from: [:])
    }

    /// Configures or updates `CXProviderConfiguration` from the Dart `IosCallConfig` dictionary.
    public func configureProvider(from config: [String: Any]) {
        let appName = (config["appName"] as? String) ?? "VoIP Call"
        let cxConfig: CXProviderConfiguration
        if #available(iOS 14.0, *) {
            cxConfig = CXProviderConfiguration()
        } else {
            cxConfig = CXProviderConfiguration(localizedName: appName)
        }

        cxConfig.supportsVideo = (config["supportsVideo"] as? Bool) ?? true
        cxConfig.maximumCallGroups = (config["maximumCallGroups"] as? Int) ?? 2
        cxConfig.maximumCallsPerCallGroup = (config["maximumCallsPerCallGroup"] as? Int) ?? 1
        cxConfig.includesCallsInRecents = (config["includesCallsInRecents"] as? Bool) ?? false
        cxConfig.supportedHandleTypes = [.generic, .phoneNumber, .emailAddress]

        if let ringtone = config["ringtoneSound"] as? String, !ringtone.isEmpty {
            cxConfig.ringtoneSound = ringtone
        }

        if let provider = self.provider {
            provider.configuration = cxConfig
        } else {
            let newProvider = CXProvider(configuration: cxConfig)
            newProvider.setDelegate(self, queue: nil)
            self.provider = newProvider
        }
    }

    /// Reports a new incoming call to `CXProvider` **synchronously** within the caller's runloop.
    ///
    /// Required by iOS 13+ `PKPushRegistry` rules to avoid `0xbaadca11` fatal termination.
    public func reportIncomingCallSynchronously(
        requestMap: [String: Any],
        reportedViaPushKit: Bool,
        isGhostCancelCall: Bool = false,
        completion: ((Error?) -> Void)? = nil
    ) {
        let rawCallId = (requestMap["callId"] as? String) ?? UUID().uuidString
        let uuid = UUID(uuidString: rawCallId) ?? UUID()
        let callerName = (requestMap["callerName"] as? String) ?? "Unknown Caller"
        let hasVideo = (requestMap["hasVideo"] as? Bool) ?? false
        let handleDict = (requestMap["handle"] as? [String: Any]) ?? [:]
        let handleTypeStr = (handleDict["type"] as? String) ?? "generic"
        let handleValue = (handleDict["value"] as? String) ?? callerName
        let capabilities = (requestMap["capabilities"] as? [String: Any]) ?? [:]

        let update = CXCallUpdate()
        update.localizedCallerName = callerName
        update.hasVideo = hasVideo
        update.remoteHandle = CXHandle(
            type: mapCXHandleType(handleTypeStr),
            value: handleValue
        )
        update.supportsHolding = (capabilities["supportsHold"] as? Bool) ?? true
        update.supportsDTMF = (capabilities["supportsDtmf"] as? Bool) ?? true
        update.supportsGrouping = (capabilities["supportsGrouping"] as? Bool) ?? false
        update.supportsUngrouping = false

        audioCoordinator.configureVoiceChatCategory()

        guard let provider = self.provider else {
            completion?(NSError(domain: "VoipCallEngine", code: -1, userInfo: nil))
            return
        }

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.eventBuffer.emit([
                    "type": "diagnostic",
                    "code": "CALLKIT_INCOMING_ERROR",
                    "message": error.localizedDescription
                ])
                completion?(error)
                return
            }

            self.activeCallUuids.insert(uuid)

            // Ghost Call Mitigation: If the push indicates the call was already cancelled
            // before reaching the device, we STILL report it to CallKit first (mandatory on iOS 13+)
            // and immediately terminate it after 120ms.
            if isGhostCancelCall {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
                    self.activeCallUuids.remove(uuid)
                    self.eventBuffer.emit([
                        "type": "ended",
                        "callId": uuid.uuidString.lowercased(),
                        "reason": "remoteCancelled",
                        "source": "remoteSignaling"
                    ])
                }
                completion?(nil)
                return
            }

            var normalizedRequest = requestMap
            normalizedRequest["callId"] = uuid.uuidString.lowercased()
            self.eventBuffer.emit([
                "type": "incomingReceived",
                "reportedViaPushKit": reportedViaPushKit,
                "request": normalizedRequest
            ])
            completion?(nil)
        }
    }

    /// Starts an outgoing call transaction via `CXCallController`.
    public func startOutgoingCall(
        requestMap: [String: Any],
        completion: @escaping (Error?) -> Void
    ) {
        let rawCallId = (requestMap["callId"] as? String) ?? UUID().uuidString
        guard let uuid = UUID(uuidString: rawCallId) else {
            completion(NSError(domain: "VoipCallEngine", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Invalid UUID for CallKit: \(rawCallId)"
            ]))
            return
        }

        let callerName = (requestMap["callerName"] as? String) ?? "Unknown"
        let hasVideo = (requestMap["hasVideo"] as? Bool) ?? false
        let handleDict = (requestMap["handle"] as? [String: Any]) ?? [:]
        let handleTypeStr = (handleDict["type"] as? String) ?? "generic"
        let handleValue = (handleDict["value"] as? String) ?? callerName

        audioCoordinator.configureVoiceChatCategory()

        let handle = CXHandle(type: mapCXHandleType(handleTypeStr), value: handleValue)
        let startAction = CXStartCallAction(call: uuid, handle: handle)
        startAction.isVideo = hasVideo
        startAction.contactIdentifier = callerName

        let transaction = CXTransaction(action: startAction)
        callController.request(transaction) { [weak self] error in
            if error == nil {
                self?.activeCallUuids.insert(uuid)
                self?.provider?.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
                self?.eventBuffer.emit([
                    "type": "outgoingStarted",
                    "callId": uuid.uuidString.lowercased(),
                    "request": requestMap
                ])
            }
            completion(error)
        }
    }

    public func answerCall(callId: String, completion: @escaping (Error?) -> Void) {
        guard let uuid = UUID(uuidString: callId) else {
            completion(nil)
            return
        }
        let action = CXAnswerCallAction(call: uuid)
        callController.request(CXTransaction(action: action), completion: completion)
    }

    public func endCall(callId: String, reason: String, completion: @escaping (Error?) -> Void) {
        guard let uuid = UUID(uuidString: callId) else {
            completion(nil)
            return
        }
        if reason == "remoteHangup" || reason == "remoteCancelled" || reason == "unansweredTimeout" {
            let cxReason: CXCallEndedReason = (reason == "unansweredTimeout") ? .unanswered : .remoteEnded
            provider?.reportCall(with: uuid, endedAt: Date(), reason: cxReason)
            activeCallUuids.remove(uuid)
            eventBuffer.emit([
                "type": "ended",
                "callId": uuid.uuidString.lowercased(),
                "reason": reason,
                "source": "remoteSignaling"
            ])
            completion(nil)
            return
        }

        let action = CXEndCallAction(call: uuid)
        callController.request(CXTransaction(action: action), completion: completion)
    }

    public func setHold(callId: String, isOnHold: Bool, completion: @escaping (Error?) -> Void) {
        guard let uuid = UUID(uuidString: callId) else {
            completion(nil)
            return
        }
        let action = CXSetHeldCallAction(call: uuid, onHold: isOnHold)
        callController.request(CXTransaction(action: action), completion: completion)
    }

    public func setMuted(callId: String, isMuted: Bool, completion: @escaping (Error?) -> Void) {
        guard let uuid = UUID(uuidString: callId) else {
            completion(nil)
            return
        }
        let action = CXSetMutedCallAction(call: uuid, muted: isMuted)
        callController.request(CXTransaction(action: action), completion: completion)
    }

    public func sendDtmf(callId: String, digits: String, completion: @escaping (Error?) -> Void) {
        guard let uuid = UUID(uuidString: callId) else {
            completion(nil)
            return
        }
        let action = CXPlayDTMFCallAction(call: uuid, digits: digits, type: .singleTone)
        callController.request(CXTransaction(action: action), completion: completion)
    }

    public func reportCallConnected(callId: String) {
        guard let uuid = UUID(uuidString: callId) else { return }
        provider?.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    // MARK: - CXProviderDelegate

    public func providerDidReset(_ provider: CXProvider) {
        for uuid in activeCallUuids {
            eventBuffer.emit([
                "type": "ended",
                "callId": uuid.uuidString.lowercased(),
                "reason": "systemBlocked",
                "source": "systemInterruption"
            ])
        }
        activeCallUuids.removeAll()
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        audioCoordinator.configureVoiceChatCategory()
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        audioCoordinator.configureVoiceChatCategory()
        eventBuffer.emit([
            "type": "answered",
            "callId": action.callUUID.uuidString.lowercased(),
            "source": "systemUi"
        ])
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let callId = action.callUUID.uuidString.lowercased()
        activeCallUuids.remove(action.callUUID)
        eventBuffer.emit([
            "type": "ended",
            "callId": callId,
            "reason": "localHangup",
            "source": "systemUi"
        ])
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        eventBuffer.emit([
            "type": "heldChanged",
            "callId": action.callUUID.uuidString.lowercased(),
            "isOnHold": action.isOnHold,
            "heldBySystem": false,
            "source": "systemUi"
        ])
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        audioCoordinator.setMicrophoneMuted(action.isMuted)
        eventBuffer.emit([
            "type": "mutedChanged",
            "callId": action.callUUID.uuidString.lowercased(),
            "isMuted": action.isMuted,
            "source": "systemUi"
        ])
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        eventBuffer.emit([
            "type": "dtmfReceived",
            "callId": action.callUUID.uuidString.lowercased(),
            "digits": action.digits
        ])
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        audioCoordinator.onCallKitDidActivateAudioSession(audioSession)
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        audioCoordinator.onCallKitDidDeactivateAudioSession(audioSession)
    }

    private func mapCXHandleType(_ raw: String) -> CXHandle.HandleType {
        switch raw {
        case "phoneNumber":
            return .phoneNumber
        case "emailAddress":
            return .emailAddress
        default:
            return .generic
        }
    }
}
