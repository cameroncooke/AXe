# Device protocol notes

AXe's own record of the wire formats it uses to reach a physical device. Each section says how it was
established. Implement from these notes and our captures (`Tests/AXeTests/Fixtures/Device`), not from
other projects' source code. Captures were taken on 2026-11-09 from an iPhone 16 Pro Max on iOS 27.2,
connected over the local network, with CoreDevice 689.2 on the Mac.

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
4. **Service ports exist only while the RSD session is open.** Keep it open for the whole command.

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
| `...feature.getdisplayinfo` | `...action.displayinfo` | `{}` | `displays[]` (`currentMode.size` pixels, `currentMode.preferredUIScale`, `currentOrientation` e.g. `rot0`), `orientation` (sensor, not UI) |
| `...feature.capturescreenshot` | `...action.capturescreenshot` | `displayUniqueID: null`, `requestedFormat: "png"` | `image` (PNG data), `imageFormat` |

Use `displays[].currentOrientation` for the screen's rotation. `orientation.currentDeviceNonFlatOrientation`
is the motion sensor and can read `landscapeLeft` while the screen is portrait.

## HID input (`com.apple.coredevice.hid.indigo`)

RemoteXPC requests without a reply, each a dictionary `messageType`, `featureIdentifier`, `payload`:

| messageType | featureIdentifier | payload |
| --- | --- | --- |
| `IndigoDigitizerEvent` | `com.apple.coredevice.feature.remote.hid.digitizer` | `pointOne {x, y}` (0..1, portrait), optional `pointTwo`, `eventType` uint64 0 start / 1 move / 2 end, `edge` uint64, `target` uint64 0 |
| `IndigoKeyboardButtonEvent` | `com.apple.coredevice.feature.remote.hid.keyboard` | `usageCode` uint64 HID usage, `state` uint64 1 down / 2 up |
| `IndigoButtonEvent` | `com.apple.coredevice.feature.remote.hid.button` | `usagePage`, `usageCode`, `state` |

Edge values verified by effect: 1 = left (back), 3 = bottom (home); top swipes work with 0. Buttons:
usage page `0x0C`, home `0x40`, lock `0x30`, siri `0xCF`, volume up `0xE9`, volume down `0xEA`.
Input needed no screen stream on the test phone, including right after a restart.

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
Details in phase 3.
