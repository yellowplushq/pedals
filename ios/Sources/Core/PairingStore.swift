import Foundation
import PedalsKit
import Security

@MainActor
protocol PairingServiceClient: AnyObject {
    func createClient() async throws -> ClientIdentity
    func pair(code: PairingCode, as client: ClientIdentity) async throws -> ComputerBinding
    func unbind(computerID: String, as client: ClientIdentity) async throws
}

extension PedalsServiceAPI: PairingServiceClient {}

/// Persists the v2 client identity and every E2EE computer binding as one
/// Keychain value. A single value is important here: replacing a stale client
/// identity must never leave bindings that belong to the previous identity.
/// Pairing codes and ephemeral agreement keys are intentionally never stored.
@MainActor
final class PairingStore {
    enum StoreError: Error, LocalizedError {
        case serviceMismatch
        case missingClientIdentity
        case compensationFailed(primary: any Error, compensation: any Error)

        var errorDescription: String? {
            switch self {
            case .serviceMismatch:
                "This Pedals installation is already registered with another service."
            case .missingClientIdentity:
                "The Pedals client identity is missing. Pair this device again."
            case .compensationFailed(let primary, let compensation):
                "Could not roll back a failed pairing commit (commit: \(primary.localizedDescription); rollback: \(compensation.localizedDescription))."
            }
        }
    }

    private struct PersistentState: Codable {
        let identity: ClientIdentity
        let bindings: [ComputerBinding]
    }

    typealias APIFactory = @MainActor (URL) -> any PairingServiceClient
    typealias StateReader = @MainActor () throws -> Data?
    typealias StateWriter = @MainActor (Data) throws -> Void

    private static let service = "air.build.pedals.v2"
    private static let stateAccount = "pairing-state"

    private let apiFactory: APIFactory
    private let stateReader: StateReader
    private let stateWriter: StateWriter
    private var mutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    convenience init() {
        self.init(
            apiFactory: { PedalsServiceAPI(serviceURL: $0) },
            stateReader: { try Self.readKeychainState() },
            stateWriter: { try Self.writeKeychainState($0) }
        )
    }

    init(
        apiFactory: @escaping APIFactory,
        stateReader: @escaping StateReader,
        stateWriter: @escaping StateWriter
    ) {
        self.apiFactory = apiFactory
        self.stateReader = stateReader
        self.stateWriter = stateWriter
    }

    #if DEBUG
    static func resetKeychainForUITesting() {
        SecItemDelete(query as CFDictionary)
    }
    #endif

    func loadAll() throws -> [ComputerBinding] {
        try loadState()?.bindings ?? []
    }

    func loadClientIdentity() throws -> ClientIdentity? {
        try loadState()?.identity
    }

    func bind(
        code: PairingCode,
        serviceURL: URL = PedalsServiceAPI.productionServiceURL
    ) async throws -> (ComputerBinding, ClientIdentity) {
        await acquireMutation()
        do {
            let result = try await bindLocked(code: code, serviceURL: serviceURL)
            releaseMutation()
            return result
        } catch {
            releaseMutation()
            throw error
        }
    }

    private func bindLocked(
        code: PairingCode,
        serviceURL: URL
    ) async throws -> (ComputerBinding, ClientIdentity) {
        let api = apiFactory(serviceURL)
        let previousState = try loadState()

        if let previousState {
            guard previousState.identity.serviceURL == serviceURL else {
                throw StoreError.serviceMismatch
            }
            do {
                let binding = try await api.pair(code: code, as: previousState.identity)
                return try await commitBinding(
                    binding,
                    identity: previousState.identity,
                    previousState: previousState,
                    api: api
                )
            } catch {
                guard Self.isUnauthorized(error) else { throw error }
                let replacement = try await api.createClient()
                let binding = try await api.pair(code: code, as: replacement)
                return try await commitReplacement(binding, identity: replacement, api: api)
            }
        }

        let identity = try await api.createClient()
        let binding = try await api.pair(code: code, as: identity)
        return try await commitReplacement(binding, identity: identity, api: api)
    }

    private func commitBinding(
        _ binding: ComputerBinding,
        identity: ClientIdentity,
        previousState: PersistentState,
        api: any PairingServiceClient
    ) async throws -> (ComputerBinding, ClientIdentity) {
        var bindings = previousState.bindings.filter {
            $0.computerID != binding.computerID
        }
        bindings.append(binding)

        do {
            try saveState(PersistentState(identity: identity, bindings: bindings))
        } catch {
            // Re-pairing an existing edge must retain that edge if the local
            // key cannot be replaced. A newly-created edge is compensated.
            if !previousState.bindings.contains(where: {
                $0.computerID == binding.computerID
            }) {
                do {
                    try await api.unbind(
                        computerID: binding.computerID,
                        as: identity
                    )
                } catch let compensation {
                    throw StoreError.compensationFailed(
                        primary: error,
                        compensation: compensation
                    )
                }
            }
            throw error
        }
        return (binding, identity)
    }

    private func commitReplacement(
        _ binding: ComputerBinding,
        identity: ClientIdentity,
        api: any PairingServiceClient
    ) async throws -> (ComputerBinding, ClientIdentity) {
        do {
            // All previous bindings were authorized by the rejected identity;
            // they cannot be used with this replacement client.
            try saveState(PersistentState(
                identity: identity,
                bindings: [binding]
            ))
        } catch {
            do {
                try await api.unbind(
                    computerID: binding.computerID,
                    as: identity
                )
            } catch let compensation {
                throw StoreError.compensationFailed(
                    primary: error,
                    compensation: compensation
                )
            }
            throw error
        }
        return (binding, identity)
    }

    func unbind(computerID: String) async throws {
        await acquireMutation()
        do {
            try await unbindLocked(computerID: computerID)
            releaseMutation()
        } catch {
            releaseMutation()
            throw error
        }
    }

    private func unbindLocked(computerID: String) async throws {
        guard let state = try loadState() else {
            throw StoreError.missingClientIdentity
        }
        let api = apiFactory(state.identity.serviceURL)
        try await api.unbind(computerID: computerID, as: state.identity)
        try saveState(PersistentState(
            identity: state.identity,
            bindings: state.bindings.filter { $0.computerID != computerID }
        ))
    }

    /// MainActor reentrancy means a second code can arrive while the
    /// first network request is suspended. This FIFO gate makes every remote
    /// mutation plus Keychain commit one transaction from the UI's view.
    private func acquireMutation() async {
        if !mutationInProgress {
            mutationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutation() {
        if mutationWaiters.isEmpty {
            mutationInProgress = false
        } else {
            mutationWaiters.removeFirst().resume()
        }
    }

    private func loadState() throws -> PersistentState? {
        guard let data = try stateReader() else { return nil }
        return try JSONDecoder().decode(PersistentState.self, from: data)
    }

    private func saveState(_ state: PersistentState) throws {
        try stateWriter(JSONEncoder().encode(state))
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        guard case PedalsServiceAPI.APIError.rejected(let status, _) = error else {
            return false
        }
        return status == 401
    }

    private static func writeKeychainState(_ data: Data) throws {
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard update == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(update))
            }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static func readKeychainState() throws -> Data? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return data
    }

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: stateAccount,
        ]
    }
}
