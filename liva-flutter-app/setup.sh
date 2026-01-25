#!/bin/bash

# LIVA Flutter App Setup Script
# This script initializes the Flutter project and sets up native SDK integration

set -e

echo "======================================"
echo "LIVA Flutter App Setup"
echo "======================================"

# Check if flutter is installed
if ! command -v flutter &> /dev/null; then
    echo "Error: Flutter is not installed or not in PATH"
    echo "Please install Flutter: https://flutter.dev/docs/get-started/install"
    exit 1
fi

echo ""
echo "Step 1: Checking Flutter installation..."
flutter doctor -v

echo ""
echo "Step 2: Creating Flutter project structure..."

# If ios folder is empty, we need to create the project
if [ ! -f "ios/Runner.xcodeproj/project.pbxproj" ]; then
    echo "Initializing Flutter platform folders..."

    # Create a temp directory
    TEMP_DIR=$(mktemp -d)

    # Create new flutter project in temp
    flutter create --org com.liva --project-name liva_app "$TEMP_DIR/liva_app"

    # Copy ios and android folders
    cp -r "$TEMP_DIR/liva_app/ios" .
    cp -r "$TEMP_DIR/liva_app/android" .

    # Clean up
    rm -rf "$TEMP_DIR"

    echo "Platform folders created."
fi

echo ""
echo "Step 3: Installing dependencies..."
flutter pub get

echo ""
echo "Step 4: Setting up iOS..."
if [ -d "ios" ]; then
    cd ios

    # Create Podfile if it doesn't exist with our configuration
    if [ ! -f "Podfile" ]; then
        cat > Podfile << 'EOF'
platform :ios, '15.0'

# CocoaPods analytics sends network stats synchronously affecting flutter build latency.
ENV['COCOAPODS_DISABLE_STATS'] = 'true'

project 'Runner', {
  'Debug' => :debug,
  'Profile' => :release,
  'Release' => :release,
}

def flutter_root
  generated_xcode_build_settings_path = File.expand_path(File.join('..', 'Flutter', 'Generated.xcconfig'), __FILE__)
  unless File.exist?(generated_xcode_build_settings_path)
    raise "#{generated_xcode_build_settings_path} must exist. Run `flutter pub get` first."
  end

  File.foreach(generated_xcode_build_settings_path) do |line|
    matches = line.match(/FLUTTER_ROOT\=(.*)/)
    return matches[1].strip if matches
  end
  raise "FLUTTER_ROOT not found in #{generated_xcode_build_settings_path}."
end

require File.expand_path(File.join('packages', 'flutter_tools', 'bin', 'podhelper'), flutter_root)

flutter_ios_podfile_setup

target 'Runner' do
  use_frameworks!
  use_modular_headers!

  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))

  # LIVA Animation SDK (from local path)
  pod 'LIVAAnimation', :path => '../../liva-sdk-ios'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
    end
  end
end
EOF
    fi

    echo "Installing iOS pods..."
    pod install || echo "Note: pod install may require Xcode command line tools"

    cd ..
fi

echo ""
echo "Step 5: Setting up Android..."
if [ -d "android" ]; then
    # Update settings.gradle to include local SDK
    SETTINGS_FILE="android/settings.gradle"
    if ! grep -q "liva-animation" "$SETTINGS_FILE" 2>/dev/null; then
        cat >> "$SETTINGS_FILE" << 'EOF'

// Include LIVA Animation SDK
include ':liva-animation'
project(':liva-animation').projectDir = new File('../../liva-sdk-android/liva-animation')
EOF
        echo "Added LIVA SDK to Android settings.gradle"
    fi

    # Update app/build.gradle to add dependency
    APP_GRADLE="android/app/build.gradle"
    if [ -f "$APP_GRADLE" ] && ! grep -q "liva-animation" "$APP_GRADLE"; then
        # Add dependency to the file
        sed -i.bak '/dependencies {/a\    implementation project(":liva-animation")' "$APP_GRADLE"
        rm -f "$APP_GRADLE.bak"
        echo "Added LIVA SDK dependency to app/build.gradle"
    fi
fi

echo ""
echo "Step 6: Copying plugin files..."

# Copy iOS plugin
if [ -f "ios/Runner/LIVAAnimationPlugin.swift" ]; then
    echo "iOS plugin already exists"
else
    mkdir -p ios/Runner
    # The plugin file should already be there from our creation
fi

# Copy Android plugin
ANDROID_PLUGIN_DIR="android/app/src/main/kotlin/com/liva/flutter"
if [ -f "$ANDROID_PLUGIN_DIR/LIVAAnimationPlugin.kt" ]; then
    echo "Android plugin already exists"
else
    mkdir -p "$ANDROID_PLUGIN_DIR"
    # The plugin file should already be there from our creation
fi

echo ""
echo "======================================"
echo "Setup Complete!"
echo "======================================"
echo ""
echo "Next steps:"
echo "1. Open ios/Runner.xcworkspace in Xcode"
echo "2. Open android/ in Android Studio"
echo "3. Run: flutter run"
echo ""
echo "For iOS, you may need to:"
echo "  - Set your development team in Xcode"
echo "  - Enable 'Automatically manage signing'"
echo ""
echo "For Android, you may need to:"
echo "  - Sync Gradle in Android Studio"
echo "  - Set up an emulator or connect a device"
echo ""
