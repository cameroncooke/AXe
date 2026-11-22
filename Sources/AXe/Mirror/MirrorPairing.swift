#if AXE_MIRROR
import Foundation
import IrohLib

/// Runs one pairing: shows a code, waits for a viewer to present it, stores the viewer.
enum MirrorPairHost {
    struct Shown { let code: String; let link: String; let expires: Date; let relay: String }

    /// `shown` is called once the temporary endpoint is reachable, with what to put on screen.
    /// Returns the viewer that paired. Throws when nobody does before the code expires.
    static func run(hostSecret: Data, relays: MirrorRelays.Choice, viewers: MirrorViewers, hostName: String,
                    lifetime: TimeInterval = MirrorPairingCode.lifetime, shown: (Shown) -> Void) async throws -> MirrorViewer {
        let hostId = try SecretKey.fromBytes(bytes: hostSecret).public().description
        let code = MirrorPairingCode.random()
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: MirrorUnannouncedPreset(relayURLs: relays.relays), secretKey: MirrorPairingCode.endpointSecret(for: code),
            alpns: [MirrorPairWire.alpn]))
        // The code is shown only once the relay knows this endpoint; before that a viewer would find nobody.
        guard await MirrorTimeout.finishes(within: 30, { await endpoint.online() }) != nil, let relay = endpoint.addr().relayUrl() else {
            try? await endpoint.close()
            throw CLIError(errorDescription: "Could not reach a relay to pair through. Check this Mac's internet connection.", code: .commandFailed)
        }
        let expires = Date().addingTimeInterval(lifetime)
        shown(Shown(code: code, link: MirrorPairingCode.link(code, relay: relays.isNamed ? relay : nil), expires: expires, relay: relay))
        let invitation = Invitation(MirrorInvitation(code: code, expires: expires))
        let reply = { @Sendable (request: MirrorPairRequest) in
            MirrorPairReply(requestId: request.requestId, hostId: hostId, name: MirrorViewers.clean(hostName),
                            homeRelay: relays.relays.isEmpty ? "" : relay, relays: relays.relays)
        }
        let paired = await MirrorTimeout.finishes(within: lifetime) { () -> MirrorViewer? in
            while let incoming = await endpoint.acceptNext() {
                guard let connection = try? await incoming.accept().connect(),
                      let served = await serve(connection, invitation: invitation, viewers: viewers, reply: reply) else { continue }
                if served.heard { return served.viewer }
                // The viewer is stored, and did not say the answer reached it: the answer may have
                // been lost. It asks again if so, and is given the same answer, for a little while.
                _ = await MirrorTimeout.finishes(within: repeatWithin) { () -> Bool in
                    while let incoming = await endpoint.acceptNext() {
                        guard let connection = try? await incoming.accept().connect(),
                              let again = await serve(connection, invitation: invitation, viewers: viewers, reply: reply) else { continue }
                        if again.heard { return true }
                    }
                    return false
                }
                return served.viewer
            }
            return nil
        }
        try? await endpoint.close()
        guard let viewer = paired ?? nil else {
            throw CLIError(errorDescription: "Nobody used the code before it expired. Run axe mirror pair again for a new one.", code: .commandFailed)
        }
        return viewer
    }

    /// How long the Mac goes on answering after it has paired a viewer that did not say the answer
    /// arrived. An app from before viewers said so costs `axe mirror pair` this long at its end.
    static let repeatWithin: TimeInterval = 12

    /// The invitation, shared between connections that arrive together.
    private actor Invitation {
        private var invitation: MirrorInvitation
        init(_ invitation: MirrorInvitation) { self.invitation = invitation }

        /// Decides the request and, for a newly accepted viewer, stores it before saying yes.
        func decide(_ request: MirrorPairRequest, from viewer: String, viewers: MirrorViewers,
                    reply: @Sendable (MirrorPairRequest) -> MirrorPairReply) -> Result<(MirrorPairReply, MirrorViewer), MirrorInvitation.Refusal> {
            switch invitation.accept(request, from: viewer, answer: reply) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let made):
                guard let stored = try? viewers.add(id: viewer, name: request.name) else { return .failure(.malformed) }
                return .success((made, stored))
            }
        }
    }

    /// Answers one connection. Nil when it is refused; otherwise the viewer that is now paired, and
    /// whether it said the answer reached it.
    private static func serve(_ connection: Connection, invitation: Invitation, viewers: MirrorViewers,
                              reply: @escaping @Sendable (MirrorPairRequest) -> MirrorPairReply) async -> (viewer: MirrorViewer, heard: Bool)? {
        let viewer = connection.remoteId().description
        let heard = MirrorLastValue()
        let request = await MirrorTimeout.finishes(within: 10) { () -> MirrorPairRequest? in
            guard let stream = try? await connection.acceptBi(),
                  let header = try? await stream.recv().readExact(size: 4), let length = MirrorPairWire.length(header: header),
                  let body = try? await stream.recv().readExact(size: UInt32(length)),
                  let request = try? JSONDecoder().decode(MirrorPairRequest.self, from: body) else { return nil }
            switch await invitation.decide(request, from: viewer, viewers: viewers, reply: reply) {
            case .failure:
                return nil
            case .success(let (made, _)):
                guard let frame = try? MirrorPairWire.frame(made) else { return nil }
                try? await stream.send().writeAll(buf: frame)
                try? await stream.send().finish()
                // An app from before viewers said so says nothing: that is waited for briefly.
                let said = await MirrorTimeout.finishes(within: 3) { try? await stream.recv().readExact(size: 1) } ?? nil
                if said == MirrorPairWire.received { _ = heard.changed(to: ["heard"]) }
                return request
            }
        } ?? nil
        guard request != nil else {
            // One answer for every failure: a wrong code, a used one and a malformed request look alike from outside.
            try? connection.close(errorCode: MirrorClose.pairingRefused, reason: Data("pairing refused".utf8))
            return nil
        }
        // The viewer closes once it has stored this Mac; give the answer a moment to arrive before closing.
        _ = await MirrorTimeout.finishes(within: 5) { await connection.closed() }
        try? connection.close(errorCode: MirrorClose.stopped, reason: Data())
        guard let stored = (try? viewers.all())?.first(where: { $0.id == viewer }) else { return nil }
        return (stored, heard.current != nil)
    }
}
#endif
