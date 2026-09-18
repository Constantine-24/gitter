import Testing
@testable import GitCore

@Test func moduleLoads() {
    #expect(GitCoreInfo.version == "0.1.0")
}
