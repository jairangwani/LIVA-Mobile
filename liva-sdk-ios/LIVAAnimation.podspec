Pod::Spec.new do |s|
  s.name             = 'LIVAAnimation'
  s.version          = '1.0.0'
  s.summary          = 'LIVA Avatar Animation SDK for iOS'
  s.description      = <<-DESC
    Native iOS SDK for rendering LIVA avatar animations with real-time
    lip sync and audio playback. Connects to AnnaOS-API backend via Socket.IO.
  DESC

  s.homepage         = 'https://github.com/your-org/liva-sdk-ios'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'LIVA Team' => 'team@liva.com' }
  s.source           = { :git => 'https://github.com/your-org/liva-sdk-ios.git', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.swift_version = '5.9'

  s.source_files = 'LIVAAnimation/Sources/**/*.swift'

  s.dependency 'Socket.IO-Client-Swift', '~> 16.0'

  s.frameworks = 'UIKit', 'AVFoundation', 'CoreGraphics'
end
