# Socket Protocol Reference

Single source of truth for Socket.IO events between mobile SDKs and AnnaOS-API backend.

Both iOS and Android SDKs implement this specification.

## Connection

### URL
```
Production: https://api.liva.com
Development: http://localhost:5003
```

### Query Parameters (Required)

| Parameter | Type | Description |
|-----------|------|-------------|
| `user_id` | string | UUID or email identifier |
| `agent_id` | string | Numeric agent ID (e.g., "1") |
| `instance_id` | string | Session ID (e.g., "default") |
| `userResolution` | string | Canvas resolution (e.g., "512") |

### Connection Example

```javascript
// JavaScript reference (SDKs implement natively)
socket.io(BACKEND_URL, {
  query: {
    user_id: "550e8400-e29b-41d4-a716-446655440000",
    agent_id: "1",
    instance_id: "default",
    userResolution: "512"
  },
  transports: ['websocket', 'polling']
});
```

### Room Assignment

Server joins client to room: `{user_id}-{agent_id}-instance-{instance_id}`

Example: `550e8400-e29b-41d4-a716-446655440000-1-instance-default`

---

## Events: Server → Client

### `receive_audio`

Audio chunk with animation metadata. Emitted multiple times per message.

```json
{
  "audio_data": "<base64_encoded_mp3>",
  "chunk_index": 0,
  "master_chunk_index": 0,
  "animationFramesChunk": [
    {
      "animation_name": "talking_1_s_talking_1_e",
      "sections": [[/* frame objects */]],
      "zone_top_left": [128, 256],
      "master_frame_play_at": 0,
      "mode": "talking"
    }
  ],
  "total_frame_images": 45,
  "first_frame_image": {
    "image_data": "<base64>",
    "sheet_filename": "frame_0.webp"
  },
  "timestamp": "2026-01-21 15:30:45.123"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `audio_data` | string | Base64 MP3 audio chunk |
| `chunk_index` | int | Index within current message |
| `master_chunk_index` | int | Global chunk index |
| `animationFramesChunk` | array | Animation metadata for this chunk |
| `total_frame_images` | int | Total frames for this chunk |
| `first_frame_image` | object | First frame for immediate display |
| `timestamp` | string | Server timestamp |

### `receive_frame_images_batch`

Batch of decoded frames. Up to 50 frames per emission.

```json
{
  "frames": [
    {
      "image_data": "<base64_webp>",
      "image_mime": "image/webp",
      "sprite_index_folder": 0,
      "sheet_filename": "frame_0.webp",
      "animation_name": "talking_1_s_talking_1_e",
      "sequence_index": 0,
      "section_index": 0,
      "frame_index": 0,
      "matched_sprite_frame_number": 10,
      "char": "vowel"
    }
  ],
  "chunk_index": 0,
  "batch_index": 0,
  "batch_start_index": 0,
  "batch_size": 45,
  "total_batches": 1,
  "emission_timestamp": 1705859445123
}
```

| Field | Type | Description |
|-------|------|-------------|
| `frames` | array | Array of frame objects |
| `frames[].image_data` | string | Base64 encoded image |
| `frames[].image_mime` | string | MIME type (image/webp, image/png) |
| `frames[].animation_name` | string | Animation sequence name |
| `frames[].sequence_index` | int | Position in sequence |
| `frames[].matched_sprite_frame_number` | int | Sprite sheet frame number |
| `frames[].char` | string | Phoneme type (vowel, consonant, etc.) |
| `chunk_index` | int | Audio chunk this belongs to |
| `batch_index` | int | Batch number within chunk |
| `batch_size` | int | Total frames in batch |
| `total_batches` | int | Total batches for chunk |

### `chunk_images_ready`

Signal that all frames for a chunk have been sent.

```json
{
  "chunk_index": 0,
  "total_images_sent": 45
}
```

### `audio_end`

Signal that no more audio chunks are coming.

```json
{}
```

### `play_base_animation` (or `play_animation`)

Request to play a transition or idle animation.

```json
{
  "animation_name": "talking_1a_e_idle_1_s"
}
```

---

## Events: Client → Server

### Connection (Automatic)

Handled via query parameters on connect. No explicit event needed.

### `user_full_audio` (Optional - Voice Input)

Send user voice recording for speech-to-text processing.

```json
{
  "user_id": "550e8400-e29b-41d4-a716-446655440000",
  "agent_id": "1",
  "app_name": "liva_mobile",
  "instance_id": "default",
  "audio_data": "<base64_wav_or_mp3>",
  "userResolution": "512",
  "messageHistory": [],
  "timestamp": 1705859445123
}
```

### `request_specific_base_animation` (Optional)

Request a specific animation sequence.

```json
{
  "agentId": "1",
  "animationType": "idle_1"
}
```

---

## Connection Events

### `connect`
Socket connected successfully. SDK should update state to `connected`.

### `disconnect`
Socket disconnected. Reason provided. SDK should attempt reconnection.

Reasons:
- `io server disconnect` - Server closed connection
- `io client disconnect` - Client closed connection
- `ping timeout` - No response to ping
- `transport close` - Transport error

### `connect_error`
Connection failed. SDK should retry with exponential backoff.

### `reconnect`
Successfully reconnected after disconnect.

---

## SDK Implementation Checklist

### Required Events (Listen)

- [ ] `receive_audio` - Queue audio, extract animation metadata
- [ ] `receive_frame_images_batch` - Decode frames, add to playback queue
- [ ] `chunk_images_ready` - Mark chunk as ready for playback
- [ ] `audio_end` - Transition to idle after current audio
- [ ] `play_base_animation` - Queue transition/idle animation
- [ ] `connect` - Update connection state
- [ ] `disconnect` - Trigger reconnection
- [ ] `connect_error` - Handle connection failure

### Required Events (Emit)

- [ ] Connection with query parameters
- [ ] `user_full_audio` (if voice input supported)

### Reconnection Strategy

```
Attempt 1: Wait 1 second
Attempt 2: Wait 2 seconds
Attempt 3: Wait 4 seconds
Attempt 4: Wait 8 seconds
Attempt 5: Wait 16 seconds
Attempt 6+: Wait 30 seconds (max)

After 10 failures: Surface error to user
```

---

## Data Formats

### Audio
- Format: MP3
- Sample rate: 44.1kHz
- Bitrate: 128kbps
- Encoding: Base64

### Images
- Format: WebP (preferred), PNG, JPEG
- Resolution: Matches `userResolution` parameter
- Encoding: Base64

### Timestamps
- Server: ISO 8601 string `"2026-01-21 15:30:45.123"`
- Client: Unix milliseconds `1705859445123`
