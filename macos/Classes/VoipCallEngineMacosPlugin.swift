import Cocoa
import CoreAudio
import FlutterMacOS

public final class VoipCallEngineMacosPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel?
    private var activeRoute: String = "speaker"
    private var isAudioSessionActive: Bool = false
    private var isMuted: Bool = false
    private var sequenceCounter: Int = 0

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "dev.flutter.telecom/voip_call_engine",
            binaryMessenger: registrar.messenger
        )
        let instance = VoipCallEngineMacosPlugin()
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {
        case "initializeAndDrainColdStartBuffer":
            result([[String: Any]]())

        case "reportIncomingCall":
            emitEvent([
                "type": "incomingReceived",
                "reportedViaPushKit": false,
                "request": args
            ])
            result(nil)

        case "startOutgoingCall":
            let callId = (args["callId"] as? String) ?? ""
            isAudioSessionActive = true
            emitEvent([
                "type": "outgoingStarted",
                "callId": callId,
                "request": args
            ])
            emitEvent([
                "type": "audioSessionActivationChanged",
                "isActive": true
            ])
            result(nil)

        case "answerCall":
            let callId = (args["callId"] as? String) ?? ""
            isAudioSessionActive = true
            emitEvent([
                "type": "answered",
                "callId": callId,
                "source": "appUi"
            ])
            emitEvent([
                "type": "audioSessionActivationChanged",
                "isActive": true
            ])
            result(nil)

        case "endCall":
            let callId = (args["callId"] as? String) ?? ""
            let reason = (args["reason"] as? String) ?? "localHangup"
            isAudioSessionActive = false
            emitEvent([
                "type": "ended",
                "callId": callId,
                "reason": reason,
                "source": "appUi"
            ])
            result(nil)

        case "setHold":
            let callId = (args["callId"] as? String) ?? ""
            let isOnHold = (args["isOnHold"] as? Bool) ?? false
            emitEvent([
                "type": "heldChanged",
                "callId": callId,
                "isOnHold": isOnHold,
                "heldBySystem": false,
                "source": "appUi"
            ])
            result(nil)

        case "setMuted":
            let callId = (args["callId"] as? String) ?? ""
            isMuted = (args["isMuted"] as? Bool) ?? false
            emitEvent([
                "type": "mutedChanged",
                "callId": callId,
                "isMuted": isMuted,
                "source": "appUi"
            ])
            result(nil)

        case "sendDtmf":
            let callId = (args["callId"] as? String) ?? ""
            let digits = (args["digits"] as? String) ?? ""
            emitEvent([
                "type": "dtmfReceived",
                "callId": callId,
                "digits": digits
            ])
            result(nil)

        case "reportCallConnected":
            isAudioSessionActive = true
            emitEvent([
                "type": "audioSessionActivationChanged",
                "isActive": true
            ])
            result(nil)

        case "getAudioRouteState":
            result(queryCoreAudioRouteState())

        case "setAudioRoute":
            activeRoute = (args["route"] as? String) ?? "speaker"
            if let deviceIdStr = args["deviceId"] as? String,
               let deviceId = AudioDeviceID(deviceIdStr) {
                setDefaultOutputDevice(deviceId)
            }
            emitEvent([
                "type": "audioRouteChanged",
                "reason": "manualOverride",
                "routeState": queryCoreAudioRouteState()
            ])
            result(nil)

        case "getVoipPushToken":
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func emitEvent(_ payload: [String: Any]) {
        sequenceCounter += 1
        var enriched = payload
        enriched["sequenceNumber"] = sequenceCounter
        enriched["timestampMs"] = Int64(Date().timeIntervalSince1970 * 1000)
        channel?.invokeMethod("onNativeCallEvent", arguments: enriched)
    }

    private func queryCoreAudioRouteState() -> [String: Any] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var devicesList: [[String: Any]] = []

        if AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        ) == noErr {
            let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
            var deviceIds = [AudioDeviceID](repeating: 0, count: deviceCount)
            if AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                0,
                nil,
                &dataSize,
                &deviceIds
            ) == noErr {
                for id in deviceIds {
                    var name: CFString = "macOS Audio Device" as CFString
                    var nameSize = UInt32(MemoryLayout<CFString>.size)
                    var nameAddress = AudioObjectPropertyAddress(
                        mSelector: kAudioObjectPropertyName,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name)
                    devicesList.append([
                        "id": String(id),
                        "name": name as String,
                        "route": activeRoute,
                        "isDefault": false,
                        "isInput": false
                    ])
                }
            }
        }

        return [
            "activeRoute": activeRoute,
            "availableRoutes": ["speaker", "wiredHeadset", "bluetooth", "systemDefault"],
            "availableDevices": devicesList,
            "isAudioSessionActive": isAudioSessionActive,
            "isMicrophoneMuted": isMuted
        ]
    }

    private func setDefaultOutputDevice(_ deviceId: AudioDeviceID) {
        var id = deviceId
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id
        )
    }
}
