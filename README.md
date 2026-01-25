# LIVA Mobile

Native SDKs and Flutter app for LIVA avatar animation system.

## Components

| Directory | Purpose | Language | Status |
|-----------|---------|----------|--------|
| [liva-sdk-ios](liva-sdk-ios/) | iOS SDK for third-party integration | Swift | Complete |
| [liva-sdk-android](liva-sdk-android/) | Android SDK for third-party integration | Kotlin | Complete |
| [liva-flutter-app](liva-flutter-app/) | LIVA standalone mobile app | Dart | Complete |
| [docs](docs/) | Shared documentation | Markdown | Active |

## Implementation Status

### iOS SDK (Complete)
- **LIVAClient** - Main SDK interface with singleton pattern
- **LIVASocketManager** - Socket.IO connection with auto-reconnect
- **FrameDecoder** - Base64 image decoding with LRU cache (50MB)
- **AnimationEngine** - Frame timing at 10fps (idle) / 30fps (talking)
- **LIVACanvasView** - CADisplayLink render loop with CALayer
- **AudioPlayer** - AVAudioEngine for MP3 streaming

### Android SDK (Complete)
- **LIVAClient** - Main SDK interface with singleton pattern
- **LIVASocketManager** - Socket.IO connection with exponential backoff
- **FrameDecoder** - Base64 decoding with LruCache
- **AnimationEngine** - Choreographer-based timing
- **LIVACanvasView** - SurfaceView with bitmap rendering
- **AudioPlayer** - MediaCodec for MP3 decoding to AudioTrack

### Flutter App (Complete)
- **Platform Channels** - LIVAAnimation class bridging to native SDKs
- **LIVACanvasWidget** - Native view embedding (UiKitView / AndroidView)
- **ChatScreen** - Main chat interface with avatar animation
- **LoginScreen** - Email/password + guest authentication
- **AgentsScreen** - Agent selection list
- **SettingsScreen** - Configuration and debug options

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     AnnaOS-API (Backend)                     │
│                        Port 5003                             │
└─────────────────────────┬───────────────────────────────────┘
                          │
                    Socket.IO + REST
                          │
┌─────────────────────────┴───────────────────────────────────┐
│                    LIVA Native SDKs                          │
│  ┌─────────────────────┐    ┌─────────────────────┐         │
│  │  liva-sdk-ios       │    │  liva-sdk-android   │         │
│  │  (Swift Framework)  │    │  (Kotlin AAR)       │         │
│  │                     │    │                     │         │
│  │  • Socket Manager   │    │  • Socket Manager   │         │
│  │  • Frame Decoder    │    │  • Frame Decoder    │         │
│  │  • Canvas Renderer  │    │  • Canvas Renderer  │         │
│  │  • Audio Player     │    │  • Audio Player     │         │
│  └─────────────────────┘    └─────────────────────┘         │
└─────────────────────────┬───────────────────────────────────┘
                          │
                   Platform Channels
                          │
┌─────────────────────────┴───────────────────────────────────┐
│                   liva-flutter-app                           │
│                                                              │
│  • UI/UX (Screens, Navigation)                              │
│  • Authentication Flow                                       │
│  • State Management                                          │
│  • Native SDK Integration via Platform Channels              │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│              Third-Party App Integration                     │
│                                                              │
│  • ChatGPT (React Native) → Uses native SDK via bridge      │
│  • Claude (Native) → Uses SDK directly                       │
│  • Gemini (Native) → Uses SDK directly                       │
│  • Any iOS/Android app → Integrates SDK                      │
└─────────────────────────────────────────────────────────────┘
```

## Quick Start

### Prerequisites

- **iOS SDK**: Xcode 15+, iOS 15.0+ deployment target
- **Android SDK**: Android Studio, minSdk 24 (Android 7.0+)
- **Flutter App**: Flutter 3.16+, Dart 3.2+

### Building

```bash
# iOS SDK
cd liva-sdk-ios
swift build

# Android SDK
cd liva-sdk-android
./gradlew build

# Flutter App
cd liva-flutter-app
flutter pub get
flutter run
```

## SDK Distribution

### iOS
- **Swift Package Manager**: Add via Xcode
- **CocoaPods**: `pod 'LIVAAnimation'`

### Android
- **Gradle**: `implementation 'com.liva:animation:1.0.0'`
- **Maven Central**: Published releases

## Package Identifiers

| Platform | Identifier |
|----------|------------|
| iOS SDK Bundle | `com.liva.animation` |
| Android SDK Package | `com.liva.animation` |
| Flutter App Bundle | `com.liva.app` |

## Related Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) - Detailed architecture and data flow
- [SOCKET_PROTOCOL.md](SOCKET_PROTOCOL.md) - Socket.IO event specification
- [docs/API_REFERENCE.md](docs/API_REFERENCE.md) - SDK public API documentation
- [docs/PUBLISHING.md](docs/PUBLISHING.md) - How to publish SDKs

## Backend Compatibility

These SDKs connect to the existing AnnaOS-API backend. No backend changes required.

| Endpoint | Purpose |
|----------|---------|
| `POST /messages` | Send user message |
| `GET /api/config` | Get backend configuration |
| `Socket.IO /` | Real-time frame + audio streaming |

See [SOCKET_PROTOCOL.md](SOCKET_PROTOCOL.md) for complete event specification.
