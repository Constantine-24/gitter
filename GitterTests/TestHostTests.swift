import Testing

@testable import Gitter

@Suite struct TestHostTests {
    /// The app this bundle is hosted in knows it is under test — which is what keeps it from
    /// reopening the last repository and from starting the automatic fetch.
    @Test func testHostIsDetected() {
        #expect(TestHost.isRunningTests)
    }
}
