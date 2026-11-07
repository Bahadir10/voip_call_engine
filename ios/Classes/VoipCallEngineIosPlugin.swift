import Flutter
import UIKit

public final class VoipCallEngineIosPlugin: NSObject, FlutterPlugin {
    /// Shared singleton so PushKit registration occurs immediately when the app process starts,
    /// even before the Flutter Engine finishes warming up on a cold VoIP push wake.
    public static let shared = VoipCallEngineIosPlugin()

    private let eventBuffer = NativeEventRingBuffer(capacity: 128)
    private let audioCoordinator: AudioSessionCoordinator
    private let callKitCoordinator: CallKitCoordinator
    private let pushKitCoordinator: PushKitCoordinator
    private var methodChannel: FlutterMethodChannel?

    private override init() {
        let audio = AudioSessionCoordinator(eventBuffer: eventBuffer)
        let callKit = CallKitCoordinator(eventBuffer: eventBuffer, audioCoordinator: audio)
        let pushKit = PushKitCoordinator(eventBuffer: eventBuffer, callKitCoordinator: callKit)
        self.audioCoordinator = audio
        self.callKitCoordinator = callKit
        self.pushKitCoordinator = pushKit
        super.init()
        pushKit.registerForVoipPushes()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "dev.flutter.telecom/voip_call_engine",
            binaryMessenger: registrar.messenger()
        )
        let instance = VoipCallEngineIosPlugin.shared
        instance.attachChannel(channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    private func attachChannel(_ channel: FlutterMethodChannel) {
        self.methodChannel = channel
        eventBuffer.setLiveDispatcher { [weak self] eventMap in
            self?.methodChannel?.invokeMethod("onNativeCallEvent", arguments: eventMap)
        }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {
        case "initializeAndDrainColdStartBuffer":
            if let iosConfig = args["ios"] as? [String: Any] {
                callKitCoordinator.configureProvider(from: iosConfig)
                if (iosConfig["enablePushKit"] as? Bool) ?? true {
                    pushKitCoordinator.registerForVoipPushes()
                }
            }
            let bufferedEvents = eventBuffer.markReadyAndDrain()
            result(bufferedEvents)

        case "reportIncomingCall":
            callKitCoordinator.reportIncomingCallSynchronously(
                requestMap: args,
                reportedViaPushKit: false
            ) { error in
                if let error = error {
                    result(FlutterError(
                        code: "REPORT_INCOMING_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
                } else {
                    result(nil)
                }
            }

        case "startOutgoingCall":
            callKitCoordinator.startOutgoingCall(requestMap: args) { error in
                if let error = error {
                    result(FlutterError(
                        code: "START_OUTGOING_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
                } else {
                    result(nil)
                }
            }

        case "answerCall":
            let callId = (args["callId"] as? String) ?? ""
            callKitCoordinator.answerCall(callId: callId) { error in
                if let error = error {
                    result(FlutterError(code: "ANSWER_FAILED", message: error.localizedDescription, details: nil))
                } else {
                    result(nil)
                }
            }

        case "endCall":
            let callId = (args["callId"] as? String) ?? ""
            let reason = (args["reason"] as? String) ?? "localHangup"
            callKitCoordinator.endCall(callId: callId, reason: reason) { error in
                if let error = error {
                    result(FlutterError(code: "END_CALL_FAILED", message: error.localizedDescription, details: nil))
                } else {
                    result(nil)
                }
            }

        case "setHold":
            let callId = (args["callId"] as? String) ?? ""
            let isOnHold = (args["isOnHold"] as? Bool) ?? false
            callKitCoordinator.setHold(callId: callId, isOnHold: isOnHold) { error in
                if let error = error {
                    result(FlutterError(code: "HOLD_FAILED", message: error.localizedDescription, details: nil))
                } else {
                    result(nil)
                }
            }

        case "setMuted":
            let callId = (args["callId"] as? String) ?? ""
            let isMuted = (args["isMuted"] as? Bool) ?? false
            callKitCoordinator.setMuted(callId: callId, isMuted: isMuted) { error in
                if let error = error {
                    result(FlutterError(code: "MUTE_FAILED", message: error.localizedDescription, details: nil))
                } else {
                    result(nil)
                }
            }

        case "sendDtmf":
            let callId = (args["callId"] as? String) ?? ""
            let digits = (args["digits"] as? String) ?? ""
            callKitCoordinator.sendDtmf(callId: callId, digits: digits) { error in
                if let error = error {
                    result(FlutterError(code: "DTMF_FAILED", message: error.localizedDescription, details: nil))
                } else {
                    result(nil)
                }
            }

        case "reportCallConnected":
            let callId = (args["callId"] as? String) ?? ""
            callKitCoordinator.reportCallConnected(callId: callId)
            result(nil)

        case "getAudioRouteState":
            result(audioCoordinator.getAudioRouteStateDictionary())

        case "setAudioRoute":
            let route = (args["route"] as? String) ?? "earpiece"
            let deviceId = args["deviceId"] as? String
            do {
                try audioCoordinator.setAudioRoute(route: route, deviceId: deviceId)
                result(nil)
            } catch {
                result(FlutterError(
                    code: "AUDIO_ROUTE_FAILED",
                    message: error.localizedDescription,
                    details: nil
                ))
            }

        case "getVoipPushToken":
            result(pushKitCoordinator.currentVoipTokenHex)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
