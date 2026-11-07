#include "voip_call_engine_windows_plugin.h"
#include "include/voip_call_engine_windows/voip_call_engine_windows_plugin_c_api.h"

#include <windows.h>
#include <mmdeviceapi.h>
#include <functiondiscoverykeys_devpkey.h>

#include <chrono>
#include <vector>

namespace voip_call_engine_windows {

namespace {

int64_t CurrentTimestampMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

std::string WideToUtf8(const wchar_t *wide_str) {
  if (!wide_str) return "";
  int size_needed = WideCharToMultiByte(CP_UTF8, 0, wide_str, -1, nullptr, 0, nullptr, nullptr);
  if (size_needed <= 1) return "";
  std::string result(size_needed - 1, 0);
  WideCharToMultiByte(CP_UTF8, 0, wide_str, -1, &result[0], size_needed, nullptr, nullptr);
  return result;
}

}  // namespace

void VoipCallEngineWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "dev.flutter.telecom/voip_call_engine",
      &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<VoipCallEngineWindowsPlugin>(std::move(channel));
  registrar->AddPlugin(std::move(plugin));
}

VoipCallEngineWindowsPlugin::VoipCallEngineWindowsPlugin(
    std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel)
    : channel_(std::move(channel)) {
  channel_->SetMethodCallHandler(
      [this](const auto &call, auto result) {
        this->HandleMethodCall(call, std::move(result));
      });
}

VoipCallEngineWindowsPlugin::~VoipCallEngineWindowsPlugin() = default;

void VoipCallEngineWindowsPlugin::EmitEvent(const flutter::EncodableMap &event_map) {
  flutter::EncodableMap enriched = event_map;
  enriched[flutter::EncodableValue("sequenceNumber")] =
      flutter::EncodableValue(++sequence_counter_);
  enriched[flutter::EncodableValue("timestampMs")] =
      flutter::EncodableValue(CurrentTimestampMs());

  channel_->InvokeMethod(
      "onNativeCallEvent",
      std::make_unique<flutter::EncodableValue>(enriched));
}

flutter::EncodableMap VoipCallEngineWindowsPlugin::QueryWasapiRouteState() {
  flutter::EncodableList available_routes = {
      flutter::EncodableValue("speaker"),
      flutter::EncodableValue("wiredHeadset"),
      flutter::EncodableValue("bluetooth"),
      flutter::EncodableValue("systemDefault"),
  };
  flutter::EncodableList devices_list;

  HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  const bool should_uninit = SUCCEEDED(hr);

  IMMDeviceEnumerator *enumerator = nullptr;
  hr = CoCreateInstance(
      __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
      __uuidof(IMMDeviceEnumerator), reinterpret_cast<void **>(&enumerator));

  if (SUCCEEDED(hr) && enumerator != nullptr) {
    IMMDeviceCollection *collection = nullptr;
    if (SUCCEEDED(enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &collection)) &&
        collection != nullptr) {
      UINT count = 0;
      collection->GetCount(&count);
      for (UINT i = 0; i < count; ++i) {
        IMMDevice *device = nullptr;
        if (SUCCEEDED(collection->Item(i, &device)) && device != nullptr) {
          LPWSTR device_id = nullptr;
          std::string id_str = "win_out_" + std::to_string(i);
          if (SUCCEEDED(device->GetId(&device_id)) && device_id != nullptr) {
            id_str = WideToUtf8(device_id);
            CoTaskMemFree(device_id);
          }

          std::string friendly_name = "Windows Audio Output";
          IPropertyStore *props = nullptr;
          if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &props)) && props != nullptr) {
            PROPVARIANT var_name;
            PropVariantInit(&var_name);
            if (SUCCEEDED(props->GetValue(PKEY_Device_FriendlyName, &var_name)) &&
                var_name.vt == VT_LPWSTR) {
              friendly_name = WideToUtf8(var_name.pwszVal);
            }
            PropVariantClear(&var_name);
            props->Release();
          }

          flutter::EncodableMap dev_map;
          dev_map[flutter::EncodableValue("id")] = flutter::EncodableValue(id_str);
          dev_map[flutter::EncodableValue("name")] = flutter::EncodableValue(friendly_name);
          dev_map[flutter::EncodableValue("route")] = flutter::EncodableValue(active_route_);
          dev_map[flutter::EncodableValue("isDefault")] = flutter::EncodableValue(i == 0);
          dev_map[flutter::EncodableValue("isInput")] = flutter::EncodableValue(false);
          devices_list.push_back(flutter::EncodableValue(dev_map));

          device->Release();
        }
      }
      collection->Release();
    }
    enumerator->Release();
  }

  if (should_uninit) {
    CoUninitialize();
  }

  flutter::EncodableMap route_state;
  route_state[flutter::EncodableValue("activeRoute")] = flutter::EncodableValue(active_route_);
  route_state[flutter::EncodableValue("availableRoutes")] = flutter::EncodableValue(available_routes);
  route_state[flutter::EncodableValue("availableDevices")] = flutter::EncodableValue(devices_list);
  route_state[flutter::EncodableValue("isAudioSessionActive")] =
      flutter::EncodableValue(is_audio_session_active_);
  route_state[flutter::EncodableValue("isMicrophoneMuted")] =
      flutter::EncodableValue(is_muted_);
  return route_state;
}

void VoipCallEngineWindowsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto &method = method_call.method_name();
  const auto *args = std::get_if<flutter::EncodableMap>(method_call.arguments());

  if (method == "initializeAndDrainColdStartBuffer") {
    result->Success(flutter::EncodableValue(flutter::EncodableList{}));
    return;
  }

  if (method == "reportIncomingCall") {
    if (args) {
      flutter::EncodableMap event;
      event[flutter::EncodableValue("type")] = flutter::EncodableValue("incomingReceived");
      event[flutter::EncodableValue("reportedViaPushKit")] = flutter::EncodableValue(false);
      event[flutter::EncodableValue("request")] = flutter::EncodableValue(*args);
      EmitEvent(event);
    }
    result->Success();
    return;
  }

  if (method == "startOutgoingCall") {
    if (args) {
      std::string call_id;
      auto it = args->find(flutter::EncodableValue("callId"));
      if (it != args->end() && std::holds_alternative<std::string>(it->second)) {
        call_id = std::get<std::string>(it->second);
      }
      is_audio_session_active_ = true;
      flutter::EncodableMap event;
      event[flutter::EncodableValue("type")] = flutter::EncodableValue("outgoingStarted");
      event[flutter::EncodableValue("callId")] = flutter::EncodableValue(call_id);
      event[flutter::EncodableValue("request")] = flutter::EncodableValue(*args);
      EmitEvent(event);

      flutter::EncodableMap audio_event;
      audio_event[flutter::EncodableValue("type")] =
          flutter::EncodableValue("audioSessionActivationChanged");
      audio_event[flutter::EncodableValue("isActive")] = flutter::EncodableValue(true);
      EmitEvent(audio_event);
    }
    result->Success();
    return;
  }

  if (method == "answerCall") {
    std::string call_id;
    if (args) {
      auto it = args->find(flutter::EncodableValue("callId"));
      if (it != args->end() && std::holds_alternative<std::string>(it->second)) {
        call_id = std::get<std::string>(it->second);
      }
    }
    is_audio_session_active_ = true;

    flutter::EncodableMap ans_event;
    ans_event[flutter::EncodableValue("type")] = flutter::EncodableValue("answered");
    ans_event[flutter::EncodableValue("callId")] = flutter::EncodableValue(call_id);
    ans_event[flutter::EncodableValue("source")] = flutter::EncodableValue("appUi");
    EmitEvent(ans_event);

    flutter::EncodableMap audio_event;
    audio_event[flutter::EncodableValue("type")] =
        flutter::EncodableValue("audioSessionActivationChanged");
    audio_event[flutter::EncodableValue("isActive")] = flutter::EncodableValue(true);
    EmitEvent(audio_event);

    result->Success();
    return;
  }

  if (method == "endCall") {
    std::string call_id;
    std::string reason = "localHangup";
    if (args) {
      auto it = args->find(flutter::EncodableValue("callId"));
      if (it != args->end() && std::holds_alternative<std::string>(it->second)) {
        call_id = std::get<std::string>(it->second);
      }
      auto r_it = args->find(flutter::EncodableValue("reason"));
      if (r_it != args->end() && std::holds_alternative<std::string>(r_it->second)) {
        reason = std::get<std::string>(r_it->second);
      }
    }
    is_audio_session_active_ = false;

    flutter::EncodableMap end_event;
    end_event[flutter::EncodableValue("type")] = flutter::EncodableValue("ended");
    end_event[flutter::EncodableValue("callId")] = flutter::EncodableValue(call_id);
    end_event[flutter::EncodableValue("reason")] = flutter::EncodableValue(reason);
    end_event[flutter::EncodableValue("source")] = flutter::EncodableValue("appUi");
    EmitEvent(end_event);

    result->Success();
    return;
  }

  if (method == "setHold") {
    std::string call_id;
    bool is_on_hold = false;
    if (args) {
      auto it = args->find(flutter::EncodableValue("callId"));
      if (it != args->end() && std::holds_alternative<std::string>(it->second)) {
        call_id = std::get<std::string>(it->second);
      }
      auto h_it = args->find(flutter::EncodableValue("isOnHold"));
      if (h_it != args->end() && std::holds_alternative<bool>(h_it->second)) {
        is_on_hold = std::get<bool>(h_it->second);
      }
    }
    flutter::EncodableMap hold_event;
    hold_event[flutter::EncodableValue("type")] = flutter::EncodableValue("heldChanged");
    hold_event[flutter::EncodableValue("callId")] = flutter::EncodableValue(call_id);
    hold_event[flutter::EncodableValue("isOnHold")] = flutter::EncodableValue(is_on_hold);
    hold_event[flutter::EncodableValue("heldBySystem")] = flutter::EncodableValue(false);
    hold_event[flutter::EncodableValue("source")] = flutter::EncodableValue("appUi");
    EmitEvent(hold_event);
    result->Success();
    return;
  }

  if (method == "setMuted") {
    std::string call_id;
    if (args) {
      auto it = args->find(flutter::EncodableValue("callId"));
      if (it != args->end() && std::holds_alternative<std::string>(it->second)) {
        call_id = std::get<std::string>(it->second);
      }
      auto m_it = args->find(flutter::EncodableValue("isMuted"));
      if (m_it != args->end() && std::holds_alternative<bool>(m_it->second)) {
        is_muted_ = std::get<bool>(m_it->second);
      }
    }
    flutter::EncodableMap mute_event;
    mute_event[flutter::EncodableValue("type")] = flutter::EncodableValue("mutedChanged");
    mute_event[flutter::EncodableValue("callId")] = flutter::EncodableValue(call_id);
    mute_event[flutter::EncodableValue("isMuted")] = flutter::EncodableValue(is_muted_);
    mute_event[flutter::EncodableValue("source")] = flutter::EncodableValue("appUi");
    EmitEvent(mute_event);
    result->Success();
    return;
  }

  if (method == "sendDtmf") {
    std::string call_id;
    std::string digits;
    if (args) {
      auto it = args->find(flutter::EncodableValue("callId"));
      if (it != args->end() && std::holds_alternative<std::string>(it->second)) {
        call_id = std::get<std::string>(it->second);
      }
      auto d_it = args->find(flutter::EncodableValue("digits"));
      if (d_it != args->end() && std::holds_alternative<std::string>(d_it->second)) {
        digits = std::get<std::string>(d_it->second);
      }
    }
    flutter::EncodableMap dtmf_event;
    dtmf_event[flutter::EncodableValue("type")] = flutter::EncodableValue("dtmfReceived");
    dtmf_event[flutter::EncodableValue("callId")] = flutter::EncodableValue(call_id);
    dtmf_event[flutter::EncodableValue("digits")] = flutter::EncodableValue(digits);
    EmitEvent(dtmf_event);
    result->Success();
    return;
  }

  if (method == "reportCallConnected") {
    is_audio_session_active_ = true;
    flutter::EncodableMap audio_event;
    audio_event[flutter::EncodableValue("type")] =
        flutter::EncodableValue("audioSessionActivationChanged");
    audio_event[flutter::EncodableValue("isActive")] = flutter::EncodableValue(true);
    EmitEvent(audio_event);
    result->Success();
    return;
  }

  if (method == "getAudioRouteState") {
    result->Success(flutter::EncodableValue(QueryWasapiRouteState()));
    return;
  }

  if (method == "setAudioRoute") {
    if (args) {
      auto it = args->find(flutter::EncodableValue("route"));
      if (it != args->end() && std::holds_alternative<std::string>(it->second)) {
        active_route_ = std::get<std::string>(it->second);
      }
    }
    flutter::EncodableMap route_event;
    route_event[flutter::EncodableValue("type")] = flutter::EncodableValue("audioRouteChanged");
    route_event[flutter::EncodableValue("reason")] = flutter::EncodableValue("manualOverride");
    route_event[flutter::EncodableValue("routeState")] =
        flutter::EncodableValue(QueryWasapiRouteState());
    EmitEvent(route_event);
    result->Success();
    return;
  }

  if (method == "getVoipPushToken") {
    result->Success(flutter::EncodableValue());
    return;
  }

  result->NotImplemented();
}

}  // namespace voip_call_engine_windows

void VoipCallEngineWindowsPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  voip_call_engine_windows::VoipCallEngineWindowsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
