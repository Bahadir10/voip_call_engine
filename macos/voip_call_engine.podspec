Pod::Spec.new do |s|
  s.name             = 'voip_call_engine'
  s.version          = '0.1.0'
  s.summary          = 'macOS CallKit and CoreAudio implementation for voip_call_engine.'
  s.description      = <<-DESC
macOS desktop CallKit and CoreAudio voice routing implementation for voip_call_engine.
                       DESC
  s.homepage         = 'https://github.com/example/flutter-packages'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Flutter Telecom' => 'telecom@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '11.0'
  s.frameworks       = 'CoreAudio', 'CallKit'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.9'
end
