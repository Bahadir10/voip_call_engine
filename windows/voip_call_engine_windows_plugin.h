#ifndef FLUTTER_PLUGIN_VOIP_CALL_ENGINE_WINDOWS_PLUGIN_H_
#define FLUTTER_PLUGIN_VOIP_CALL_ENGINE_WINDOWS_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

namespace voip_call_engine_windows {

class VoipCallEngineWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  explicit VoipCallEngineWindowsPlugin(
      std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel);

  virtual ~VoipCallEngineWindowsPlugin();

  VoipCallEngineWindowsPlugin(const VoipCallEngineWindowsPlugin &) = delete;
  VoipCallEngineWindowsPlugin &operator=(const VoipCallEngineWindowsPlugin &) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void EmitEvent(const flutter::EncodableMap &event_map);
  flutter::EncodableMap QueryWasapiRouteState();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::string active_route_ = "speaker";
  bool is_audio_session_active_ = false;
  bool is_muted_ = false;
  int sequence_counter_ = 0;
};

}  // namespace voip_call_engine_windows

#endif  // FLUTTER_PLUGIN_VOIP_CALL_ENGINE_WINDOWS_PLUGIN_H_
