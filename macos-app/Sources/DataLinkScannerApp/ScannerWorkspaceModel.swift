import Foundation
import SwiftUI

@MainActor
final class ScannerWorkspaceModel: ObservableObject {
    @Published var selectedSection: WorkspaceSection? = .scan
    @Published private(set) var scannerState: ScannerState = .disconnected
    @Published private(set) var currentSession = ScanSession(
        name: "Untitled scanning session",
        course: ""
    )
    @Published private(set) var savedSessions: [ScanSession] = []
    @Published private(set) var activity: [ActivityEntry] = []
    @Published var showingNewSession = false
    @Published var showingActivity = false
    @Published var demoMode = true

    private let transport: any ScannerTransport

    init(transport: any ScannerTransport = DemoScannerTransport()) {
        self.transport = transport
        log("Workspace opened. Scanner is disconnected.")
    }

    var scanCount: Int { currentSession.records.count }
    var flaggedCount: Int { currentSession.records.filter { !$0.flags.isEmpty }.count }

    func connect() async {
        scannerState = .connecting
        log("Looking for the DataLink 1200…")
        do {
            let port = try await transport.connect()
            scannerState = .connected(port: port)
            log("Scanner identified on \(port).", kind: .success)
        } catch {
            fail(error)
        }
    }

    func enterDataMode() async {
        guard let port = scannerState.port else {
            fail(ScannerTransportError.notConnected)
            return
        }
        scannerState = .enteringDataMode(port: port)
        log("Requesting Data Mode…")
        do {
            try await transport.enterDataMode()
            scannerState = .dataMode(port: port)
            log("Data Mode confirmed. Ready for sheets.", kind: .success)
        } catch {
            fail(error)
        }
    }

    func disconnect() async {
        await transport.disconnect()
        scannerState = .disconnected
        log("Scanner disconnected.")
    }

    func createSession(name: String, course: String) {
        if !currentSession.records.isEmpty {
            savedSessions.insert(currentSession, at: 0)
        }
        currentSession = ScanSession(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Untitled scanning session" : name,
            course: course
        )
        log("Created session “\(currentSession.name).”", kind: .success)
    }

    func simulateScan() {
        guard scannerState.isDataMode else {
            log("A sheet was ignored because Data Mode is not active.", kind: .warning)
            return
        }

        let samples: [(String, [ScanFlag])] = [
            ("900011", []),
            ("900006", [.blank]),
            ("900012", []),
            ("900009", [.multiple]),
            ("", [.missingID]),
        ]
        let sample = samples[currentSession.records.count % samples.count]
        let choices = Array("ABCDE")
        let answers = (0..<30).map { index in
            sample.1.contains(.blank) && index == 12 ? "" : String(choices[index % choices.count])
        }
        let record = ScanRecord(
            studentID: sample.0,
            formName: "30-question form",
            responses: answers,
            flags: sample.1
        )
        currentSession.records.insert(record, at: 0)
        log(
            sample.0.isEmpty ? "Captured a sheet with no student ID." : "Captured student \(sample.0).",
            kind: sample.1.isEmpty ? .success : .warning
        )
    }

    func removeRecords(at offsets: IndexSet) {
        currentSession.records.remove(atOffsets: offsets)
    }

    private func fail(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        scannerState = .failed(message: message)
        log(message, kind: .warning)
    }

    private func log(_ message: String, kind: ActivityEntry.Kind = .information) {
        activity.insert(ActivityEntry(time: .now, message: message, kind: kind), at: 0)
    }
}
