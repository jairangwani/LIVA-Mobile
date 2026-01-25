# LIVA Mobile - Quick Start Guide

Get the LIVA mobile apps running in under 10 minutes.

## Prerequisites

- **Flutter** 3.16+ ([Install](https://flutter.dev/docs/get-started/install))
- **Android Studio** with Android SDK 24+ (for Android)
- **Xcode** 15+ (for iOS, Mac only)
- **AnnaOS-API** backend running (see main LIVA_CODE docs)

## Quick Start

### 1. Start the Backend

```bash
cd ~/Desktop/LIVA_CODE/AnnaOS-API
python main.py
# Backend runs on http://localhost:5003
```

### 2. Setup Flutter App

**Windows:**
```cmd
cd LIVA-Mobile\liva-flutter-app
setup.bat
```

**Mac/Linux:**
```bash
cd LIVA-Mobile/liva-flutter-app
chmod +x setup.sh
./setup.sh
```

**Or manually:**
```bash
cd LIVA-Mobile/liva-flutter-app
flutter pub get

# Initialize platform folders if empty
flutter create --org com.liva --project-name liva_app .
```

### 3. Run the App

**Android:**
```bash
# Start an emulator or connect a device
flutter run -d android
```

**iOS (Mac only):**
```bash
cd ios && pod install && cd ..
flutter run -d ios
```

---

## Directory Structure

```
LIVA-Mobile/
├── liva-sdk-ios/           # iOS SDK (Swift)
│   ├── Package.swift       # Swift Package Manager
│   ├── LIVAAnimation.podspec
│   └── LIVAAnimation/
│       └── Sources/
│           ├── Core/       # LIVAClient, SocketManager
│           ├── Rendering/  # AnimationEngine, FrameDecoder, CanvasView
│           └── Audio/      # AudioPlayer
│
├── liva-sdk-android/       # Android SDK (Kotlin)
│   └── liva-animation/
│       └── src/main/kotlin/com/liva/animation/
│           ├── core/       # LIVAClient, SocketManager, Configuration
│           ├── rendering/  # AnimationEngine, FrameDecoder, CanvasView
│           ├── audio/      # AudioPlayer
│           └── models/     # Data classes
│
├── liva-flutter-app/       # Flutter App
│   ├── lib/
│   │   ├── app/            # App shell, routes
│   │   ├── core/           # Config, theme
│   │   ├── features/       # Screens (chat, auth, agents, settings)
│   │   └── platform/       # Native SDK bridge
│   ├── ios/Runner/         # iOS plugin
│   └── android/app/        # Android plugin
│
└── docs/                   # Documentation
    ├── INTEGRATION_EXAMPLES.md
    └── API_REFERENCE.md
```

---

## Configuration

Update the backend URL in `lib/core/config/app_config.dart`:

```dart
class AppConfigConstants {
  static const String backendUrl = 'http://localhost:5003';  // Change this
  static const String defaultAgentId = '1';
}
```

---

## Testing the Flow

1. **Start Backend** - AnnaOS-API on port 5003
2. **Run Flutter App** - `flutter run`
3. **Login** - Use guest login or create account
4. **Chat** - Type a message and watch the avatar respond

---

## Common Issues

### Android: Gradle sync fails
```bash
cd android
./gradlew clean
./gradlew build
```

### iOS: Pod install fails
```bash
cd ios
rm -rf Pods Podfile.lock
pod install --repo-update
```

### Flutter: Platform folder empty
```bash
flutter create --org com.liva --project-name liva_app .
```

### Connection refused
- Make sure AnnaOS-API is running
- Check the serverUrl matches your backend
- For emulators, use `10.0.2.2:5003` instead of `localhost:5003`

---

## Using SDKs in Your Own App

### iOS (Swift)

Add to your `Package.swift`:
```swift
dependencies: [
    .package(path: "../liva-sdk-ios")
]
```

Or via CocoaPods:
```ruby
pod 'LIVAAnimation', :path => '../liva-sdk-ios'
```

### Android (Kotlin)

Add to `settings.gradle`:
```kotlin
include ':liva-animation'
project(':liva-animation').projectDir = file('../liva-sdk-android/liva-animation')
```

Add to `app/build.gradle`:
```kotlin
dependencies {
    implementation project(':liva-animation')
}
```

See [docs/INTEGRATION_EXAMPLES.md](docs/INTEGRATION_EXAMPLES.md) for full examples.

---

## Architecture Overview

```
┌─────────────────────────────────────────┐
│          Flutter App (UI)               │
│  Login → Chat → Agents → Settings       │
└──────────────────┬──────────────────────┘
                   │ Platform Channels
┌──────────────────┴──────────────────────┐
│          Native SDKs                     │
│  ┌─────────────┐  ┌─────────────┐       │
│  │ iOS SDK     │  │ Android SDK │       │
│  │ (Swift)     │  │ (Kotlin)    │       │
│  └─────────────┘  └─────────────┘       │
└──────────────────┬──────────────────────┘
                   │ Socket.IO + REST
┌──────────────────┴──────────────────────┐
│          AnnaOS-API Backend              │
│          (Port 5003)                     │
└─────────────────────────────────────────┘
```

---

## Next Steps

1. **Customize UI** - Modify screens in `lib/features/`
2. **Add agents** - Use the backend dashboard at localhost:8080
3. **Deploy** - Build release versions for App Store / Play Store

For more details, see the main [README.md](README.md) and [ARCHITECTURE.md](ARCHITECTURE.md).
