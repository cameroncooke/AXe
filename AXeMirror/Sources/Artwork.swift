import SwiftUI

/// A small drawn scene for a screen that has something to say and nothing yet to show: the home
/// screen, a connection being made or lost, an empty list.
///
/// Every scene is made of the same few things, so they read as one family: a Mac, the phone in
/// your hand, the line between them, and a badge that says what has happened to it. They are drawn
/// here, in shapes, and not kept as pictures: they stay sharp at any size, take the app's own
/// colours, and move a little where something is going on. They are decoration, and hidden from
/// VoiceOver: the words beside them say the same thing.
struct Artwork: View {
    enum Scene {
        /// The Mac's simulator, shown on the phone: what the app is for.
        case mirroring
        /// Reaching the Mac.
        case connecting
        /// The connection dropped and is being made again.
        case reconnecting
        /// The Mac is reached and its picture is on the way.
        case waiting
        /// This device has no internet connection.
        case offline
        /// The relay every connection starts through cannot be reached.
        case relayDown
        /// The Mac does not answer: asleep, offline, or no host running.
        case macAway
        /// The Mac no longer knows this device.
        case notPaired
        /// Somebody else is using the demo.
        case busy
        /// This app is too old to connect.
        case update
        /// The Mac has published no builds.
        case noBuilds
        /// No simulator is running on the Mac.
        case nothingRunning
        /// Something on the Mac went wrong.
        case trouble
        /// Done, and working.
        case ready
    }

    let scene: Scene
    /// The width to draw at; the height follows.
    var width: CGFloat = 240

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // The scenes are laid out on a canvas 280 by 190 and drawn at whatever size is asked for.
    private var unit: CGFloat { width / 280 }
    private func u(_ value: CGFloat) -> CGFloat { value * unit }

    private struct Parts {
        var tint: Color = .accentColor
        var mac: Mac? = .on
        var phone: Phone? = .dark
        var line: Line = .none
        var badge: (symbol: String, colour: Color, spot: Spot)?
        var symbol: String?
    }
    private enum Mac { case on, showing, dim, empty }
    private enum Phone { case dark, lit, faded }
    private enum Line { case none, flowing, still, broken }
    private enum Spot { case middle, onMac, onPhone }

    private var parts: Parts {
        switch scene {
        case .mirroring: return Parts(mac: .showing, phone: .lit, line: .flowing)
        case .connecting: return Parts(line: .flowing)
        case .reconnecting: return Parts(tint: .orange, line: .flowing)
        case .waiting: return Parts(mac: .showing, line: .flowing)
        case .offline: return Parts(tint: .orange, mac: .dim, line: .broken, badge: ("wifi.slash", .orange, .onPhone))
        case .relayDown: return Parts(tint: .orange, line: .broken, badge: ("xmark", .orange, .middle))
        case .macAway: return Parts(tint: .indigo, mac: .dim, line: .still, badge: ("moon.zzz.fill", .indigo, .onMac))
        case .notPaired: return Parts(tint: .orange, line: .broken, badge: ("lock.fill", .orange, .middle))
        case .busy: return Parts(tint: .purple, mac: .showing, phone: .faded, line: .still, badge: ("hourglass", .purple, .onPhone))
        case .update: return Parts(mac: nil, phone: .dark, badge: ("arrow.down", .accentColor, .onPhone))
        case .noBuilds: return Parts(tint: .orange, mac: nil, phone: nil, symbol: "shippingbox.fill")
        case .nothingRunning: return Parts(tint: .indigo, mac: .empty, phone: nil)
        case .trouble: return Parts(tint: .orange, mac: .dim, phone: nil, badge: ("exclamationmark", .orange, .onMac))
        case .ready: return Parts(tint: .green, mac: nil, phone: .lit, badge: ("checkmark", .green, .onPhone))
        }
    }

    var body: some View {
        let parts = parts
        // Where things stand. A scene with one thing in it has that thing in the middle.
        let alone = parts.mac == nil || parts.phone == nil
        let macCentre = CGPoint(x: alone ? 140 : 104, y: 92)
        let phoneCentre = CGPoint(x: alone ? 140 : 214, y: 104)
        ZStack {
            glow(parts.tint)
            sparks(parts.tint)
            if let mac = parts.mac { self.mac(mac, tint: parts.tint).position(x: u(macCentre.x), y: u(macCentre.y)) }
            if !alone, parts.line != .none { line(parts.line, tint: parts.tint) }
            if let phone = parts.phone { self.phone(phone, tint: parts.tint).position(x: u(phoneCentre.x), y: u(phoneCentre.y)) }
            if let symbol = parts.symbol { tile(symbol, tint: parts.tint).position(x: u(140), y: u(96)) }
            if let badge = parts.badge {
                let place: CGPoint = switch badge.spot {
                case .middle: CGPoint(x: 176, y: 62)
                case .onMac: CGPoint(x: macCentre.x + 62, y: macCentre.y - 46)
                case .onPhone: CGPoint(x: phoneCentre.x + 26, y: phoneCentre.y - 50)
                }
                self.badge(badge.symbol, badge.colour).position(x: u(place.x), y: u(place.y))
            }
        }
        .frame(width: width, height: u(190))
        .accessibilityHidden(true)
    }

    // MARK: The pieces

    /// Light behind the scene, in its colour.
    private func glow(_ tint: Color) -> some View {
        Ellipse()
            .fill(RadialGradient(colors: [tint.opacity(0.34), tint.opacity(0.0)], center: .center, startRadius: 0, endRadius: u(130)))
            .frame(width: u(270), height: u(180))
            .position(x: u(140), y: u(100))
    }

    /// A few specks around it, so the scene does not float in nothing.
    private func sparks(_ tint: Color) -> some View {
        let specks: [(x: CGFloat, y: CGFloat, size: CGFloat, strength: Double)] = [
            (26, 46, 5, 0.5), (48, 150, 3.5, 0.35), (252, 34, 4, 0.45), (262, 150, 5.5, 0.3), (150, 18, 3, 0.4), (120, 174, 4, 0.3),
        ]
        return ZStack {
            ForEach(Array(specks.enumerated()), id: \.offset) { _, speck in
                Circle().fill(tint.opacity(speck.strength)).frame(width: u(speck.size), height: u(speck.size)).position(x: u(speck.x), y: u(speck.y))
            }
        }
    }

    /// The Mac: a laptop, its screen dark unless it has something on it.
    private func mac(_ state: Mac, tint: Color) -> some View {
        let dim = state == .dim
        return VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: u(9), style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: dim ? 0.13 : 0.2), Color(white: dim ? 0.09 : 0.11)], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: u(9), style: .continuous)
                    .strokeBorder(Color.white.opacity(dim ? 0.2 : 0.42), lineWidth: u(2))
                switch state {
                case .showing:
                    // The simulator on the Mac's screen: the same picture the phone has.
                    RoundedRectangle(cornerRadius: u(5), style: .continuous)
                        .fill(wallpaper(tint))
                        .frame(width: u(28), height: u(56))
                        .overlay(RoundedRectangle(cornerRadius: u(5), style: .continuous).strokeBorder(Color.white.opacity(0.55), lineWidth: u(1.2)))
                case .empty:
                    // Where a simulator would be.
                    RoundedRectangle(cornerRadius: u(5), style: .continuous)
                        .strokeBorder(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: u(1.6), dash: [u(4), u(4)]))
                        .frame(width: u(28), height: u(56))
                case .on, .dim:
                    EmptyView()
                }
            }
            .frame(width: u(132), height: u(86))
            // The part the screen stands on.
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: u(2), bottomLeading: u(7), bottomTrailing: u(7), topTrailing: u(2)), style: .continuous)
                // The screen's own colour is dark in any appearance; the base takes the text's, to show on either.
                .fill(Color.primary.opacity(dim ? 0.22 : 0.42))
                .frame(width: u(158), height: u(8))
        }
        .opacity(dim ? 0.75 : 1)
    }

    /// The phone in your hand.
    private func phone(_ state: Phone, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: u(13), style: .continuous)
                .fill(state == .dark ? AnyShapeStyle(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.11)], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(wallpaper(tint)))
            RoundedRectangle(cornerRadius: u(13), style: .continuous)
                .strokeBorder(Color.white.opacity(0.75), lineWidth: u(2.4))
            Capsule().fill(Color.black.opacity(0.75)).frame(width: u(18), height: u(5)).offset(y: u(-46))
            if state == .lit {
                // A finger on the picture: touches go the other way.
                Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: u(2)).frame(width: u(18), height: u(18)).offset(x: u(4), y: u(14))
                Circle().fill(Color.white.opacity(0.35)).frame(width: u(18), height: u(18)).offset(x: u(4), y: u(14))
            }
        }
        .frame(width: u(58), height: u(112))
        .opacity(state == .faded ? 0.5 : 1)
        .shadow(color: .black.opacity(0.35), radius: u(8), y: u(5))
    }

    private func wallpaper(_ tint: Color) -> LinearGradient {
        LinearGradient(colors: [tint, tint.opacity(0.75), (tint == .green ? Color.mint : Color.purple).opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// What passes between the two: dots that travel while it does, stand still while it waits,
    /// and stop short when it is broken.
    ///
    /// The dots travel by the clock, one gap every `dotsTurn` seconds, and not by an animation
    /// started when the scene appears. That animation never ended, and it took with it whatever
    /// else was settling into place at that moment: on a screen still finding its width, the
    /// words under the drawing slid sideways with it, over and over, in scenes with no dots at all.
    private func line(_ state: Line, tint: Color) -> some View {
        let travels = state == .flowing && !reduceMotion
        return TimelineView(.animation(paused: !travels)) { context in
            let turn = travels ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.dotsTurn) / Self.dotsTurn : 0
            Path { path in
                path.move(to: CGPoint(x: u(150), y: u(40)))
                path.addQuadCurve(to: CGPoint(x: u(state == .broken ? 170 : 206), y: u(state == .broken ? 32 : 42)), control: CGPoint(x: u(178), y: u(16)))
            }
            .stroke(state == .flowing ? tint : Color.white.opacity(0.45),
                    style: StrokeStyle(lineWidth: u(3.2), lineCap: .round, dash: [u(1), u(9)], dashPhase: -u(10) * turn))
        }
    }
    private static let dotsTurn: TimeInterval = 1.1

    /// What has happened, on a disc of its colour.
    private func badge(_ symbol: String, _ colour: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: u(15), weight: .bold))
            .foregroundStyle(.white)
            .frame(width: u(32), height: u(32))
            .background(colour.gradient, in: Circle())
            .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: u(2.5)))
    }

    /// A scene that is one thing: that thing, large, on a tile.
    private func tile(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: u(50), weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: u(104), height: u(104))
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: u(28), style: .continuous))
            .rotationEffect(.degrees(-6))
            .shadow(color: tint.opacity(0.4), radius: u(14), y: u(8))
    }
}
