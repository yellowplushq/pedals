import ActivityKit
import Foundation

@MainActor
public final class TTYLiveActivityController {
    public static let shared = TTYLiveActivityController()

    private var observing = false
    private var observationTasks: [Task<Void, Never>] = []
    private var tokenTasks: [String: Task<Void, Never>] = [:]
    private var stateTasks: [String: Task<Void, Never>] = [:]

    public init() {}

    /// Call once during app launch. It covers both app-created and APNs-created
    /// activities and keeps every rotating ActivityKit token registered.
    public func startObservingPushTokens() {
        guard !observing else { return }
        observing = true

        observationTasks.append(Task { [weak self] in
            for await token in Activity<TTYActivityAttributes>.pushToStartTokenUpdates {
                guard !Task.isCancelled else { return }
                await PushEndpointRegistrar.registerOrQueue(
                    .init(
                        surface: .iOSLiveActivityStart,
                        token: token.pedalsHexString
                    )
                )
                guard self != nil else { return }
            }
        })

        for activity in Activity<TTYActivityAttributes>.activities {
            observe(activity)
        }

        observationTasks.append(Task { [weak self] in
            for await activity in Activity<TTYActivityAttributes>.activityUpdates {
                guard !Task.isCancelled else { return }
                self?.observe(activity)
            }
        })
    }

    public func stopObservingPushTokens() {
        observationTasks.forEach { $0.cancel() }
        tokenTasks.values.forEach { $0.cancel() }
        stateTasks.values.forEach { $0.cancel() }
        observationTasks.removeAll()
        tokenTasks.removeAll()
        stateTasks.removeAll()
        observing = false
    }

    #if DEBUG
    /// Dev-only visual fixture: the production activity is APNs
    /// push-to-start only, which a simulator cannot receive, so this renders
    /// the identical UI from a locally requested activity.
    /// `PEDALS_LA_FIXTURE="ttys:agentsRunning:agentsWaiting"`.
    public func startFixtureActivity(spec: String) {
        let counts = spec.split(separator: ":").compactMap { Int($0) }
        guard counts.count == 3 else { return }
        Task { @MainActor in
            for activity in Activity<TTYActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            let state = TTYActivityAttributes.ContentState(
                totalRunning: counts[0],
                agentsRunning: counts[1],
                agentsWaiting: counts[2],
                onlineComputerCount: 1,
                offlineComputerCount: 0,
                updatedAt: .now,
                sequence: 1
            )
            _ = try? Activity<TTYActivityAttributes>.request(
                attributes: TTYActivityAttributes(),
                content: ActivityContent(state: state, staleDate: nil)
            )
        }
    }
    #endif

    private func observe(_ activity: Activity<TTYActivityAttributes>) {
        observeUpdateToken(for: activity)
        observeState(for: activity)
    }

    /// Keeps an existing server-started activity current while the app is in
    /// the foreground. Activity creation is intentionally APNs-only: locally
    /// requesting one here would race the push-to-start delivery and create a
    /// duplicate Dynamic Island activity.
    public func synchronize(with snapshot: TTYStatusSnapshot) async throws {
        StatusSharedStore.saveSnapshot(snapshot)
        // The activity lives while anything is active: a running TTY or a
        // running/waiting agent (the Worker uses the same lifecycle rule).
        let totalActive =
            snapshot.totalRunning + snapshot.agentsRunning + snapshot.agentsWaiting
        let content = ActivityContent(
            state: TTYActivityAttributes.ContentState(snapshot: snapshot),
            staleDate: snapshot.updatedAt.addingTimeInterval(5 * 60),
            relevanceScore: totalActive > 0 ? 100 : 0
        )

        let activities = Activity<TTYActivityAttributes>.activities
        if totalActive == 0 {
            for activity in activities {
                await activity.end(content, dismissalPolicy: .immediate)
            }
            return
        }

        for activity in activities {
            await activity.update(content)
        }
    }

    private func observeUpdateToken(for activity: Activity<TTYActivityAttributes>) {
        guard tokenTasks[activity.id] == nil else { return }
        tokenTasks[activity.id] = Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                await PushEndpointRegistrar.registerOrQueue(
                    .init(
                        surface: .iOSLiveActivityUpdate,
                        token: token.pedalsHexString,
                        activityId: activity.id
                    )
                )
            }
            self?.tokenTasks.removeValue(forKey: activity.id)
        }
    }

    private func observeState(for activity: Activity<TTYActivityAttributes>) {
        guard stateTasks[activity.id] == nil else { return }
        stateTasks[activity.id] = Task { [weak self] in
            if Self.isTerminal(activity.activityState) {
                await self?.removeEndpoint(for: activity.id)
                return
            }
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                if Self.isTerminal(state) {
                    await self?.removeEndpoint(for: activity.id)
                    return
                }
            }
            self?.stateTasks.removeValue(forKey: activity.id)
        }
    }

    private func removeEndpoint(for activityId: String) async {
        // Stop token rotation first. The durable mutation identity is shared
        // with PUT, so a terminal DELETE safely wins even if a registration
        // was already in flight in another App Group process.
        tokenTasks.removeValue(forKey: activityId)?.cancel()
        await PushEndpointRegistrar.unregisterOrQueue(
            .iOSLiveActivityUpdate,
            activityId: activityId
        )
        stateTasks.removeValue(forKey: activityId)
    }

    private static func isTerminal(_ state: ActivityState) -> Bool {
        state == .ended || state == .dismissed
    }
}
