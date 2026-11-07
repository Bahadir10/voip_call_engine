Pod::Spec.new do |s|
  s.name             = 'voip_call_engine'
  s.version          = '0.1.0'
  s.summary          = 'iOS PushKit + CallKit + AVAudioSession implementation for voip_call_engine.'
  s.description      = <<-DESC
Production-grade iOS CallKit, PushKit, and AVAudioSession voice routing implementation with deterministic cold-start event buffering.
                       DESC
  s.homepage         = 'https://github.com/example/flutter-packages'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Flutter Telecom' => 'telecom@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.frameworks       = 'CallKit', 'PushKit', 'AVFoundation', 'UIKit'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version    = '5.9'
end
