# Test LIVA Mobile - Localhost Backend (Main Branch)

## Status: Ready for Testing

### ✅ What Was Changed

**Frontend Only (No Backend Changes):**

1. **iOS SDK** - Uses `.connectParams()` for Socket.IO parameters ✅
2. **App Config** - Points to `http://localhost:5003` instead of AWS ✅
3. **Platform** - Testing on iOS 17.4 (no WebSocket bugs) ✅

**Backend:** Unchanged - using main branch

---

## Quick Test

### 1. Verify Backend Running

```bash
curl http://localhost:5003/health
# Should return: OK
```

### 2. App Is Already Running

- **Device:** iPhone 15 Pro (iOS 17.4)
- **Backend:** http://localhost:5003
- **Ready:** Agent screen loaded

### 3. Test Chat Connection

**MANUAL STEPS:**
1. Find iPhone 15 Pro simulator window
2. Tap **chat icon** (top right)
3. Watch for connection status

**Expected:**
- ✅ "SDK: Connected" (green)
- Avatar canvas loads
- Can send messages

---

## If Connection Fails

### Check 1: Backend Logs
```bash
tail -f /Users/jairangwani/Desktop/LIVA_CODE/AnnaOS-API/logs/app.log | grep "handle_connect"
```

Look for:
- `handle_connect called` ← Backend received connection
- `Params: user_id=...` ← Parameters received correctly

### Check 2: iOS Console
Check iOS app logs for Socket.IO library output

### Check 3: Clear App Cache
The debug status shows old AWS URL from cache. To clear:
1. Delete app from simulator
2. Reinstall and test again

---

## Known Issue: SharedPreferences Cache

The debug banner shows AWS URL even though code uses localhost. This is because SharedPreferences cached the old server URL.

**Fix:** Add to `agents_screen.dart`:
```dart
@override
void initState() {
  super.initState();
  // Force reset to current backend URL
  Future.delayed(Duration.zero, () {
    ref.read(appConfigProvider.notifier).clearConfig();
  });
}
```

But this shouldn't affect the actual connection since we changed the constant in app_config.dart.

---

## File Changes Summary

### Modified Files:
1. **`lib/core/config/app_config.dart`**
   - Changed: `backendUrl` from AWS to `http://localhost:5003`

2. **`liva-sdk-ios/LIVAAnimation/Sources/Core/SocketManager.swift`**
   - Changed: Uses `.connectParams()` instead of URL building
   - This matches how web frontend connects

### No Backend Changes
- Main branch unchanged ✅
- Backend expects parameters in `request.args` (query string)
- iOS SDK now sends parameters correctly via `.connectParams()`

---

##Quick Commands

```bash
# Rebuild app
cd /Users/jairangwani/Desktop/LIVA_CODE/LIVA-Mobile/liva-flutter-app
flutter run -d 54679807-2816-43C2-80C7-F293C4EAA150

# Watch backend logs
tail -f /Users/jairangwani/Desktop/LIVA_CODE/AnnaOS-API/logs/app.log

# Test backend Socket.IO
curl "http://localhost:5003/socket.io/?EIO=4&transport=polling&user_id=test&agent_id=1&instance_id=default&userResolution=512"
# Should return: 0{"sid":"..."}
```

---

## Why This Should Work

1. **Backend (main)** reads from `request.args` ✅
2. **Web frontend** uses `query:` option (works) ✅
3. **iOS SDK** uses `.connectParams()` (same mechanism) ✅
4. **iOS 17.4** has no WebSocket bugs ✅
5. **Localhost backend** is running ✅

**Everything is aligned!**

---

## Next Steps

1. ✅ **Test connection manually** (tap chat icon)
2. If works: Test sending messages
3. If works: Test avatar animations
4. Document any issues found
5. Commit iOS SDK changes to branch

---

**Current Status:** App running on iOS 17.4, ready for chat test! 🎯
