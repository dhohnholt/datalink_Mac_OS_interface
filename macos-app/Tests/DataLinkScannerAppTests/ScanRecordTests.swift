import Testing

@testable import DataLinkScannerApp

// The native front end is not wired to the transport yet; see README, phase 7.
// This suite exists so `swift test` has something to run and the model layer
// stays compiling as the Python side evolves.

@Test func packageBuilds() {
    #expect(Bool(true))
}
