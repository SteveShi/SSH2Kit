import Testing
import Foundation
@testable import SSH2Kit

@Test func testSessionInitialState() async throws {
    let session = SSHSession()
    let state = await session.state
    #expect(state == .disconnected)
}
