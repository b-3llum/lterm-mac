import XCTest
@testable import LtermCore

final class AgentStateTests: XCTestCase {
    func testUrgencyOrder() {
        let blocked = AgentStatus(state: .blocked)
        let doneUnseen = AgentStatus(state: .done, seen: false)
        let working = AgentStatus(state: .working)
        let doneSeen = AgentStatus(state: .done, seen: true)
        XCTAssertGreaterThan(blocked.urgency, doneUnseen.urgency)
        XCTAssertGreaterThan(doneUnseen.urgency, working.urgency)
        XCTAssertGreaterThan(working.urgency, doneSeen.urgency)
        XCTAssertEqual(AgentRules.mostUrgent([working, doneSeen, blocked])?.state, .blocked)
        XCTAssertNil(AgentRules.mostUrgent([AgentStatus()]))
    }

    func testUpdateResetsSeenForDoneAndBlocked() {
        var status = AgentStatus()
        status.update(state: .working, agent: "claude", message: nil)
        XCTAssertTrue(status.seen)
        status.update(state: .done, agent: nil, message: nil)
        XCTAssertFalse(status.seen)
        XCTAssertEqual(status.agent, "claude", "agent name sticks")
        XCTAssertEqual(status.border, .done)
        status.seen = true
        XCTAssertEqual(status.border, .fadedDone)
        status.update(state: .none, agent: nil, message: nil)
        XCTAssertNil(status.agent)
    }

    func testNextNeedsMeCyclesBlockedFirst() {
        let panes: [(id: Int, status: AgentStatus)] = [
            (1, AgentStatus(state: .done, seen: false)),
            (2, AgentStatus(state: .working)),
            (3, AgentStatus(state: .blocked)),
            (4, AgentStatus(state: .idle, notified: true)),
        ]
        XCTAssertEqual(AgentRules.nextNeedsMe(panes: panes, current: 2), 3)
        XCTAssertEqual(AgentRules.nextNeedsMe(panes: panes, current: 3), 1)
        XCTAssertEqual(AgentRules.nextNeedsMe(panes: panes, current: 1), 4)
        XCTAssertEqual(AgentRules.nextNeedsMe(panes: panes, current: 4), 3)
        XCTAssertNil(AgentRules.nextNeedsMe(panes: [(1, AgentStatus(state: .working))], current: nil))
    }

    func testSummary() {
        let list = [AgentStatus(state: .working), AgentStatus(state: .working), AgentStatus(state: .blocked), AgentStatus()]
        XCTAssertEqual(AgentRules.summary(list), "1 blocked  2 working")
    }

    func testNotificationParsing() {
        XCTAssertEqual(AgentRules.notificationText(code: 9, payload: "Build finished"), "Build finished")
        XCTAssertNil(AgentRules.notificationText(code: 9, payload: "4;1;50"), "progress report")
        XCTAssertEqual(AgentRules.notificationText(code: 777, payload: "notify;Claude;Needs approval"), "Claude: Needs approval")
        XCTAssertNil(AgentRules.notificationText(code: 777, payload: "other;x"))
        XCTAssertEqual(AgentRules.notificationText(code: 99, payload: "i=1:d=0;Hello"), "Hello")
        XCTAssertEqual(AgentRules.notificationText(code: 99, payload: "e=1;" + Data("hi there".utf8).base64EncodedString()), "hi there")
        XCTAssertNil(AgentRules.notificationText(code: 99, payload: "i=1:p=?;"))
    }
}
