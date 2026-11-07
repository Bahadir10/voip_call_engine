import AVFoundation
import Foundation

/// Coordinates `AVAudioSession` configuration, CallKit audio activation barriers,
/// and dynamic audio route switching (Earpiece, Speaker, Bluetooth HFP/BLE, Wired Headset, CarPlay).
public final class AudioSessionCoordinator {
    private let eventBuffer: NativeEventRingBuffer
    private var isAudioSessionActivatedByCallKit: Bool = false
    private var isMicrophoneMuted: Bool = false

    public init(eventBuffer: NativeEventRingBuffer) {
        self.eventBuffer = eventBuffer
        registerNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func registerNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    /// Pre-configures `AVAudioSession` for voice chat BEFORE CallKit activates the session.
    ///
    /// Note: Never call `setActive(true)` directly during a CallKit call; CallKit manages
    /// activation and notifies via `provider(_:didActivate:)`.
    public func configureVoiceChatCategory() {
        let session = AVAudioSession.sharedInstance()
        do {
            let options: AVAudioSession.CategoryOptions = [
                .allowBluetooth,
                .allowBluetoothA2DP
            ]
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            try session.setPreferredIOBufferDuration(0.01) // 10ms low-latency VoIP buffer
            try session.setPreferredSampleRate(48000.0)
        } catch {
            eventBuffer.emit([
                "type": "diagnostic",
                "code": "IOS_AUDIO_CATEGORY_ERROR",
                "message": "Failed to configure AVAudioSession category: \(error.localizedDescription)"
            ])
        }
    }

    /// Invoked directly from `CXProviderDelegate.provider(_:didActivate:)`.
    public func onCallKitDidActivateAudioSession(_ audioSession: AVAudioSession) {
        isAudioSessionActivatedByCallKit = true
        eventBuffer.emit([
            "type": "audioSessionActivationChanged",
            "isActive": true
        ])
        emitCurrentRouteState(reason: "callKitDidActivate")
    }

    /// Invoked directly from `CXProviderDelegate.provider(_:didDeactivate:)`.
    public func onCallKitDidDeactivateAudioSession(_ audioSession: AVAudioSession) {
        isAudioSessionActivatedByCallKit = false
        eventBuffer.emit([
            "type": "audioSessionActivationChanged",
            "isActive": false
        ])
    }

    /// Switches the active voice route on iOS.
    public func setAudioRoute(route: String, deviceId: String?) throws {
        let session = AVAudioSession.sharedInstance()
        switch route {
        case "speaker":
            try session.overrideOutputAudioPort(.speaker)
        case "earpiece":
            try session.overrideOutputAudioPort(.none)
            if let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try session.setPreferredInput(builtInMic)
            }
        case "bluetooth":
            try session.overrideOutputAudioPort(.none)
            if let btInput = session.availableInputs?.first(where: {
                if let id = deviceId, $0.uid == id { return true }
                return $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
            }) {
                try session.setPreferredInput(btInput)
            }
        case "wiredHeadset":
            try session.overrideOutputAudioPort(.none)
            if let wiredInput = session.availableInputs?.first(where: {
                $0.portType == .headsetMic || $0.portType == .usbAudio
            }) {
                try session.setPreferredInput(wiredInput)
            }
        default:
            try session.overrideOutputAudioPort(.none)
        }
        emitCurrentRouteState(reason: "manualOverride")
    }

    public func setMicrophoneMuted(_ muted: Bool) {
        isMicrophoneMuted = muted
    }

    /// Serializes the current `AVAudioSession` route state into a dictionary matching `AudioRouteState`.
    public func getAudioRouteStateDictionary() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        let currentOutput = session.currentRoute.outputs.first
        let activeRoute = mapPortToRouteName(currentOutput?.portType)

        var availableRoutesSet = Set<String>(["earpiece", "speaker"])
        var devicesList: [[String: Any]] = []

        if let inputs = session.availableInputs {
            for input in inputs {
                let routeName = mapPortToRouteName(input.portType)
                availableRoutesSet.insert(routeName)
                devicesList.append([
                    "id": input.uid,
                    "name": input.portName,
                    "route": routeName,
                    "isDefault": input.portType == .builtInMic,
                    "isInput": true
                ])
            }
        }

        for output in session.currentRoute.outputs {
            let routeName = mapPortToRouteName(output.portType)
            availableRoutesSet.insert(routeName)
            devicesList.append([
                "id": output.uid,
                "name": output.portName,
                "route": routeName,
                "isDefault": true,
                "isInput": false
            ])
        }

        let activeDeviceMap: [String: Any]? = currentOutput.map {
            [
                "id": $0.uid,
                "name": $0.portName,
                "route": activeRoute,
                "isDefault": true,
                "isInput": false
            ]
        }

        return [
            "activeRoute": activeRoute,
            "availableRoutes": Array(availableRoutesSet),
            "activeDevice": activeDeviceMap as Any,
            "availableDevices": devicesList,
            "isAudioSessionActive": isAudioSessionActivatedByCallKit,
            "isMicrophoneMuted": isMicrophoneMuted
        ]
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        var reasonString = "routeConfigurationChange"
        if let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
           let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) {
            switch reason {
            case .newDeviceAvailable:
                reasonString = "newDeviceAvailable"
            case .oldDeviceUnavailable:
                reasonString = "oldDeviceUnavailable"
            case .override:
                reasonString = "override"
            case .categoryChange:
                reasonString = "categoryChange"
            default:
                reasonString = "other(\(reasonValue))"
            }
        }
        emitCurrentRouteState(reason: reasonString)
    }

    private func emitCurrentRouteState(reason: String) {
        eventBuffer.emit([
            "type": "audioRouteChanged",
            "reason": reason,
            "routeState": getAudioRouteStateDictionary()
        ])
    }

    private func mapPortToRouteName(_ portType: AVAudioSession.Port?) -> String {
        guard let portType = portType else { return "earpiece" }
        switch portType {
        case .builtInSpeaker:
            return "speaker"
        case .builtInReceiver, .builtInMic:
            return "earpiece"
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
            return "bluetooth"
        case .headphones, .headsetMic, .usbAudio:
            return "wiredHeadset"
        case .carAudio:
            return "carAudio"
        default:
            return "systemDefault"
        }
    }
}
