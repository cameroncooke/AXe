# Device protocol notes

AXe's record of the wire formats it uses to reach a physical device. The Phase 1 wire notes use local
research captures, which are not checked into the repository. The captures were taken on 2026-11-09
from an iPhone 16 Pro Max on iOS 27.2 over the local network, with CoreDevice 689.2 on the Mac.

## Reaching the device

The Mac's CoreDevice (`remotepairingd`) keeps an IPv6 point-to-point tunnel (`utun`) to each connected
device. Any local process can open TCP connections through it; AXe never creates its own tunnel.

1. **Tunnel address.** `xcrun devicectl device info details --device <udid> -q -j <file>`. Device end:
   `result.properties.connection.tunnelIPAddressString`, or the older
   `result.connectionProperties.tunnelIPAddress`. The Mac's end is the same `/64` prefix with host part
   `::2`. The address changes when the phone restarts.
2. **RSD port.** macOS `remoted` keeps an ESTABLISHED TCP connection to the device's service directory
   (RSD). `netstat -anv -p tcp`: the foreign port of a `remoted` socket whose foreign address starts
   with the tunnel prefix. Fallback: the last `server port N` in `remotepairingd`'s unified log for that
   address.
3. **RSD session.** Connect to `[tunnel]:port` and speak RemoteXPC. After the handshake the device sends
   one dictionary: `MessageType: "Handshake"`, `MessagingProtocolVersion` (7), `Services`
   (name -> `Port` string, `Entitlement`, `Properties` with `UsesRemoteXPC`, `Features`,
   `ServiceVersion`), `Properties` (`UniqueDeviceID`, `ProductType`, `OSVersion`, ...), `UUID`.
4. **Target identity.** Check the handshake's `Properties.UniqueDeviceID` against the hardware UDID
   before opening a service. Keep the RSD session open while using its advertised ports.

## RemoteXPC transport

HTTP/2 over the TCP connection, no TLS, no HPACK header content.

Client sends, in order:

1. Preface `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`.
2. SETTINGS: `MAX_CONCURRENT_STREAMS (3) = 100`, `INITIAL_WINDOW_SIZE (4) = 16777216`.
3. WINDOW_UPDATE on stream 0, increment `16711681`.
4. HEADERS on stream 1, flags `END_HEADERS (0x4)`, empty block.
5. DATA on stream 1: wrapper flags `0x1`, message id 0, body = empty dictionary.
6. HEADERS on stream 3, flags `0x4`, empty block.
7. DATA on stream 1: wrapper flags `0x201`, id 0, no body.
8. DATA on stream 3: wrapper flags `0x400001`, id 0, no body.
9. SETTINGS ACK once the server's SETTINGS arrive.

The captured RSD service directory arrives on stream 1 with wrapper flags `0x101` and message ID 2.

The device answers with its own SETTINGS (`MAX_CONCURRENT_STREAMS = 100`,
`INITIAL_WINDOW_SIZE = 1048576`), WINDOW_UPDATE (`983041`), SETTINGS ACK, and mirrors steps 4-8.

Requests: DATA on stream 1, wrapper flags `0x10101` (always + data present + wants reply), message id
counting up from 1. Replies: DATA on stream 3, flags `0x20101` (always + data present + reply), same
message id. Large replies span several DATA frames; reassemble by the wrapper's body length and send
WINDOW_UPDATEs to keep the window open (a 6.6 MB screenshot arrives this way).

### Wrapper (little-endian)

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | magic `0x29B00B92` |
| 4 | 4 | flags |
| 8 | 8 | body length |
| 16 | 8 | message id |
| 24 | n | body: magic `0x42133742`, version `5`, then one object |

### Objects

Each object is a 4-byte little-endian type tag followed by its payload; payloads are padded to 4 bytes.

| Tag | Type | Payload |
| --- | --- | --- |
| `0x1000` | null | none |
| `0x2000` | bool | u32 0 or 1 |
| `0x3000` | int64 | 8 bytes |
| `0x4000` | uint64 | 8 bytes |
| `0x5000` | double | 8 bytes |
| `0x7000` | date | int64 nanoseconds since 1970 |
| `0x8000` | data | u32 length, bytes, pad |
| `0x9000` | string | u32 length including NUL, UTF-8 bytes, NUL, pad |
| `0xA000` | uuid | 16 bytes |
| `0xE000` | array | u32 byte length (counted after this field), u32 count, objects |
| `0xF000` | dictionary | u32 byte length (counted after this field), u32 count, then per entry: NUL-terminated key padded to 4, object |

An empty dictionary is `00 F0 00 00 | 04 00 00 00 | 00 00 00 00`.

## CoreDevice service requests

Services such as `com.apple.coredevice.screencaptureservice` and `com.apple.coredevice.deviceinfo` take
one request dictionary and answer one reply:

```text
CoreDevice.featureIdentifier       string   e.g. com.apple.coredevice.feature.capturescreenshot
CoreDevice.actionIdentifier        string   e.g. com.apple.coredevice.action.capturescreenshot
CoreDevice.action                  dict     {}
CoreDevice.input                   dict     feature input
CoreDevice.invocationIdentifier    string   new UUID per request
CoreDevice.deviceIdentifier        string   a UUID string
CoreDevice.CoreDeviceDDIProtocolVersion  int64  2
CoreDevice.coreDeviceVersion       dict     components: [uint64], originalComponentsCount: int64, stringValue: string
```

The reply carries `CoreDevice.output`, or an error dictionary.

| Feature | Action | Input | Output |
| --- | --- | --- | --- |
| `...feature.getdisplayinfo` | `...action.displayinfo` | `{}` | `displays[]` (`currentMode.size` pixels, `currentMode.preferredUIScale`, `nativeOrientation`, `currentOrientation` e.g. `rot0`), `orientation` (device orientation; see below) |
| `...feature.capturescreenshot` | `...action.capturescreenshot` | `displayUniqueID: null`, `requestedFormat: "png"` | `image` (PNG data), `imageFormat` |

The interface rotation is `(currentOrientation + nativeOrientation) mod 360`; on an iPhone (native
`rot0`) that is `currentOrientation` alone. `orientation.currentDeviceNonFlatOrientation` does not always
match the interface: an iPhone reports `portraitUpsideDown` while its interface stays in landscape.
On the iPad it matched the interface in every consistent state; see below.

An iPad Pro 11-inch (3rd generation) on iOS 27.2 reported its primary display with `nativeOrientation`
`rot270`, `nativeSize` 2388 × 1668, `currentMode.size` 2778 × 1940 and `preferredUIScale` 2. The UI was
1389 × 970 points in landscape. Its digitizer `pointOne` is normalized to a device-portrait frame: the
mode size with its axes swapped for native `rot270`, here 970 × 1389 points. With physical rotation and
with orientation lock, the interface rotation was `(currentOrientation + nativeOrientation) mod 360`:
portrait `rot90`, camera-right landscape `rot180`, upside down `rot270`, camera-left landscape `rot0`.
After some simulated `OrientationRequest` rotations, `currentOrientation` lagged one step behind the
interface, and the screenshot service sometimes returned sideways images. On the iPad,
`orientation.currentDeviceNonFlatOrientation` followed the interface in every consistent state,
including under orientation lock. AXe compares the two before input on panels whose native
orientation is not `rot0`. The reply's `currentDeviceOrientation` maps to the display the same way
on the iPhone and the iPad: portrait 0, landscapeRight 90, portraitUpsideDown 180,
landscapeLeft 270, measured as interface rotation.

## HID input (`com.apple.coredevice.hid.indigo`)

RemoteXPC requests without a reply, each a dictionary `messageType`, `featureIdentifier`, `payload`:

| messageType | featureIdentifier | payload |
| --- | --- | --- |
| `IndigoDigitizerEvent` | `com.apple.coredevice.feature.remote.hid.digitizer` | `pointOne {x, y}` (0..1, portrait), optional `pointTwo`, `eventType` uint64 0 start / 1 move / 2 end, `edge` uint64, `target` uint64 0 |
| `IndigoKeyboardButtonEvent` | `com.apple.coredevice.feature.remote.hid.keyboard` | `usageCode` uint64 HID usage, `state` uint64 1 down / 2 up |
| `IndigoButtonEvent` | `com.apple.coredevice.feature.remote.hid.button` | `usagePage`, `usageCode`, `state` |

Edge values verified by effect: 1 = left (back), 3 = bottom (home); top swipes work with 0. Buttons:
usage page `0x0C`, home `0x40`, lock `0x30`, siri `0xCF`, volume up `0xE9`, volume down `0xEA`.
Input needed no screen stream on the test phone, including right after a restart. The phone answers
an HTTP/2 PING on the HID connection. AXe waits for the matching ACK after sending the release events
and before closing the connection. This checks receipt of the preceding transport frames. The app
effect still needs a screen check.

## Rotation (`com.apple.coredevice.devicecontrol`)

`featureIdentifier: com.apple.coredevice.feature.remote.devicecontrol.orientation`,
`messageType: OrientationRequest`, `payload: {rotate: {_0: "left" | "right"}}`. The reply reports
`currentDeviceOrientation`, `currentDeviceNonFlatOrientation`, `currentDeviceOrientationLocked`.

## Accessibility (`com.apple.accessibility.axAuditDaemon.remoteAXService`)

Advertised with `UsesRemoteXPC: true` but speaks DTX (first bytes `79 5B 3D 1F`). After the DTX
capability handshake: `clientNeedsAccessibility:` (BOOL) on the control channel makes the device push
`processDataFromRemoteDevice:` messages whose argument is an NSKeyedArchiver `AXPTranslatorResponse`
holding `treeDump` (an array of `AXPTranslatorResponse`) and `treeDumpType`
(`AXPTreeDumpTypeInitialDump`, then `AXPTreeDumpTypeAdditionalData`). Sending NO closes the channel.

A Phase 3 capture confirmed the 32-byte little-endian message header. It contains magic, header size,
16-bit fragment index and count, body size, message identifier, conversation, signed channel and
reply flag. For a fragmented message, fragment zero carries the total size and has no body. The
16-byte payload header gives payload type, auxiliary size and total payload size.

Both peers publish capabilities on channel 0. The host acknowledges reply-bearing calls, including
`hostAPIVersion` and tree pushes, with a type-0 empty reply. AXe sends one subscription again after
2.5 seconds only when no tree push has arrived; a resubscription reset admission between an
InitialDump and a slow AdditionalData and discarded the pair. It validates the root and child graph of each push, then
uses the complete AdditionalData tree. Object IDs can differ between the two pushes.


A Phase 4 probe sent a securely archived translator attribute request as NSData with
`processDataFromHost:`. The empty DTX acknowledgement matched the outbound identifier. A separate
`processDataFromRemoteDevice:` push carried the result and its associated request type, attribute,
PID and object ID. The push has its own DTX identifier. The client sends one request at a time.

A second YES on the same raw connection replayed the previous archive. NO closed that connection.
For fresh reads, the broker replaces the raw DTX channel while keeping its RSD and HID connections.


A physical AXPress uses request type 7, action 5 and client type 2. Its separate push reports
associated request type 7, attribute 0 and a native Boolean, with a null associated translation.
The broker permits this reply only for its single pending action on the exact admitted tree
generation, and requires the exact DTX acknowledgement and fresh Boolean readback.

## Video capture

The screenshot route holds an RSD connection separate from the input broker. It reads the primary
display before and after each PNG and accepts the frame only if the display and orientation agree.
The stream emits the existing JPEG or BGRA formats. The recorder encodes the PNG frames to MP4 with
host capture timestamps and publishes the file after it finishes.

### Native display stream (`com.apple.coredevice.displayservice`)

The native route requests feature `startmediastream` and action `mediastreamstart` over a retained
RemoteXPC connection. The input carries the sender and receiver IPv6 endpoints, a client session
UUID, the primary display ID and a binary property list offer. The offer embeds a zlib-compressed
protobuf capability record. The captured offer for payload type 100 selected HEVC. The AVC-only
offer for payload type 123 selected H.264. The start reply reports both endpoints, payload type,
cipher suites, frame size and frame rate.

The phone sends RTP and RTCP to the same UDP port. The observed H.264 RTP header had an extension
and occupied 20 bytes. H.264 picture data used single NAL units and FU-A fragments. A separate
payload with the device-specific header byte `0x92` contained an `avcC` atom with one length-delimited SPS and PPS. AXe uses those
settings to emit Annex B video. It discards damaged pictures and waits for another complete IDR
after packet loss.

AXe sends compound RTCP receiver reports and SDES to the same confirmed UDP endpoint. The
offer's receiver SSRC must match one of the negotiated SSRCs. Incoming RTP must match the
other. The report includes sequence, loss, jitter and sender timing from the stream.

On the tested Mac, the CoreDevice tunnel route disappeared after about ten seconds despite
active RTP, RTCP and repeated service reads. Read-only `devicectl device info details` calls
about every three seconds kept the same route active. The native command refreshes that route
and checks the identity, address and CoreDevice version on each read.

The start reply and status results identify the session by its client UUID and receiver endpoint.
The tested reply did not include a numeric stop token. AXe closes its own control and UDP
connections, keeps the verified directory and tunnel active, and checks that its session disappears.
The live stream disappeared 19.38 seconds after SIGINT with the negotiated 20-second RTCP timeout.

The tested phone sends one display video stream at a time. A new `mediastreamstart` video
session removes the existing one from status; another client's audio session can stay. Xcode
Device Hub's screen view holds an audio and a video session with one client UUID. After its
video is replaced, it starts a new pair within about 20 seconds, which replaces AXe's. When
packets stop, AXe reads `getmediastreamserverstatus`. If its own session is gone and another
video session is listed, it reports `deviceStreamReplaced`.
