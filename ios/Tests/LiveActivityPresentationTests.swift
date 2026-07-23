import ActivityKit
import PedalsKit
import XCTest
@testable import Pedals

final class LiveActivityPresentationTests: XCTestCase {
    func testNoAgentsAlwaysUsesTerminalPresentation() {
        let state = makeState(
            running: 0,
            waiting: 0,
            done: 0,
            recentState: AgentState.waiting.rawValue
        )

        XCTAssertEqual(state.totalAgents, 0)
        XCTAssertNil(state.displayedAgentState)
    }

    func testRecentAgentStateWinsWhenAgentsExist() {
        let state = makeState(
            running: 1,
            waiting: 1,
            done: 0,
            recentState: AgentState.running.rawValue
        )

        XCTAssertEqual(state.totalAgents, 2)
        XCTAssertEqual(state.displayedAgentState, .running)
    }

    func testAgentAggregateNeverFallsBackToTerminalWithoutRichContent() {
        XCTAssertEqual(
            makeState(running: 0, waiting: 1, done: 0).displayedAgentState,
            .waiting
        )
        XCTAssertEqual(
            makeState(running: 0, waiting: 0, done: 1).displayedAgentState,
            .done
        )
        XCTAssertEqual(
            makeState(running: 1, waiting: 0, done: 0).displayedAgentState,
            .running
        )
    }

    private func makeState(
        running: Int,
        waiting: Int,
        done: Int,
        recentState: String? = nil
    ) -> TTYActivityAttributes.ContentState {
        .init(
            totalRunning: 3,
            agentsRunning: running,
            agentsWaiting: waiting,
            agentsDone: done,
            recentAgentState: recentState,
            onlineComputerCount: 1,
            offlineComputerCount: 0,
            updatedAt: .now,
            sequence: 1
        )
    }
}
