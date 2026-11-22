#if AXE_MIRROR
import CoreGraphics
import Foundation

// The host's clock and its log line. The wire format itself, which the host and the viewer app
// must agree on, is in `Shared/MirrorWireFormat.swift`, compiled into both.

func mirrorNow() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
/// Writes a log line. A write that fails, as to a terminal that has been closed, is dropped: the
/// non-throwing `write(_:)` would stop the host with an exception.
func mirrorNote(_ text: String) { try? FileHandle.standardError.write(contentsOf: Data((text + "\n").utf8)) }
#endif
