# Android Emulator Networking Guide

## Problem Solved (2026-01-28)

Android 14 emulator (API 34) blocks application-level sockets to host machine, even when:
- Shell commands (`nc`, `ping`) work
- Cleartext traffic is enabled
- Proper permissions are set

## The Solution

### 1. Cold Boot the Emulator (CRITICAL)

The emulator's network stack can become corrupted. Always cold boot when starting a dev session:

```bash
# Option A: Via Android Studio
# Device Manager → Click "..." next to device → "Cold Boot Now"

# Option B: Via command line
/Users/jairangwani/Library/Android/sdk/emulator/emulator -avd Pixel_3a_API_34 -no-snapshot-load
```

### 2. Use `adb reverse` + localhost

Instead of using `10.0.2.2` (which is unreliable on API 34), tunnel through USB:

```bash
# Run this after emulator boots
adb reverse tcp:5003 tcp:5003
```

Then in Android code, use `localhost`:
```kotlin
// WRONG (unreliable on API 34)
private const val SERVER_URL = "http://10.0.2.2:5003"

// CORRECT (works with adb reverse)
private const val SERVER_URL = "http://localhost:5003"
```

### 3. Network Security Config (Required for Android 9+)

Create `app/src/main/res/xml/network_security_config.xml`:
```xml
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config cleartextTrafficPermitted="true">
        <trust-anchors>
            <certificates src="system" />
        </trust-anchors>
    </base-config>
</network-security-config>
```

Link in `AndroidManifest.xml`:
```xml
<application
    android:networkSecurityConfig="@xml/network_security_config"
    android:usesCleartextTraffic="true"
    ...>
```

### 4. Uninstall Before Testing Config Changes

Android caches security configs. After changing network_security_config.xml:
```bash
adb uninstall com.your.package
adb install app/build/outputs/apk/debug/app-debug.apk
```

## Quick Start Checklist

1. [ ] Cold boot emulator (or use `-no-snapshot-load`)
2. [ ] Run `adb reverse tcp:5003 tcp:5003`
3. [ ] Use `http://localhost:5003` in app (not 10.0.2.2)
4. [ ] Have `network_security_config.xml` with cleartext permitted
5. [ ] Link config in AndroidManifest.xml
6. [ ] Uninstall app if you changed network config

## Test Commands

```bash
# Verify emulator is connected
adb devices

# Setup port forwarding
adb reverse tcp:5003 tcp:5003

# Verify port forwarding
adb reverse --list

# Test from emulator shell (should work)
adb shell "nc localhost 5003"

# Install app
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## Why 10.0.2.2 Fails on API 34

- Android 14's application sandbox is stricter
- Shell runs as privileged user (bypasses sandbox)
- Apps run as restricted user (blocked by sandbox)
- `adb reverse` creates a tunnel that bypasses this restriction

## Files Modified in LIVA-Mobile (2026-01-28)

### Native Android Test App (`liva-android-app/`)

- `app/src/main/res/xml/network_security_config.xml` - Created
- `app/src/main/AndroidManifest.xml` - Added networkSecurityConfig reference
- `app/src/main/java/com/liva/testapp/MainActivity.kt` - Changed URL to localhost

### Android SDK (`liva-sdk-android/liva-animation/`)

- `src/main/res/xml/network_security_config.xml` - Created (apps inherit when using SDK)

### Flutter App (`liva-flutter-app/`)

- `lib/core/config/app_config.dart` - Changed `backendUrlAndroid` to localhost

## Socket.IO Compatibility

The Android SDK uses Socket.IO client v2.1.0 which is compatible with the Python backend's Socket.IO v4.x server. The key fix was networking, not Socket.IO version mismatch.

Working configuration:
- **Backend:** Python Flask-SocketIO (async_mode='eventlet')
- **Android Client:** Socket.IO-Kotlin v2.1.0 with WebSocket transport only
- **Transport:** `{ transports: ["websocket"] }` (no polling fallback)
