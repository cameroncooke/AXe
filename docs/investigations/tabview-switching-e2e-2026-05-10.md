# Investigation: SwiftUI TabView E2E Switching

## Summary
Selector-based switching for the standard SwiftUI `TabView` fixture is now unblocked by setting the outgoing CoreSimulator accessibility request's `AXPTranslatorRequest.clientType` to `2` in the host-side FBSimulatorControl translation delegate.

The earlier clean path sent requests with `clientType=0`, which exposed the tab bar as one leaf `AXGroup` labeled `Tab Bar`. A focused client-type probe showed that forcing the serialized request `clientType` to `2` makes the simulator-side AccessibilityPlatformTranslation path expose real SwiftUI tab item elements:

- `Home`, `type='RadioButton'`, with a real frame
- `Settings`, `type='RadioButton'`, with a real frame
- parent `Tab Bar`, `type='Group'`, now with the tab item children

This is a real metadata fix, not coordinate segmentation and not synthetic tab creation.

## Goal
Prove whether AXe can expose and tap individual standard SwiftUI `TabView` tab items through discovered accessibility metadata, without XCTest, WDA, a test-runner host app, or coordinate segmentation heuristics.

Completion required one of these outcomes:

1. `axe describe-ui` shows `Home` and `Settings` tab item elements with real labels, types, and frames, and selector-based `tap` switches tabs.
2. The report contains concrete reverse-engineered evidence for the blocker, including the private request paths and constants attempted.

This investigation reached outcome 1.

## Current Fixture
The `tab-view-test` playground route renders a standard SwiftUI `TabView` with:

- `Home` tab
- `Settings` tab
- visible state label: `Current Tab: Home` / `Current Tab: Settings`
- content marker: `Home panel active` / `Settings panel active`

The route is valid: launching `screen=tab-view-test` renders `Current Tab: Home`.

## Final `describe-ui` Evidence
Captured after removing temporary instrumentation, applying the production `clientType=2` request patch, rebuilding the vendored frameworks, and launching the fixture on simulator `A2C64636-37E9-4B68-B872-E7F0A82A5670` / iPhone 17 Pro.

Command shape:

```sh
UDID=${SIMULATOR_UDID:-A2C64636-37E9-4B68-B872-E7F0A82A5670}
AXE_BIN="$(swift build --show-bin-path)/axe"
xcrun simctl terminate "$UDID" com.cameroncooke.AxePlayground || true
xcrun simctl launch "$UDID" com.cameroncooke.AxePlayground --launch-arg "screen=tab-view-test"
"$AXE_BIN" describe-ui --udid "$UDID" > /tmp/axe-tabview-final-client2.json
```

Observed accessibility tree summary from the focused client-type capture:

```text
('Tab Bar', 'Group', frame={x:0,y:790.9999999999999,width:402,height:83}, children=1)
('Home', 'RadioButton', frame={x:111,y:794.9999999999999,width:94,height:54}, children=0)
('Settings', 'RadioButton', frame={x:197,y:794.9999999999999,width:94,height:54}, children=0)
Home tab element matches: 1
Settings tab element matches: 1
```

The important difference was not a serializer change. The same `AXPMacPlatformElement.accessibilityChildren` walk returned real children once the CoreSimulator request carried `AXPTranslatorRequest.clientType=2` into the simulator-side AccessibilityPlatformTranslation service.

## Vendored Serializer Baseline
Primary file inspected and temporarily patched during the probe:

- `idb_checkout/FBSimulatorControl/Commands/FBSimulatorAccessibilityCommands.m`

Baseline behavior:

- Flat serialization walks `element.accessibilityChildren`.
- Nested serialization recursively walks `element.accessibilityChildren`.
- For this SwiftUI `TabView`, the `Tab Bar` element has no serialized children.

Relevant private API surface inspected:

- `idb_checkout/PrivateHeaders/AccessibilityPlatformTranslation/AXPMacPlatformElement.h`
- `idb_checkout/PrivateHeaders/AccessibilityPlatformTranslation/AXPTranslationObject.h`
- `idb_checkout/PrivateHeaders/AccessibilityPlatformTranslation/AXPTranslator.h`
- `idb_checkout/PrivateHeaders/AccessibilityPlatformTranslation/AXPTranslatorRequest.h`
- `idb_checkout/PrivateHeaders/AccessibilityPlatformTranslation/AXPTranslatorResponse.h`
- `idb_checkout/PrivateHeaders/AccessibilityPlatformTranslation/AXPTranslator_iOS.h`
- `idb_checkout/PrivateHeaders/CoreSimulator/SimDevice.h`

`AXPMacPlatformElement` supports generic attribute access through methods such as `accessibilityAttributeValue:`, `accessibilityMultipleAttributes:`, `accessibilityAttributeNames`, and `accessibilityParameterizedAttributeNames`.

## Lower-Level AccessibilityPlatformTranslation Evidence
The repo-visible headers do not publish the request or attribute constants, so the investigation moved to dyld-cache disassembly, Objective-C runtime probes, and temporary FBSimulatorControl instrumentation.

### Binary and symbol commands

```sh
xcrun dyld_info -exports /System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/Versions/A/AccessibilityPlatformTranslation
xcrun dyld_info -disassemble /System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/Versions/A/AccessibilityPlatformTranslation > /tmp/axe_apt_disasm.txt
nm -m /Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator | grep -i 'sendAccessibilityRequest\|accessibilityRequest\|Accessibility'
strings /Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator | grep -i 'sendAccessibilityRequest\|accessibilityRequest\|Accessibility'
xcrun dyld_info -objc /Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator | grep -i 'sendAccessibilityRequest\|accessibilityRequest\|Accessibility'
```

Relevant symbols found:

```text
_OBJC_CLASS_$_AXPMacPlatformElement
_OBJC_CLASS_$_AXPTranslationObject
_OBJC_CLASS_$_AXPTranslator
_OBJC_CLASS_$_AXPTranslatorRequest
_OBJC_CLASS_$_AXPTranslatorResponse
-[AXPTranslator_iOS attributeFromRequest:]
-[AXPTranslator_iOS _processChildrenAttributeRequest:error:]
-[AXPTranslator_iOS _processRawElementDataRequest:error:]
-[AXPTranslator_iOS processAttributeRequest:]
-[AXPMacPlatformElement _attributeTypeForMacAttribute:]
-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]
-[SimDevice accessibilityPlatformTranslationToken]
com.apple.CoreSimulator.accessibility
SimAccessibility_PayloadClassName
SimAccessibility_Payload
```

Disassembly findings:

- `-[AXPTranslator_iOS attributeFromRequest:]` accepts attribute IDs through `0x81` / `129` before falling out to no direct attribute.
- `-[AXPTranslator_iOS processAttributeRequest:]` first checks special cases, then calls `attributeFromRequest:`, then the direct attribute path.
- `-[AXPTranslator_iOS _processChildrenAttributeRequest:error:]` is the concrete path for child requests.
- `-[AXPTranslator_iOS _processRawElementDataRequest:error:]` is the concrete path for raw element token requests.
- `AXPMacPlatformElement` creates translator requests with `requestWithTranslation:`, sets `requestType`, sets `attributeType`, and sends them via `AXPTranslator.sharedInstance sendTranslatorRequest:`.
- Normal attribute requests use `requestType=2`.
- Multiple attribute requests use `requestType=5` and the `_AXPParametersDictAttributesKey` parameter.
- Application object requests use `requestType=1`.
- Action requests use `requestType=7`.
- CoreSimulator owns `-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]`, which is the host-to-simulator request transport used behind this translation layer.

### Runtime constant derivation

A local Objective-C runtime probe called `AXPMacPlatformElement.applicationElement` and `_attributeTypeForMacAttribute:`.

Important Mac attribute mappings:

| Mac attribute string | AXP attribute ID |
| --- | ---: |
| `AXChildren` | `8` / `0x08` |
| `AXChildrenInNavigationOrder` | `9` / `0x09` |
| `AXSelectedChildren` | `81` / `0x51` |
| `AXRole` | `45` |
| `AXRoleDescription` | `46` |
| `AXSubrole` | `51` |
| `AXDescription` / label | `33` |
| `AXValue` | `53` |
| `AXFrame` | `21` |
| `AXIdentifier` | `25` |
| `AXEnabled` | `27` |

Strings such as `AXTabs`, `AXContents`, `AXRows`, `AXColumns`, `AXVisibleChildren`, and `AXRawElementData` mapped to `0`, so they are not accepted Mac-side attribute names for this bridge.

A second runtime probe used the exported `_AXPAttributeToString` plus `_macAttributeTypeForAXPAttribute:`. `_attributeTypeForMacAttribute:@"AXChildren"` had to be called first to initialize the internal mapping.

Important AXP enum names:

| AXP attribute ID | AXP name | Mac bridge name |
| ---: | --- | --- |
| `8` | `AXPAttributeChildren` | `AXChildren` |
| `9` | `AXPAttributeChildrenInNavigationOrder` | `AXChildrenInNavigationOrder` |
| `18` | `AXPAttributeFirstContainedElement` | none returned |
| `34` | `AXPAttributeLastContainedElement` | none returned |
| `37` | `AXPAttributeNextContentSibling` | none returned |
| `44` | `AXPAttributePreviousContentSibling` | none returned |
| `58` | `AXPAttributeVisibleOpaqueElements` | none returned |
| `60` | `AXPAttributeRawElementData` | `AXDeviceElementToken` |
| `76` | `AXPAttributeLinkedUIElements` | `AXLinkedUIElements` |
| `79` | `AXPAttributeWindowSections` | none returned |
| `81` | `AXPAttributeSelectedChildren` | `AXSelectedChildren` |
| `85` | `AXPAttributeFirstElementForFocus` | none returned |
| `113` | `AXPAttributeElementsForSearchParameters` | none returned |
| `128` | `AXPAttributeMemoryAddress` | none returned |

Key finding: raw element data is requested through AXP attribute `60` and appears on the Mac bridge as `AXDeviceElementToken`, not as a Mac attribute named `AXRawElementData`.

## Temporary FBSimulatorControl Direct Request Probe
I temporarily instrumented `FBSimulatorAccessibilityCommands.m` only around the element labeled `Tab Bar`. The instrumentation was removed before the final rebuild.

The probe collected:

- `accessibilityAttributeNames`
- `accessibilityParameterizedAttributeNames`
- selected `accessibilityAttributeValue:` results
- direct `AXPTranslatorRequest` results with `requestType=2`
- `AXPTranslatorResponse.responseObject`
- `AXPTranslatorResponse.translationResponse`
- `AXPTranslatorResponse.translationsResponse`
- `AXPTranslatorResponse.errorCode`

The direct request path used runtime class lookup to avoid hard-linking private classes:

```objc
Class requestClass = objc_getClass("AXPTranslatorRequest");
Class translatorClass = objc_getClass("AXPTranslator");
id request = [requestClass requestWithTranslation:element.translation];
[request setRequestType:2];
[request setAttributeType:attributeID];
id response = [[translatorClass sharedInstance] sendTranslatorRequest:request];
```

Important build finding:

- Referencing private classes directly, such as `AXPTranslatorRequest` or `AXPMacPlatformElement.class`, caused architecture-specific undefined symbol failures.
- `objc_getClass("AXPTranslatorRequest")`, `objc_getClass("AXPTranslator")`, and `objc_getClass("AXPMacPlatformElement")` avoided direct symbol references and allowed the temporary probe to build.

### Tab Bar attributes exposed by the bridge

`Tab Bar` returned these attribute names:

```text
AXChildren
AXChildrenInNavigationOrder
AXCustomContent
AXDescription
AXEnabled
AXFocused
AXHelp
AXLanguage
AXParent
AXPosition
AXRole
AXRoleDescription
AXSelected
AXLinkedUIElements
AXSize
AXSubrole
AXTopLevelUIElement
AXUserInputLabels
AXValue
AXWindow
AXIdentifier
```

`accessibilityParameterizedAttributeNames` returned an empty array.

Important Mac attribute values:

| Attribute | Result |
| --- | --- |
| `AXChildren` | empty array |
| `AXChildrenInNavigationOrder` | empty array |
| `AXSelectedChildren` | nil |
| `_AXVisibleOpaqueElements` | nil |
| `AXDeviceElementToken` | dictionary with `TokenType` and `ElementData` |
| `AXTraits` | `8589934592` |
| `AXSections` | nil |
| `AXLinkedUIElements` | nil |
| `AXFirstContainedElement` | nil |
| `AXLastContainedElement` | nil |
| `AXNextContentSibling` | nil |
| `AXPreviousContentSibling` | nil |
| `AXUIElementsForSearchPredicate` | nil |
| `_AXFirstFocusedElement` | nil |

### Direct AXP request results for `Tab Bar`

All requests used `AXPTranslatorRequest.requestType=2` against the `Tab Bar` translation object.

| AXP attr | Name | Result | Error code | Translation objects |
| ---: | --- | --- | ---: | --- |
| `8` | children | `NSArray[0]` | `0` | `NSArray[0]` |
| `9` | children in navigation order | `NSArray[0]` | `0` | empty/nil |
| `18` | first contained element | nil | `18446744073709526411` | nil |
| `34` | last contained element | nil | `18446744073709526411` | nil |
| `37` | next content sibling | nil | `18446744073709526411` | nil |
| `44` | previous content sibling | nil | `18446744073709526411` | nil |
| `58` | visible opaque elements | nil | `18446744073709526411` | nil |
| `60` | raw element data | token dictionary | `0` | nil |
| `76` | linked UI elements | nil | `18446744073709526411` | nil |
| `79` | window sections | nil | `0` | nil |
| `81` | selected children | nil | `0` | nil |
| `85` | first element for focus | nil | `18446744073709526411` | nil |
| `113` | elements for search parameters | nil | `0` | nil |
| `128` | memory address | string-like pointer | `0` | nil |

Raw element data returned only the simulator element token payload:

```text
{
  TokenType = AXElementTokenSimulator;
  ElementData = {length = 20, bytes = 0xe8a6000080f98905010000000900000000000000};
}
```

That payload is useful for a deeper protocol investigation, but it does not contain tab labels, frames, types, or child translation objects at this layer.

## Raw Token / CoreSimulator XPC Follow-up
Follow-up reverse engineering on Xcode 26.4 (`17E192`) and the iOS 26.4 simulator runtime did not find a bypass that exposes real `Home` / `Settings` tab item elements.

### Raw `AXElementTokenSimulator` payload

Inspected binary:

```text
/Library/Developer/CoreSimulator/Volumes/iOS_23E244/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.4.simruntime/Contents/Resources/RuntimeRoot/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation
```

Relevant symbols:

```text
-[AXPTranslator_iOS _processRawElementDataRequest:error:]
-[AXPTranslator_iOS translationObjectFromData:]
-[AXPTranslator_iOS remoteTranslationDataWithTranslation:pid:]
__AXUIElementCreateData
__AXUIElementCreateWithData
__AXUIElementIDForElement
__AXUIElementCreateWithPIDAndID
```

Disassembly evidence:

- `_processRawElementDataRequest:error:` calls `axElement`, then `__AXUIElementCreateData`, then returns a two-key dictionary: `TokenType = AXElementTokenSimulator` and `ElementData = <NSData>`. It does not request descendants or attach attribute data.
- `translationObjectFromData:` is the inverse: it calls `__AXUIElementCreateWithData`, then `translationObjectFromPlatformElement:`. This can rehydrate an `AXUIElement` token into the normal translation path, but it does not introduce a new child enumeration source.
- `remoteTranslationDataWithTranslation:pid:` only rewrites a remote element PID when `__AXUIElementIDForElement` returns the remote-element sentinel shape, then serializes the element again with `__AXUIElementCreateData`. That is PID remapping, not tab-item discovery.

The observed 20-byte `ElementData` decodes as little-endian chunks:

```text
bytes: e8 a6 00 00 80 f9 89 05 01 00 00 00 09 00 00 00 00 00 00 00
u32@0  = 42728 / 0xa6e8
u64@4  = 4387895680 / 0x10589f980
u32@12 = 9 / 0x9
u32@16 = 0 / 0x0
```

This looks like an opaque AXRuntime element token containing process/element identity fields. It has no room for, and does not contain, tab labels, frames, roles, or child references. The only supported use visible in `AccessibilityPlatformTranslation` is rehydrating the same `AXUIElement` with `__AXUIElementCreateWithData`.

### CoreSimulator accessibility XPC path

Inspected binaries:

```text
/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/CoreSimulator
/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/Platforms/iphoneos/usr/libexec/CoreSimulatorBridge
```

Relevant host-side methods:

```text
-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]
+[SimDevice _xpcMessageWithAXRequest:]
+[SimDevice _axResponseFromXPCMessage:]
-[SimDevice accessibilityPlatformTranslationToken]
-[SimDevice accessibilityConnection]
```

Relevant simulator-side methods:

```text
-[CSBAccessibilityBridgeManager start]
+[CSBAccessibilityBridgeManager _responseMessageFromRequestMessage:]
+[CSBAccessibilityBridgeManager _axRequestFromXPCMessage:]
+[CSBAccessibilityBridgeManager _xpcMessageWithAXResponse:requestMessage:]
```

Transport shape:

1. Host looks up Mach service `com.apple.CoreSimulator.accessibility`.
2. Host builds an XPC dictionary with `SimAccessibility_PayloadClassName = NSStringFromClass(AXPTranslatorRequest)`.
3. Host archives the `AXPTranslatorRequest` with secure coding and stores it as data under nested key `translatorRequest` inside `SimAccessibility_Payload`.
4. `CoreSimulatorBridge` accepts only that request class shape, unarchives the `AXPTranslatorRequest`, and calls `[[AXPTranslator sharedInstance] processTranslatorRequest:request]` inside the simulator.
5. The bridge archives the resulting `AXPTranslatorResponse` under nested key `translatorResponse` and sends it back with `SimAccessibility_PayloadClassName = NSStringFromClass(AXPTranslatorResponse)`.
6. Host accepts only `AXPTranslatorResponse` from `_axResponseFromXPCMessage:`.

That means the CoreSimulator XPC layer is not a richer accessibility API. It is a narrow secure-coding carrier for the same `AXPTranslatorRequest` / `AXPTranslatorResponse` path already exercised by the direct request probe. Sending a different payload class would fail the class-name/unarchive checks unless `CoreSimulatorBridge` itself were changed, which is outside a maintainable AXe patch.

### Request surface still available below this point

`AXPTranslator processTranslatorRequest:` dispatches request types `1...11`; cache-aware request handling only covers request types `2`, `3`, `4`, `5`, `9`, and `10` (`shouldCheckTreeDumpCacheForRequestType:` mask `0x63c`). The normal request types used by AXe are already covered:

- `requestType=2`: single attribute request
- `requestType=5`: multiple attribute request
- `requestType=1`: application object request
- `requestType=7`: action request

The remaining interesting private surface is the AX tree-dump / cached-tree path:

```text
-[AXPTranslator_iOS setRequestResolvingBehavior:]
-[AXPTranslator_iOS generateAXTreeDumpTypeOnBackgroundThread:completionHandler:]
-[AXPTranslator_iOS _frontmostAppChildrenForXCTest]
-[AXPTranslator_iOS axTreeDumpGenerateNextSetOfElementAttrsOnMainThread]
-[AXPTranslator processPlatformAXTreeDump:]
-[AXPTranslator checkTreeDumpCacheForRequest:]
```

This is not the same as decoding `AXElementTokenSimulator`. It appears to be an alternate in-simulator AX tree cache used by Apple clients such as Oneness / XCTest-style tree dumping. It was probed as the next focused metadata path.

## AX Tree-Dump / Cache Follow-up

A temporary FBSimulatorControl probe was added at the existing CoreSimulator translation hook, after `frontmostApplicationWithDisplayId:bridgeDelegateToken:` returned an `AXPTranslationObject` and after the bridge token was installed. The probe was removed before the final clean rebuild.

Inspected binaries:

```text
/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/Versions/A/AccessibilityPlatformTranslation
/Library/Developer/CoreSimulator/Volumes/iOS_23E244/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.4.simruntime/Contents/Resources/RuntimeRoot/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation
```

Relevant symbols and entry points found by strings, `nm -m`, `xcrun dyld_info -objc`, and disassembly:

```text
-[AXPTranslator_iOS setRequestResolvingBehavior:]
-[AXPTranslator_iOS generateAXTreeDumpTypeOnBackgroundThread:completionHandler:]
-[AXPTranslator_iOS fetchNextSetOfElementAttrsOnBackgroundThreadWithEarlyTermination:]
-[AXPTranslator_iOS _frontmostAppChildrenForXCTest]
-[AXPTranslator_iOS axTreeDumpGenerateNextSetOfElementAttrsOnMainThread]
-[AXPTranslator_iOS processPlatformAXTreeDump:]
-[AXPTranslator processPlatformAXTreeDump:]
-[AXPTranslator checkTreeDumpCacheForRequest:]
-[AXPTranslator treeDumpResponseCacheForBridgeDelegateToken:]
-[AXPTranslator processAXTreeElements:]
-[AXPRemoteCacheManager initWithCachedTreeClientType:]
-[AXPRemoteCacheManager start]
-[AXPRemoteCacheManager _sendAXHierachyOnBackgroundQueue]
-[AXPRemoteCacheManager axInitialTreeDumpGeneratedOnBackgroundThreadCallback:success:]
_AXRequestingClient
_AXOverrideRequestingClientType
AXPTreeDumpTypeInitialDump
AXPTreeDumpTypeAdditionalData
AXPTreeDumpTypeTreeDestroyed
```

Disassembly findings:

- `AXPRemoteCacheManager.start` sets `[AXPTranslator sharedInstance] setRequestResolvingBehavior:2` and `setCachedTreeClientType:`.
- `AXPRemoteCacheManager._sendAXHierachyOnBackgroundQueue` calls `[AXPTranslator sharediOSInstance] generateAXTreeDumpTypeOnBackgroundThread:@"AXPTreeDumpTypeInitialDump" completionHandler:...]`.
- `generateAXTreeDumpTypeOnBackgroundThread:completionHandler:` expects to run on `axTreeDumpSharedBackgroundQueue` (`com.apple.accessibility.AXPRemoteCacheManager.axHierarchyGeneration`).
- The tree generator references `AXRequestingClient`; when that client is `2`, it can call `_frontmostAppChildrenForXCTest`.
- `_frontmostAppChildrenForXCTest` reads AX attribute `0x1389` from the frontmost app and converts each returned `AXUIElement` into an `AXPTranslationObject`.
- `AXPTranslatorResponse.treeDumpType` reads `resultData[@"treeDumpType"]`.
- `AXPTranslatorResponse.treeDumpResponse` reads `resultData[@"treeDump"]`.

Runtime probe values from AXe/FBSimulatorControl, with the fixture launched to `screen=tab-view-test`:

```text
translator class=AXPTranslator
responds setRequestResolvingBehavior=1
responds generateAXTreeDump=1
responds processPlatformAXTreeDump=1
responds checkTreeDumpCache=1
sharedIOS=<AXPTranslator_iOS ...>
sharedIOS responds _frontmostAppChildrenForXCTest=1
sharedIOS responds axTreeDumpSharedBackgroundQueue=1
sharedIOS responds generateAXTreeDump=1
```

Request/cache knobs attempted:

```text
-[AXPTranslator setRequestResolvingBehavior:] = 2
-[AXPTranslator setCachedTreeClientType:] = 2
-[AXPTranslator_iOS setRequestResolvingBehavior:] = 2
-[AXPTranslator_iOS setCachedTreeClientType:] = 2
AXOverrideRequestingClientType(2): symbol available, AXRequestingClient before=0 after=0
```

Direct request attempts through `-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]`:

| Request | Client type | Response | Notes |
| --- | ---: | --- | --- |
| `requestType=11`, `attributeType=0` | `0` | nil | No `treeDump`, no matches |
| `requestType=11`, `attributeType=0` | `2` | nil | No `treeDump`, no matches |
| `requestType=11`, `attributeType=0` | `16` | timeout in the first probe | Dropped from later probes to avoid blocking |

Private method outputs:

```text
_frontmostAppChildrenForXCTest output=NSArray(count=0, first=<nil>)
Home matches: 0
Settings matches: 0
Tab Bar matches: 0
```

Calling `generateAXTreeDumpTypeOnBackgroundThread:completionHandler:` on `axTreeDumpSharedBackgroundQueue` did complete once the temporary probe used the correct private completion signature, which is `(BOOL success, AXPTranslatorResponse *response)`.

Observed completion:

```text
generateAXTreeDump completion success=1
treeDumpType=AXPTreeDumpTypeInitialDump
treeDump=NSArray(count=2)
```

Observed tree-dump payload:

```text
AXPTranslatorResponse associatedRequestType=11
resultData keys=(treeDump, treeDumpType)
treeDump[0] associatedRequestType=4, attribute=AXPAttributeUndefined, associatedTranslationObj=(null)
treeDump[1] associatedRequestType=2, attribute=AXPAttributeApplicationOrientation, associatedTranslationObj=(null)
treeDumpResponseCacheForBridgeDelegateToken(token) = nil
Home matches: 0
Settings matches: 0
Tab Bar matches: 0
```

The first generator probe briefly crashed because the temporary completion block used `(AXPTranslatorResponse *, BOOL)`. The crash report confirmed APT invoked the block as `(BOOL, AXPTranslatorResponse *)`, causing the probe to retain pointer `0x1` as an object. After correcting the temporary probe, the generator completed successfully but still returned only the two response objects above.

Conclusion: AXe can reach the private tree-dump entry point from the host-side FBSimulatorControl path, but this does not expose SwiftUI `TabView` tab item elements. The in-process tree generator returned no real `Home` / `Settings` labels, frames, roles, or translation objects, and the bridge-token cache stayed empty. No serializer/fetch patch was kept.

## AXRuntime Client-Type Follow-up

The final lower-level target was host-side AXRuntime client gating around `AXRequestingClient`, `AXOverrideRequestingClientType`, and CoreSimulator's serialized `AXPTranslatorRequest` path.

### Host AXRuntime behavior

A small host probe loaded AXRuntime from the dyld shared cache and called the available client APIs:

```text
initial: AXRequestingClient=0, _AXRequestingClientForSelfMachMessage=7
after AXOverrideRequestingClientType(2): AXRequestingClient=0, _AXRequestingClientForSelfMachMessage=2
after _AXSetRequestingClient(2): AXRequestingClient=2, _AXRequestingClientForSelfMachMessage=2
after _AXSetRequestingClient(0): AXRequestingClient=0, _AXRequestingClientForSelfMachMessage=2
```

Disassembly matched those results:

- `AXOverrideRequestingClientType` writes the self-Mach-message override global.
- `AXRequestingClient` reads a different requesting-client global.
- `_AXSetRequestingClient` writes the `AXRequestingClient` global.

So `AXOverrideRequestingClientType(2)` leaving `AXRequestingClient` at `0` in the AXe host process is expected. It changes the client used for messages sent as this process, not the plain host getter.

### Why host `_AXSetRequestingClient(2)` was not enough

`AXPTranslatorRequest.requestWithTranslation:` sets `request.clientType` from AccessibilityPlatformTranslation's current-request client conversion, not from AXe's later CoreSimulator send call. A standalone host probe showed the request stayed at `clientType=0` even after both host calls:

```text
AXOverrideRequestingClientType(2)
_AXSetRequestingClient(2)
AXPTranslatorRequest.requestWithTranslation:nil -> clientType=0
```

That means mutating AXRuntime globals in the AXe host process does not reliably mutate the `clientType` serialized to CoreSimulator.

### What actually gates simulator-side results

`AXPTranslatorRequest` securely encodes `clientType`, and CoreSimulator carries that request across XPC to `CoreSimulatorBridge`. Simulator-side AccessibilityPlatformTranslation decodes the same request and uses `request.clientType` while processing attribute, multiple-attribute, and action requests. Disassembly showed simulator-side request processors reading `request.clientType` and calling `AXOverrideRequestingClientType(...)` before resolving attributes.

A temporary FBSimulatorControl probe forced outgoing requests to `clientType=2` immediately before `-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]`. One focused capture then exposed real SwiftUI tab item metadata:

```text
AXE_PROBE forcing requestType=... clientType=2
Home exact matches: 1
Settings exact matches: 1
Home type: RadioButton
Settings type: RadioButton
```

After that proof, the temporary env gate and probe logging were removed. The kept patch sets `request.clientType = 2` unconditionally in the CoreSimulator accessibility translation delegate.

## Root Cause
The selector blocker was not AXe's Swift target resolver and not a missing serializer fallback. It was the host-to-simulator request client type.

With `AXPTranslatorRequest.clientType=0`, simulator-side AccessibilityPlatformTranslation resolves the standard SwiftUI `TabView` tab bar as a leaf `AXGroup`. With `clientType=2`, the same CoreSimulator bridge path resolves real tab item children with labels, roles, and frames.

The practical cause is that AXe's vendored FBSimulatorControl path was forwarding whatever `AXPTranslatorRequest.requestWithTranslation:` produced in the host process. In this AXe host context, that value stayed at `0`; the XCTest-style client behavior only appeared after setting `request.clientType=2` on the outgoing request before CoreSimulator serialized it.

## Decisions
- Set `AXPTranslatorRequest.clientType=2` in the FBSimulatorControl CoreSimulator accessibility translation delegate.
- Did not change `AccessibilityTargetResolver`; it can now consume real tab item metadata.
- Replaced the temporary coordinate TabView E2E with a selector-based `tap --label Settings --element-type RadioButton` test.
- Normalized scalar AX fields in the production and test decoders so numeric `AXValue` from the newly exposed tab radio buttons does not break selector resolution.
- Removed all temporary probe logging, environment gates, and AXRuntime/tree-dump instrumentation.
- Did not use XCTest, WDA, a test-runner host app, coordinate segmentation, or synthetic tab elements.

## Checks and Commands Run
Passed after the production patch and probe removal:

```sh
./scripts/build.sh frameworks
./scripts/build.sh install
./scripts/build.sh strip
./scripts/build.sh xcframeworks
./scripts/build.sh verify-xcframeworks
swift build
./test-runner.sh TapTests
AXE_E2E=1 SIMULATOR_UDID=A2C64636-37E9-4B68-B872-E7F0A82A5670 swift test --filter DescribeUITests
swift test
```

Focused `describe-ui` capture after removing probe instrumentation and using the kept `clientType=2` patch:

```text
elements: 100
Home tab element matches: 2
Settings tab element matches: 2
Home type: RadioButton, AXValue: 1
Settings type: RadioButton, AXValue: 0
```

Regression coverage added:

- `TapTests.selectorTapSwitchesSwiftUITabViewTab` verifies that `describe-ui` exposes `Home` and `Settings` as `RadioButton` elements, then taps `Settings` with `--label Settings --element-type RadioButton` and waits for `Current Tab: Settings`.
- The production and test accessibility decoders now accept scalar AX string fields as strings, numbers, or booleans; this is required because the newly exposed tab radio buttons return numeric selected-state `AXValue` values.

## Next Lower-Level Target
No lower-level host-side avenue remains for this specific TabView selector blocker. The client-gating path produced real metadata and the patch is intentionally small.

Future work, if this regresses on another Xcode/iOS runtime, should start by verifying the AXP client mapping for `clientType=2` on that runtime and checking whether simulator-side AccessibilityPlatformTranslation still applies it before child/attribute resolution. Do not reintroduce coordinate segmentation unless the product explicitly chooses a best-effort fallback with clear UX tradeoffs.
