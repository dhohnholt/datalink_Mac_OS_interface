import Foundation

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case scan = "Scan"
    case sessions = "Sessions"
    case reports = "Reports"
    case protocolStatus = "Protocol status"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .scan: "doc.viewfinder"
        case .sessions: "tray.full"
        case .reports: "chart.bar.xaxis"
        case .protocolStatus: "wave.3.right"
        case .settings: "gearshape"
        }
    }
}

enum ScannerState: Equatable {
    case disconnected
    case connecting
    case connected(port: String)
    case enteringDataMode(port: String)
    case dataMode(port: String)
    case failed(message: String)

    var title: String {
        switch self {
        case .disconnected: "Scanner disconnected"
        case .connecting: "Finding scanner…"
        case .connected: "Scanner connected"
        case .enteringDataMode: "Entering Data Mode…"
        case .dataMode: "Ready to scan"
        case .failed: "Scanner needs attention"
        }
    }

    var detail: String {
        switch self {
        case .disconnected:
            "Connect the DataLink 1200 to begin."
        case .connecting:
            "Checking USB serial ports and identifying the scanner."
        case .connected(let port):
            "Connected on \(port). Enter Data Mode before feeding a sheet."
        case .enteringDataMode:
            "Waiting for the scanner to confirm its operating mode."
        case .dataMode(let port):
            "Data Mode is active on \(port). Feed one sheet at a time."
        case .failed(let message):
            message
        }
    }

    var port: String? {
        switch self {
        case .connected(let port), .enteringDataMode(let port), .dataMode(let port): port
        default: nil
        }
    }

    var isDataMode: Bool {
        if case .dataMode = self { return true }
        return false
    }
}

enum ScanFlag: String, Codable, CaseIterable {
    case blank = "Blank response"
    case multiple = "Multiple marks"
    case missingID = "Missing ID"
}

struct ScanRecord: Identifiable, Codable, Equatable {
    let id: UUID
    var studentID: String
    var formName: String
    var responses: [String]
    var flags: [ScanFlag]
    var scannedAt: Date

    init(
        id: UUID = UUID(),
        studentID: String,
        formName: String,
        responses: [String],
        flags: [ScanFlag] = [],
        scannedAt: Date = .now
    ) {
        self.id = id
        self.studentID = studentID
        self.formName = formName
        self.responses = responses
        self.flags = flags
        self.scannedAt = scannedAt
    }

    var answeredCount: Int {
        responses.filter { !$0.isEmpty }.count
    }
}

struct ScanSession: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var course: String
    var createdAt: Date
    var records: [ScanRecord]

    init(
        id: UUID = UUID(),
        name: String,
        course: String,
        createdAt: Date = .now,
        records: [ScanRecord] = []
    ) {
        self.id = id
        self.name = name
        self.course = course
        self.createdAt = createdAt
        self.records = records
    }
}

struct ActivityEntry: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let message: String
    let kind: Kind

    enum Kind {
        case information
        case success
        case warning
    }
}
