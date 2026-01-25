# LIVA Flutter App

Cross-platform mobile application for LIVA avatar chat system.

## Overview

This Flutter app provides the UI/UX layer for LIVA, using native SDKs for
performance-critical avatar rendering and audio playback.

## Requirements

- Flutter 3.16+
- Dart 3.2+
- iOS: Xcode 15+, iOS 15.0+
- Android: Android Studio, minSdk 24

## Getting Started

### Install Dependencies

```bash
flutter pub get
```

### Run Development

```bash
# iOS
flutter run -d ios

# Android
flutter run -d android

# Both (pick device)
flutter run
```

### Build Release

```bash
# iOS
flutter build ios --release

# Android
flutter build apk --release
flutter build appbundle --release
```

## Architecture

```
lib/
├── main.dart                 # App entry point
├── app/
│   ├── app.dart             # App widget
│   └── routes.dart          # Navigation routes
├── core/
│   ├── config/              # App configuration
│   ├── theme/               # Theme definitions
│   └── constants/           # App constants
├── features/
│   ├── auth/                # Authentication
│   ├── chat/                # Main chat + avatar
│   ├── agents/              # Agent selection
│   └── settings/            # User settings
├── platform/
│   ├── liva_animation.dart  # Platform channel interface
│   ├── liva_animation_ios.dart
│   └── liva_animation_android.dart
└── shared/
    ├── widgets/             # Reusable widgets
    └── utils/               # Utility functions
```

## Native SDK Integration

The app uses native SDKs for avatar rendering via platform channels:

```dart
// Platform channel interface
import 'package:liva_app/platform/liva_animation.dart';

// Initialize
await LIVAAnimation.initialize(config);

// Connect
await LIVAAnimation.connect();

// The LIVACanvasWidget renders the native view
LIVACanvasWidget()
```

## Features

### Authentication
- Email/password login
- Guest mode
- Session persistence

### Chat
- Text input
- Voice input (optional)
- Message history
- Real-time avatar animation

### Agent Selection
- Browse available agents
- Agent details
- Switch agents

### Settings
- Backend URL configuration
- Resolution settings
- Theme preferences

## State Management

Using Riverpod for state management:

```dart
// Providers
final authProvider = StateNotifierProvider<AuthNotifier, AuthState>(...);
final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>(...);
final agentProvider = StateNotifierProvider<AgentNotifier, AgentState>(...);
```

## Testing

```bash
# Unit tests
flutter test

# Integration tests
flutter test integration_test/
```

## Configuration

### Development

Edit `lib/core/config/app_config.dart`:

```dart
class AppConfig {
  static const String backendUrl = 'http://localhost:5003';
  static const String defaultAgentId = '1';
}
```

### Production

```dart
class AppConfig {
  static const String backendUrl = 'https://api.liva.com';
  static const String defaultAgentId = '1';
}
```

## Platform-Specific Setup

### iOS

The native SDK is linked in `ios/Podfile`:

```ruby
pod 'LIVAAnimation', :path => '../../liva-sdk-ios'
```

### Android

The native SDK is linked in `android/app/build.gradle.kts`:

```kotlin
dependencies {
    implementation(project(":liva-animation"))
}
```

## Troubleshooting

### SDK not rendering
1. Ensure native SDKs are properly linked
2. Check platform channel connection
3. Verify backend is reachable

### Build failures
```bash
# Clean and rebuild
flutter clean
flutter pub get
flutter run
```
