package dev.flutter.telecom.voip_call_engine_android

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class VoipCallEngineAndroidPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var applicationContext: Context
    private var audioRouter: TelecomAudioRouter? = null
    private var phoneAccountHandle: PhoneAccountHandle? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "dev.flutter.telecom/voip_call_engine")
        channel.setMethodCallHandler(this)

        val router = TelecomAudioRouter(applicationContext)
        audioRouter = router
        VoipConnectionService.audioRouter = router

        NativeEventRingBuffer.setLiveDispatcher { eventMap ->
            channel.invokeMethod("onNativeCallEvent", eventMap)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        NativeEventRingBuffer.setLiveDispatcher(null)
        audioRouter?.dispose()
        audioRouter = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        @Suppress("UNCHECKED_CAST")
        val args = (call.arguments as? Map<String, Any?>) ?: emptyMap()

        when (call.method) {
            "initializeAndDrainColdStartBuffer" -> {
                @Suppress("UNCHECKED_CAST")
                val androidConfig = (args["android"] as? Map<String, Any?>) ?: emptyMap()
                val label = (androidConfig["phoneAccountLabel"] as? String) ?: "VoIP Call Service"
                registerSelfManagedPhoneAccount(label)
                val drained = NativeEventRingBuffer.markReadyAndDrain()
                result.success(drained)
            }

            "reportIncomingCall" -> {
                val callId = (args["callId"] as? String) ?: ""
                val callerName = (args["callerName"] as? String) ?: "Incoming Call"
                @Suppress("UNCHECKED_CAST")
                val handleMap = (args["handle"] as? Map<String, Any?>) ?: emptyMap()
                val handleValue = (handleMap["value"] as? String) ?: callerName

                reportIncomingToTelecom(callId, callerName, handleValue, args)
                result.success(null)
            }

            "startOutgoingCall" -> {
                val callId = (args["callId"] as? String) ?: ""
                val callerName = (args["callerName"] as? String) ?: "Outgoing Call"
                @Suppress("UNCHECKED_CAST")
                val handleMap = (args["handle"] as? Map<String, Any?>) ?: emptyMap()
                val handleValue = (handleMap["value"] as? String) ?: callerName

                startOutgoingInTelecom(callId, callerName, handleValue, args)
                result.success(null)
            }

            "answerCall" -> {
                val callId = (args["callId"] as? String) ?: ""
                val connection = VoipConnectionService.activeConnections[callId]
                if (connection != null) {
                    connection.onAnswer(0)
                } else {
                    audioRouter?.activateVoiceCommunicationSession()
                    NativeEventRingBuffer.emit(
                        mapOf(
                            "type" to "answered",
                            "callId" to callId,
                            "source" to "appUi"
                        )
                    )
                }
                result.success(null)
            }

            "endCall" -> {
                val callId = (args["callId"] as? String) ?: ""
                val reason = (args["reason"] as? String) ?: "localHangup"
                val connection = VoipConnectionService.activeConnections[callId]
                if (connection != null) {
                    val causeCode = when (reason) {
                        "localRejected" -> DisconnectCause.REJECTED
                        "remoteHangup", "remoteCancelled" -> DisconnectCause.REMOTE
                        "unansweredTimeout" -> DisconnectCause.MISSED
                        else -> DisconnectCause.LOCAL
                    }
                    connection.setDisconnected(DisconnectCause(causeCode))
                    connection.cleanupAndRemove()
                } else if (VoipConnectionService.activeConnections.isEmpty()) {
                    audioRouter?.deactivateVoiceCommunicationSession()
                }
                NativeEventRingBuffer.emit(
                    mapOf(
                        "type" to "ended",
                        "callId" to callId,
                        "reason" to reason,
                        "source" to "appUi"
                    )
                )
                result.success(null)
            }

            "setHold" -> {
                val callId = (args["callId"] as? String) ?: ""
                val isOnHold = (args["isOnHold"] as? Boolean) ?: false
                val connection = VoipConnectionService.activeConnections[callId]
                if (connection != null) {
                    if (isOnHold) connection.setOnHold() else connection.setActive()
                }
                NativeEventRingBuffer.emit(
                    mapOf(
                        "type" to "heldChanged",
                        "callId" to callId,
                        "isOnHold" to isOnHold,
                        "heldBySystem" to false,
                        "source" to "appUi"
                    )
                )
                result.success(null)
            }

            "setMuted" -> {
                val callId = (args["callId"] as? String) ?: ""
                val isMuted = (args["isMuted"] as? Boolean) ?: false
                audioRouter?.setMuted(isMuted)
                NativeEventRingBuffer.emit(
                    mapOf(
                        "type" to "mutedChanged",
                        "callId" to callId,
                        "isMuted" to isMuted,
                        "source" to "appUi"
                    )
                )
                result.success(null)
            }

            "sendDtmf" -> {
                val callId = (args["callId"] as? String) ?: ""
                val digits = (args["digits"] as? String) ?: ""
                NativeEventRingBuffer.emit(
                    mapOf(
                        "type" to "dtmfReceived",
                        "callId" to callId,
                        "digits" to digits
                    )
                )
                result.success(null)
            }

            "reportCallConnected" -> {
                val callId = (args["callId"] as? String) ?: ""
                VoipConnectionService.activeConnections[callId]?.setActive()
                audioRouter?.activateVoiceCommunicationSession()
                result.success(null)
            }

            "getAudioRouteState" -> {
                result.success(audioRouter?.getAudioRouteStateMap())
            }

            "setAudioRoute" -> {
                val route = (args["route"] as? String) ?: "earpiece"
                val deviceId = args["deviceId"] as? String
                audioRouter?.setAudioRoute(route, deviceId)
                result.success(null)
            }

            "getVoipPushToken" -> {
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun registerSelfManagedPhoneAccount(label: String) {
        try {
            val telecomManager = applicationContext.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            val componentName = ComponentName(applicationContext, VoipConnectionService::class.java)
            val handle = PhoneAccountHandle(componentName, "voip_call_engine_self_managed")
            val account = PhoneAccount.builder(handle, label)
                .setCapabilities(
                    PhoneAccount.CAPABILITY_SELF_MANAGED or
                        PhoneAccount.CAPABILITY_SUPPORTS_VIDEO_CALLING
                )
                .addSupportedUriScheme("sip")
                .addSupportedUriScheme(PhoneAccount.SCHEME_TEL)
                .build()
            telecomManager.registerPhoneAccount(account)
            phoneAccountHandle = handle
        } catch (e: Exception) {
            NativeEventRingBuffer.emit(
                mapOf(
                    "type" to "diagnostic",
                    "code" to "ANDROID_TELECOM_REGISTER_FALLBACK",
                    "message" to "TelecomManager registration fallback: ${e.message}"
                )
            )
        }
    }

    private fun reportIncomingToTelecom(
        callId: String,
        callerName: String,
        handleValue: String,
        requestMap: Map<String, Any?>
    ) {
        try {
            val telecomManager = applicationContext.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            val handle = phoneAccountHandle
            if (handle != null) {
                val extras = Bundle().apply {
                    putString("callId", callId)
                    putString("callerName", callerName)
                    putString("handleValue", handleValue)
                }
                telecomManager.addNewIncomingCall(handle, extras)
            }
        } catch (_: SecurityException) {
            // Fallback when MANAGE_OWN_CALLS is not granted or on restricted OEM ROMs
        }

        NativeEventRingBuffer.emit(
            mapOf(
                "type" to "incomingReceived",
                "reportedViaPushKit" to false,
                "request" to requestMap
            )
        )
    }

    private fun startOutgoingInTelecom(
        callId: String,
        callerName: String,
        handleValue: String,
        requestMap: Map<String, Any?>
    ) {
        try {
            val telecomManager = applicationContext.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            val handle = phoneAccountHandle
            if (handle != null) {
                val extras = Bundle().apply {
                    putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle)
                    putBundle(
                        TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS,
                        Bundle().apply {
                            putString("callId", callId)
                            putString("callerName", callerName)
                            putString("handleValue", handleValue)
                        }
                    )
                }
                telecomManager.placeCall(Uri.fromParts("sip", handleValue, null), extras)
            }
        } catch (_: SecurityException) {
            // Fallback when MANAGE_OWN_CALLS is not granted
        }

        audioRouter?.activateVoiceCommunicationSession()
        NativeEventRingBuffer.emit(
            mapOf(
                "type" to "outgoingStarted",
                "callId" to callId,
                "request" to requestMap
            )
        )
    }
}
