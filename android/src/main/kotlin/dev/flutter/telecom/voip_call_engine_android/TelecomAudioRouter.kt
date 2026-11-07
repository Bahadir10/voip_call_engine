package dev.flutter.telecom.voip_call_engine_android

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper

/**
 * Manages voice communication audio routing across Android versions:
 * - API 31+ (Android 12+): `AudioManager.setCommunicationDevice` & `availableCommunicationDevices`
 * - API 26..30: `startBluetoothSco`, `isSpeakerphoneOn`, and `AudioDeviceInfo` enumeration
 */
class TelecomAudioRouter(private val context: Context) {
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private var isAudioSessionActive = false

    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
            emitRouteChanged("deviceAdded")
        }

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
            emitRouteChanged("deviceRemoved")
        }
    }

    init {
        audioManager.registerAudioDeviceCallback(deviceCallback, mainHandler)
    }

    fun dispose() {
        audioManager.unregisterAudioDeviceCallback(deviceCallback)
    }

    fun activateVoiceCommunicationSession() {
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        isAudioSessionActive = true
        NativeEventRingBuffer.emit(
            mapOf(
                "type" to "audioSessionActivationChanged",
                "isActive" to true
            )
        )
        emitRouteChanged("voiceSessionActivated")
    }

    fun deactivateVoiceCommunicationSession() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audioManager.clearCommunicationDevice()
        } else {
            @Suppress("DEPRECATION")
            audioManager.stopBluetoothSco()
            @Suppress("DEPRECATION")
            audioManager.isBluetoothScoOn = false
            @Suppress("DEPRECATION")
            audioManager.isSpeakerphoneOn = false
        }
        audioManager.mode = AudioManager.MODE_NORMAL
        isAudioSessionActive = false
        NativeEventRingBuffer.emit(
            mapOf(
                "type" to "audioSessionActivationChanged",
                "isActive" to false
            )
        )
    }

    fun setMuted(muted: Boolean) {
        audioManager.isMicrophoneMute = muted
        emitRouteChanged("muteChanged")
    }

    fun setAudioRoute(route: String, deviceId: String?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val devices = audioManager.availableCommunicationDevices
            val targetDevice = devices.firstOrNull { device ->
                if (deviceId != null && device.id.toString() == deviceId) {
                    true
                } else {
                    mapDeviceTypeToRouteName(device.type) == route
                }
            }
            if (targetDevice != null) {
                audioManager.setCommunicationDevice(targetDevice)
            }
        } else {
            @Suppress("DEPRECATION")
            when (route) {
                "speaker" -> {
                    audioManager.stopBluetoothSco()
                    audioManager.isBluetoothScoOn = false
                    audioManager.isSpeakerphoneOn = true
                }
                "bluetooth" -> {
                    audioManager.isSpeakerphoneOn = false
                    audioManager.startBluetoothSco()
                    audioManager.isBluetoothScoOn = true
                }
                else -> {
                    audioManager.stopBluetoothSco()
                    audioManager.isBluetoothScoOn = false
                    audioManager.isSpeakerphoneOn = false
                }
            }
        }
        emitRouteChanged("manualRouteSwitch")
    }

    fun getAudioRouteStateMap(): Map<String, Any?> {
        val availableRoutes = linkedSetOf("earpiece", "speaker")
        val devicesList = mutableListOf<Map<String, Any?>>()
        var activeRoute = "earpiece"
        var activeDeviceMap: Map<String, Any?>? = null

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val commDevices = audioManager.availableCommunicationDevices
            val currentCommDevice = audioManager.communicationDevice
            if (currentCommDevice != null) {
                activeRoute = mapDeviceTypeToRouteName(currentCommDevice.type)
                activeDeviceMap = mapOf(
                    "id" to currentCommDevice.id.toString(),
                    "name" to currentCommDevice.productName.toString(),
                    "route" to activeRoute,
                    "isDefault" to true,
                    "isInput" to false
                )
            }
            for (device in commDevices) {
                val routeName = mapDeviceTypeToRouteName(device.type)
                availableRoutes.add(routeName)
                devicesList.add(
                    mapOf(
                        "id" to device.id.toString(),
                        "name" to device.productName.toString(),
                        "route" to routeName,
                        "isDefault" to (device.id == currentCommDevice?.id),
                        "isInput" to device.isSource
                    )
                )
            }
        } else {
            val outputs = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            for (device in outputs) {
                val routeName = mapDeviceTypeToRouteName(device.type)
                availableRoutes.add(routeName)
                devicesList.add(
                    mapOf(
                        "id" to device.id.toString(),
                        "name" to device.productName.toString(),
                        "route" to routeName,
                        "isDefault" to false,
                        "isInput" to false
                    )
                )
            }
            @Suppress("DEPRECATION")
            activeRoute = when {
                audioManager.isBluetoothScoOn -> "bluetooth"
                audioManager.isSpeakerphoneOn -> "speaker"
                else -> "earpiece"
            }
        }

        return mapOf(
            "activeRoute" to activeRoute,
            "availableRoutes" to availableRoutes.toList(),
            "activeDevice" to activeDeviceMap,
            "availableDevices" to devicesList,
            "isAudioSessionActive" to isAudioSessionActive,
            "isMicrophoneMuted" to audioManager.isMicrophoneMute
        )
    }

    private fun emitRouteChanged(reason: String) {
        NativeEventRingBuffer.emit(
            mapOf(
                "type" to "audioRouteChanged",
                "reason" to reason,
                "routeState" to getAudioRouteStateMap()
            )
        )
    }

    private fun mapDeviceTypeToRouteName(type: Int): String {
        return when (type) {
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE -> "speaker"

            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"

            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_BLE_SPEAKER,
            AudioDeviceInfo.TYPE_HEARING_AID -> "bluetooth"

            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_USB_DEVICE -> "wiredHeadset"

            else -> "systemDefault"
        }
    }
}
