#if AXE_MIRROR
import CoreWLAN
import Darwin
import Foundation

/// Watches this Mac's own network link for stalls, by pinging the router at uneven intervals.
///
/// A Mac on Wi-Fi shares its one radio with Apple's peer-to-peer Wi-Fi (AirDrop, AirPlay, Handoff),
/// which takes the radio off the router's channel for tens of milliseconds at a time, up to twice a
/// second. Nothing an app can do stops that, so the host measures it and says so (experiment M).
/// A stall is one or more probes in a row that took over 25 ms or went unanswered.
final class MirrorLinkHealth {
    var onReport: ((_ line: String, _ short: String) -> Void)?
    /// Whether anyone is there to be told. With no viewer connected the router is not probed:
    /// eight to twenty-five pings a second, all day, for nobody. Nil means always.
    var isWanted: (() -> Bool)?
    private(set) var link = "unknown link"
    private var samples: [(at: TimeInterval, ms: Double?)] = []     // the last minute, in the order sent
    private var totals = (probes: 0, over50: 0, stalls: 0, seconds: 0.0)
    private let lock = NSLock()
    private var running = false

    func start() {
        guard !running else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/route")
        task.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { onReport?("link health: cannot find the router", ""); return }
        task.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        func field(_ name: String) -> String? {
            text.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(name + ":") }
                .map { $0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces) }
        }
        guard let gateway = field("gateway"), gateway.contains(".") else { onReport?("link health: no IPv4 router to probe", ""); return }
        let name = field("interface") ?? ""
        if let wifi = CWWiFiClient.shared().interface(), wifi.interfaceName == name {
            if let channel = wifi.wlanChannel() {
                let band = channel.channelBand == .band6GHz ? "6 GHz" : channel.channelBand == .band5GHz ? "5 GHz" : "2.4 GHz"
                link = "Wi-Fi channel \(channel.channelNumber) (\(band))"
            } else { link = "Wi-Fi" }
        } else { link = "not Wi-Fi (\(name))" }
        running = true
        Thread.detachNewThread { [self] in probe(gateway) }
    }

    func stop() { running = false }

    private func probe(_ gateway: String) {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)      // needs no special rights on macOS
        guard descriptor >= 0 else { onReport?("link health: cannot open a probe socket", ""); return }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, gateway, &address.sin_addr)
        var waiting: [UInt16: TimeInterval] = [:]
        var sequence: UInt16 = 0
        let began = mirrorNow()
        var nextSend = began, nextReport = began + 10
        while running {
            if isWanted?() == false {
                // Start afresh when a viewer comes: what was sent before the pause is not a stall.
                waiting.removeAll()
                Thread.sleep(forTimeInterval: 0.5)
                nextSend = mirrorNow()
                nextReport = max(nextReport, nextSend + 10)
                continue
            }
            let time = mirrorNow()
            if time >= nextSend {
                sequence &+= 1
                var packet = [UInt8](repeating: 0, count: 16)
                packet[0] = 8
                packet[6] = UInt8(sequence >> 8); packet[7] = UInt8(sequence & 0xFF)
                var sum: UInt32 = 0
                for index in stride(from: 0, to: packet.count, by: 2) { sum += UInt32(packet[index]) << 8 | UInt32(packet[index + 1]) }
                sum = (sum >> 16) + (sum & 0xFFFF); sum += sum >> 16
                let check = ~UInt16(truncatingIfNeeded: sum)
                packet[2] = UInt8(check >> 8); packet[3] = UInt8(check & 0xFF)
                let sent = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                if sent > 0 { waiting[sequence] = time }
                // Uneven on purpose: an even rate can beat against the radio's own schedule.
                nextSend = time + Double.random(in: 0.04...0.12)
            }
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            if poll(&poller, 1, Int32(max(0, min(nextSend - mirrorNow(), 0.1)) * 1000)) > 0 {
                var buffer = [UInt8](repeating: 0, count: 256)
                let count = recv(descriptor, &buffer, buffer.count, 0)
                let got = mirrorNow()
                let offset = count >= 28 && buffer[0] >> 4 == 4 ? 20 : 0     // the reply may come with its IP header
                if count >= offset + 8, buffer[offset] == 0 {
                    let reply = UInt16(buffer[offset + 6]) << 8 | UInt16(buffer[offset + 7])
                    if let at = waiting.removeValue(forKey: reply) { record(at: at, ms: (got - at) * 1000) }
                }
            }
            let cutoff = mirrorNow() - 1
            for (key, at) in waiting.filter({ $0.value < cutoff }) { waiting[key] = nil; record(at: at, ms: nil) }
            if mirrorNow() >= nextReport {
                nextReport += 10
                let recent = measure(over: 30)
                onReport?("link health: \(link), \(recent.line)", recent.short)
            }
        }
    }

    private func record(at: TimeInterval, ms: Double?) {
        lock.lock()
        samples.append((at, ms))
        samples.removeAll { at - $0.at > 60 }
        totals.probes += 1
        if (ms ?? 1000) > 50 { totals.over50 += 1 }
        lock.unlock()
    }

    /// Stalls among the probes of the last `seconds`.
    private func measure(over seconds: TimeInterval) -> (line: String, short: String, perMinute: Double) {
        lock.lock()
        let recent = samples.filter { mirrorNow() - $0.at <= seconds }.sorted { $0.at < $1.at }
        lock.unlock()
        guard recent.count >= 20, let first = recent.first, let last = recent.last, last.at > first.at else { return ("measuring", "", 0) }
        var depths: [Double] = []
        var open: Double?
        for sample in recent {
            if (sample.ms ?? 1000) > 25 { open = max(open ?? 0, sample.ms ?? 1000) } else if let depth = open { depths.append(depth); open = nil }
        }
        if let open { depths.append(open) }
        let perMinute = Double(depths.count) * 60 / (last.at - first.at)
        let usual = depths.sorted()[safe: depths.count / 2] ?? 0
        let over = Double(recent.filter { ($0.ms ?? 1000) > 50 }.count) / Double(recent.count) * 100
        guard perMinute >= 6 else { return ("steady, \(depths.count) stalls in \(Int(last.at - first.at)) s", "Mac link steady", perMinute) }
        return (String(format: "%.0f stalls a minute, usually %.0f ms, %.1f%% of probes over 50 ms", perMinute, usual, over),
                String(format: "Mac %@: %.0f stalls a minute of about %.0f ms", link.hasPrefix("Wi-Fi") ? "Wi-Fi" : "link", perMinute, usual), perMinute)
    }

    /// What to write at the end of a session, with advice when the link stalled often.
    func summary() -> [String] {
        let whole = measure(over: 60)
        lock.lock()
        let probes = totals.probes, over50 = totals.over50
        lock.unlock()
        guard probes > 0 else { return [] }
        var lines = [String(format: "link health: %@, last minute %@; whole session %d probes, %.1f%% over 50 ms", link, whole.line, probes, Double(over50) / Double(probes) * 100)]
        if whole.perMinute >= 20, link.hasPrefix("Wi-Fi") {
            lines.append("link health advice: this Mac's Wi-Fi radio is leaving its channel many times a minute, which delays touches and frames by up to the "
                + "length of each stall. Apple's peer-to-peer Wi-Fi (AirDrop, AirPlay, Handoff) is the usual cause. A network cable to the Mac removes it. "
                + "A router on 5 GHz channel 44 or 149 may also help. Turning off AirDrop is a further thing to try.")
        }
        return lines
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
