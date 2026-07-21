import Foundation
import PedalsKit

/// The Watch's independent relay credential plus E2EE bindings copied from the
/// paired iPhone. The Worker never sees this payload; WatchConnectivity moves
/// it between the two app installations and the Watch stores it in Keychain.
public struct WatchTerminalContext: Codable, Equatable, Sendable {
    public static let applicationContextKey = "pedals.terminal.context.v1"
    public static let applicationContextPresenceKey = "pedals.terminal.context.present.v1"
    public static let requestMessageKey = "pedals.terminal.context.request.v1"

    public let identity: ClientIdentity
    public let bindings: [ComputerBinding]

    public init(identity: ClientIdentity, bindings: [ComputerBinding]) {
        self.identity = identity
        self.bindings = bindings.filter { $0.serviceURL == identity.serviceURL }
    }

    public static func applicationContext(_ context: Self?) -> [String: Any] {
        var value: [String: Any] = [applicationContextPresenceKey: true]
        if let context, let data = try? JSONEncoder().encode(context) {
            value[applicationContextKey] = data
        }
        return value
    }

    public init?(applicationContext: [String: Any]) {
        guard let data = applicationContext[Self.applicationContextKey] as? Data,
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              decoded.bindings.allSatisfy({ $0.serviceURL == decoded.identity.serviceURL })
        else { return nil }
        self = decoded
    }
}
