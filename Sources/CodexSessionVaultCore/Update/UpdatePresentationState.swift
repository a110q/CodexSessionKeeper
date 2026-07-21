public enum UpdatePresentationState: Equatable, Sendable {
    case idle
    case checking
    case available(version: String, notes: [String])
    case downloading(version: String, received: UInt64, total: UInt64?)
    case extracting(version: String, progress: Double)
    case ready(version: String)
    case installing(version: String)
    case failed(message: String)
    case upToDate(version: String)
    case completed(version: String)
}

public enum UpdatePresentationEvent: Equatable, Sendable {
    case checkStarted
    case found(version: String, notes: [String])
    case downloadStarted(version: String)
    case downloadProgress(version: String, received: UInt64, total: UInt64?)
    case extractionProgress(version: String, progress: Double)
    case downloadReady(version: String)
    case installStarted(version: String)
    case failed(message: String)
    case upToDate(version: String)
    case completed(version: String)
    case dismiss
}

public struct UpdatePresentationMachine: Equatable, Sendable {
    public private(set) var state: UpdatePresentationState = .idle

    public init() {}

    public mutating func apply(_ event: UpdatePresentationEvent) {
        switch event {
        case .checkStarted:
            state = .checking
        case .found(let version, let notes):
            state = .available(version: version, notes: notes)
        case .downloadStarted(let version):
            state = .downloading(version: version, received: 0, total: nil)
        case .downloadProgress(let version, let received, let total):
            state = .downloading(version: version, received: received, total: total)
        case .extractionProgress(let version, let progress):
            state = .extracting(version: version, progress: min(max(progress, 0), 1))
        case .downloadReady(let version):
            state = .ready(version: version)
        case .installStarted(let version):
            state = .installing(version: version)
        case .failed(let message):
            state = .failed(message: message)
        case .upToDate(let version):
            state = .upToDate(version: version)
        case .completed(let version):
            state = .completed(version: version)
        case .dismiss:
            state = .idle
        }
    }
}

