# LIVA Native Android Test App

Simple native Android app for testing the LIVA Animation SDK.

## Architecture

- **Native Android** (Kotlin + XML layouts)
- **Properly depends on SDK** via gradle module reference
- **No code duplication** - uses source SDK directly
- **Simple UI** - Canvas view + message input

## Project Structure

```
liva-android-app/
├── app/
│   ├── src/main/
│   │   ├── java/com/liva/testapp/
│   │   │   └── MainActivity.kt       # Main activity
│   │   ├── res/layout/
│   │   │   └── activity_main.xml     # UI layout
│   │   └── AndroidManifest.xml
│   └── build.gradle.kts
├── settings.gradle.kts                # Includes SDK module
└── build.gradle.kts
```

## Build System

The app properly references the SDK as a gradle module:

```kotlin
// settings.gradle.kts
include(":liva-animation")
project(":liva-animation").projectDir = file("../liva-sdk-android/liva-animation")
```

**Benefits:**
- Single source of truth (SDK source code)
- No manual syncing required
- Changes to SDK immediately available
- Clean architecture

## Building

### Android Studio (Recommended)
1. Open `liva-android-app/` in Android Studio
2. Wait for Gradle sync
3. Run on emulator or device

### Command Line
```bash
cd liva-android-app

# Build debug APK
./gradlew assembleDebug

# Install on connected device/emulator
./gradlew installDebug

# Or combined
./gradlew installDebug
```

## Configuration

**Backend URL:** Hardcoded to `http://10.0.2.2:5003` (Android emulator → host)

To change, edit `MainActivity.kt`:
```kotlin
private const val SERVER_URL = "http://10.0.2.2:5003"
```

## Usage

1. Start backend: `cd AnnaOS-API && python main.py`
2. Run app on emulator
3. Wait for socket connection (~20 seconds)
4. Type message and press Send
5. Watch animation play

## Testing

View session logs:
```bash
# Web UI
open http://localhost:5003/logs

# CLI
ls -la ../LIVA-TESTS/logs/sessions/ | grep ANDROID
```

## vs Flutter App

**Advantages of Native:**
- ✅ No Flutter overhead
- ✅ Direct SDK access (no platform channels)
- ✅ Easier debugging
- ✅ No build system complexity
- ✅ Consistent with iOS being native

**Flutter app:**
- Now iOS-only (`liva-flutter-app/`)
- Will be replaced with native iOS app in future
