package dev.flutter.telecom.voip_call_engine_android

import android.net.Uri
import android.os.Bundle
import android.telecom.CallAudioState
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import java.util.concurrent.ConcurrentHashMap

/**
 * Self-Managed Android `ConnectionService` integrating VoIP calls with the OS Telecom stack,
 * Bluetooth headset buttons, WearOS, Android Auto, and GSM cellular call hold coordination.
 */
class VoipConnectionService : ConnectionService() {

    companion object {
        val activeConnections = ConcurrentHashMap<String, VoipCallConnection>()
        var audioRouter: TelecomAudioRouter? = null
    }

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        val extras = request?.extras ?: Bundle()
        val callId = extras.getString("callId") ?: "unknown"
        val callerName = extras.getString("callerName") ?: "Incoming Call"
        val handleValue = extras.getString("handleValue") ?: callerName

        val connection = VoipCallConnection(callId)
        connection.setAddress(Uri.fromParts("sip", handleValue, null), TelecomManager.PRESENTATION_ALLOWED)
        connection.setCallerDisplayName(callerName, TelecomManager.PRESENTATION_ALLOWED)
        connection.setInitializing()
        connection.setRinging()
        activeConnections[callId] = connection
        return connection
    }

    override fun onCreateIncomingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ) {
        val callId = request?.extras?.getString("callId") ?: ""
        NativeEventRingBuffer.emit(
            mapOf(
                "type" to "ended",
                "callId" to callId,
                "reason" to "systemBlocked",
                "source" to "systemInterruption"
            )
        )
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        val extras = request?.extras ?: Bundle()
        val callId = extras.getString("callId") ?: "unknown"
        val callerName = extras.getString("callerName") ?: "Outgoing Call"
        val handleValue = extras.getString("handleValue") ?: callerName

        val connection = VoipCallConnection(callId)
        connection.setAddress(Uri.fromParts("sip", handleValue, null), TelecomManager.PRESENTATION_ALLOWED)
        connection.setCallerDisplayName(callerName, TelecomManager.PRESENTATION_ALLOWED)
        connection.setDialing()
        activeConnections[callId] = connection
        return connection
    }
}

class VoipCallConnection(val callId: String) : Connection() {
    init {
        connectionProperties = PROPERTY_SELF_MANAGED
        connectionCapabilities = CAPABILITY_HOLD or CAPABILITY_SUPPORT_HOLD or CAPABILITY_MUTE
        audioModeIsVoip = true
    }

    override fun onShowIncomingCallUi() {
        // Triggered by Android Telecom for self-managed connections to display notification/UI
        NativeEventRingBuffer.emit(
            mapOf(
                "type" to "diagnostic",
                "code" to "ANDROID_SHOW_INCOMING_UI",
                "message" to "Telecom requested incoming call UI for $callId"
            )
        )
    }

    override fun onAnswer(videoState: Int) {
        setActive()
        VoipConnectionService.audioRouter?.activateVoiceCommunicationSession()
        NativeEventRingBuffer.emit(
            mapOf(
                "type" to "answered",
                "callId" to callId,
                "source" to "systemUi"
            )
        )
    }

    override fun onReject() {
        setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
        cleanupAndRemove()
        NativeEventRingBuffer.emit(
            mapOf(
                "type" to "ended",
                "callId" to callId,
                "reason" to "localRejected",
                "source" to "systemUi"
            )
        )
    }

    override fun onDisconnect() {
        setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
        cleanupAndRemove()
        NativeEventRingBuffer.emit(
            mapOf(
                "type" to "ended",
                "callId" to callId,
                "reason" to "localHangup",
                "source" to "systemUi"
            )
        )
    }

    override fun onHold() {
        setOnHold()
        // When Android Telecom invokes onHold without an explicit app request, a GSM call
        // or higher-priority system audio stream has pre-empted the VoIP call.
        NativeEventRingBuffer.emit(
            mapOf(
                "type" to "heldChanged",
                "callId" to callId,
                "isOnHold" to true,
                "heldBySystem" to true,
                "source" to "systemInterruption"
            )
        )
    }

    override fun onUnhold() {
        setActive()
        NativeEventRingBuffer.emit(
            mapOf(
                "type" to "heldChanged",
                "callId" to callId,
                "isOnHold" to false,
                "heldBySystem" to false,
                "source" to "systemUi"
            )
        )
    }

    override fun onPlayDtmfTone(c: Char) {
        NativeEventRingBuffer.emit(
            mapOf(
                "type" to "dtmfReceived",
                "callId" to callId,
                "digits" to c.toString()
            )
        )
    }

    @Deprecated("Deprecated in API 34 in favor of CallEndpoint, retained for API 26-33 compatibility")
    override fun onCallAudioStateChanged(state: CallAudioState?) {
        if (state == null) return
        NativeEventRingBuffer.emit(
            mapOf(
                "type" to "mutedChanged",
                "callId" to callId,
                "isMuted" to state.isMuted,
                "source" to "hardwareAccessory"
            )
        )
    }

    fun cleanupAndRemove() {
        VoipConnectionService.activeConnections.remove(callId)
        if (VoipConnectionService.activeConnections.isEmpty()) {
            VoipConnectionService.audioRouter?.deactivateVoiceCommunicationSession()
        }
        destroy()
    }
}
