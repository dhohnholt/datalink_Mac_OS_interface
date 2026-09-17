import Foundation

enum ScannerTransportError: LocalizedError, Equatable {
    case noScannerFound
    case notConnected
    case dataModeCommandUnconfirmed
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .noScannerFound:
            "No DataLink 1200 was found. Check its USB connection and driver."
        case .notConnected:
            "Connect to the scanner before changing its mode."
        case .dataModeCommandUnconfirmed:
            "The Data Mode command has not been confirmed from a protocol capture yet."
        case .rejected(let reason):
            reason
        }
    }
}

protocol ScannerTransport: Sendable {
    func connect() async throws -> String
    func enterDataMode() async throws
    func disconnect() async
}

/// Safe UI transport used while the DataLink 1200 mode command is being decoded.
/// It mirrors the device state transitions without writing unverified bytes.
actor DemoScannerTransport: ScannerTransport {
    private var connected = false

    func connect() async throws -> String {
        try await Task.sleep(for: .milliseconds(450))
        connected = true
        return "/dev/cu.usbserial-1200 (Demo)"
    }

    func enterDataMode() async throws {
        guard connected else { throw ScannerTransportError.notConnected }
        try await Task.sleep(for: .milliseconds(550))
    }

    func disconnect() async {
        connected = false
    }
}

/// Evidence-backed protocol facts. Unknown commands remain nil so the app can
/// never accidentally transmit a guessed device-control instruction.
enum DataLinkProtocol {
    static let baudRate = 9_600
    static let versionCommand = Data("V".utf8)
    static let expectedVersionFragment = "ADV 1200OK"
    static let dataModeCommand: Data? = nil
}
