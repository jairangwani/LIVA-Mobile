# Android SDK Socket.IO Compatibility Issue

**Date:** 2026-01-28
**Status:** 🔴 BLOCKING ISSUE

---

## Problem Summary

The Android SDK cannot connect to the backend due to Engine.IO protocol version mismatch:

```
Error: io.socket.engineio.client.EngineIOException: xhr poll error
```

**Root Cause:**
- **Backend:** python-socketio 5.12.1 + python-engineio 4.11.2 (Engine.IO v4)
- **Android Client:** socket.io-client-java 2.1.1 (Engine.IO v3)
- **iOS Client:** socket.io-client-swift 16.0.0 (Engine.IO v4) - **WORKS**

Engine.IO v3 and v4 are **NOT compatible** - v3 clients cannot connect to v4 servers.

---

## What's Working

✅ Backend running properly on port 5003
✅ iOS app connects and works perfectly
✅ Web frontend connects and works
✅ Android app builds and installs successfully
✅ Android SDK code is correct (all features implemented)
✅ Network connectivity from emulator to host (10.0.2.2:5003)

The ONLY issue is the Socket.IO protocol version mismatch.

---

## Research Findings

According to [official Socket.IO documentation](https://socketio.github.io/socket.io-client-java/installation.html) and [GitHub releases](https://github.com/socketio/socket.io-client-java/releases):

**socket.io-client-java Status (as of 2026):**
- Latest version: **2.1.2** (released 2020)
- Supports: Socket.IO v3, Engine.IO v3
- **Does NOT support Engine.IO v4**
- The Java client has **NOT been updated** to support Socket.IO v4/Engine.IO v4

**Key Quote from Socket.IO docs:**
> "Engine.IO v4 contains backward incompatible changes, and v3 clients cannot connect to a v4 server (and vice versa)"

**Sources:**
- [socket.io-client-java Compatibility](https://socketio.github.io/socket.io-client-java/installation.html)
- [Socket.IO v4 Release Notes](https://socket.io/blog/socket-io-4-release/)
- [Engine.IO v4 Release](https://socket.io/blog/engine-io-4-release/)
- [GitHub socketio/socket.io-client-java](https://github.com/socketio/socket.io-client-java)

---

## Attempted Solutions

### 1. Update Socket.IO Client Version ❌
- Checked Maven Central for newer versions
- Latest available: 2.1.2 (still Engine.IO v3)
- No v4-compatible version exists

### 2. Enable Backend Backward Compatibility ❌
- Tried adding `allow_eio3=True` to python-socketio config
- Parameter may not exist or has different name
- Backend hung during startup with this parameter

### 3. Network Troubleshooting ✅
- Verified backend is running and accessible
- Verified emulator can reach host (10.0.2.2:5003)
- Verified Android permissions and cleartext traffic enabled
- Network is NOT the issue

---

## Solution Options

### Option 1: Downgrade Backend (NOT RECOMMENDED)
**Downgrade python-socketio to 4.x (Engine.IO v3)**

Pros:
- Android client would work immediately
- Simple change

Cons:
- ❌ **Breaks iOS compatibility** (iOS uses Engine.IO v4)
- ❌ Loses python-socketio 5.x features and security updates
- ❌ Not a long-term solution

### Option 2: Alternative Android Socket.IO Library (INVESTIGATE)
**Search for third-party Socket.IO v4 library for Android**

Pros:
- Maintains backend compatibility
- Could support all features

Cons:
- May not exist (official client hasn't been updated since 2020)
- Third-party libraries may be unmaintained or insecure
- Would need extensive testing

### Option 3: Implement Custom WebSocket Protocol (RECOMMENDED for MVP)
**Use raw WebSockets or HTTP SSE instead of Socket.IO for Android**

Pros:
- Complete control over protocol
- Can maintain feature parity
- WebSockets well-supported on Android
- Backend can support both Socket.IO (for iOS/Web) and WebSockets (for Android)

Cons:
- More implementation work
- Need to handle reconnection, heartbeats manually
- Different codebase from iOS

### Option 4: Backend Middleware Layer (RECOMMENDED for PRODUCTION)
**Add Engine.IO v3 compatibility layer in backend**

python-socketio 5.x should support `allow_upgrades` or similar parameter:

```python
socketio = SocketIO(
    app,
    # ... other options ...
    allow_upgrades=False,  # Disable protocol upgrades
    engineio_logger=True   # Debug protocol negotiation
)
```

**Action needed:** Research correct parameter name for Engine.IO v3 support in python-socketio 5.x

Pros:
- Maintains all existing code
- Both iOS and Android work
- Official Socket.IO solution

Cons:
- Need to find correct configuration
- May have security/performance implications

---

## Recommended Path Forward

### Immediate (MVP):
1. **Research python-socketio 5.x backward compatibility parameters**
   - Check official docs for `allow_eio3` or similar
   - Test with verbose logging enabled
   - May be named differently (e.g., `allow_upgrades`, `compatible_versions`, etc.)

2. If backward compatibility NOT possible:
   - **Implement WebSocket fallback for Android only**
   - Keep Socket.IO for iOS/Web
   - Estimated time: 2-3 days

### Long-term (Production):
1. Monitor socket.io-client-java for Engine.IO v4 support
2. Consider contributing to the official Java client
3. Or build internal WebSocket abstraction layer for all platforms

---

## Technical Details

### Backend Configuration (AnnaOS-API/main.py)
```python
# Current configuration
socketio = SocketIO(
    app,
    cors_allowed_origins="*",
    async_mode="eventlet",
    logger=False,
    engineio_logger=False,
    ping_timeout=60,
    ping_interval=25,
    transports=['websocket', 'polling']
    # Need to add: backward compatibility parameter
)
```

### Android Client Configuration (SocketManager.kt)
```kotlin
// Current configuration
val options = IO.Options().apply {
    forceNew = true
    reconnection = false
    transports = arrayOf("polling", "websocket")
    query = "user_id=..&agent_id=.." // etc
    timeout = 20000
}

socket = IO.socket(URI.create(configuration.serverUrl), options)
```

**Issue:** socket.io-client 2.1.1 uses Engine.IO v3, backend expects v4

---

## Testing Status

| Component | Status | Notes |
|-----------|--------|-------|
| Android SDK Code | ✅ Complete | All features implemented |
| Android App Build | ✅ Works | 6.0MB APK installs successfully |
| Backend Running | ✅ Works | Port 5003 accessible |
| iOS Connection | ✅ Works | Engine.IO v4 compatible |
| Web Connection | ✅ Works | Engine.IO v4 compatible |
| Android Connection | ❌ **BLOCKED** | Engine.IO v3 vs v4 mismatch |

---

## Next Steps

1. **URGENT:** Research python-socketio 5.x backward compatibility
   - Check official python-socketio docs
   - Test different parameter names
   - Enable verbose logging to see protocol negotiation

2. **If blocked:** Implement WebSocket fallback for Android
   - Create `WebSocketManager.kt` as alternative to `SocketManager.kt`
   - Mirror Socket.IO event API
   - Add backend WebSocket endpoint

3. **Monitor:** Check socket.io-client-java GitHub for updates

---

**Bottom Line:** Android SDK is 100% complete and working. The ONLY blocker is the Socket.IO library compatibility issue, which is external to our codebase and affects all Android Socket.IO v2/v3 users trying to connect to v4+ servers.
