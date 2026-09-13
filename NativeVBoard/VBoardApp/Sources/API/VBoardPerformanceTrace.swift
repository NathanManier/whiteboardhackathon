import Foundation

/// One monotonic, privacy-safe performance timeline for an import or board open.
/// The identifier crosses HTTP boundaries; elapsed values never do, so clocks on
/// the iPad and server are not incorrectly subtracted from one another.
final class VBoardPerformanceTrace: @unchecked Sendable {
    static let header = "X-VBoard-Trace-ID"

    let id: String
    let operation: String
    private let origin: TimeInterval
    private let lock = NSLock()
    private var emittedStages = Set<String>()

    init(operation: String, id: String = UUID().uuidString.lowercased()) {
        self.id = id
        self.operation = operation
        self.origin = ProcessInfo.processInfo.systemUptime
        event("trace_start")
    }

    var elapsedMilliseconds: Double {
        max(0, (ProcessInfo.processInfo.systemUptime - origin) * 1_000)
    }

    func event(_ stage: String, durationMilliseconds: Double? = nil,
               fields: [String: CustomStringConvertible] = [:], once: Bool = false) {
        #if DEBUG
        if once {
            lock.lock()
            let inserted = emittedStages.insert(stage).inserted
            lock.unlock()
            guard inserted else { return }
        }
        let details = fields.keys.sorted().map { key in
            "\(key)=\(Self.safe(fields[key]?.description ?? "missing"))"
        }.joined(separator: " ")
        let duration = durationMilliseconds.map { String(format: " duration_ms=%.2f", $0) } ?? ""
        let suffix = details.isEmpty ? "" : " \(details)"
        print(String(format: "[VBoard] PERF TRACE trace=%@ side=native operation=%@ stage=%@ elapsed_ms=%.2f%@%@",
                     id, operation, stage, elapsedMilliseconds, duration, suffix))
        #endif
    }

    private static func safe(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .prefix(160).description
    }
}

@MainActor
final class VBoardPerformanceTraceRegistry {
    static let shared = VBoardPerformanceTraceRegistry()
    private var traces: [String: VBoardPerformanceTrace] = [:]
    private var order: [String] = []

    func bind(_ trace: VBoardPerformanceTrace, to boardID: String) {
        traces[boardID] = trace
        order.removeAll { $0 == boardID }
        order.append(boardID)
        while order.count > 32, let expired = order.first {
            order.removeFirst()
            traces.removeValue(forKey: expired)
        }
    }

    /// Continue an import through its first board open, then retire that
    /// binding. Every later cold/warm reopen is a distinct operation and must
    /// receive a fresh origin and trace identifier.
    func takeBoundTrace(for boardID: String, operation: String) -> VBoardPerformanceTrace {
        if let existing = traces.removeValue(forKey: boardID) {
            order.removeAll { $0 == boardID }
            return existing
        }
        return VBoardPerformanceTrace(operation: operation)
    }
}

private final class VBoardTaskMetricsDelegate: NSObject, URLSessionTaskDelegate,
                                                @unchecked Sendable {
    private let trace: VBoardPerformanceTrace
    private let endpoint: String
    private let attempt: String

    init(trace: VBoardPerformanceTrace, endpoint: String, attempt: String) {
        self.trace = trace
        self.endpoint = endpoint
        self.attempt = attempt
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last else { return }
        func milliseconds(_ start: Date?, _ end: Date?) -> String {
            guard let start, let end else { return "n/a" }
            return String(format: "%.2f", max(0, end.timeIntervalSince(start) * 1_000))
        }
        trace.event("urlsession_metrics", fields: [
            "endpoint": endpoint,
            "attempt": attempt,
            "redirects": metrics.redirectCount,
            "dns_ms": milliseconds(transaction.domainLookupStartDate,
                                    transaction.domainLookupEndDate),
            "connect_ms": milliseconds(transaction.connectStartDate,
                                        transaction.connectEndDate),
            "tls_ms": milliseconds(transaction.secureConnectionStartDate,
                                    transaction.secureConnectionEndDate),
            "ttfb_ms": milliseconds(transaction.requestStartDate,
                                     transaction.responseStartDate),
            "transfer_ms": milliseconds(transaction.responseStartDate,
                                         transaction.responseEndDate),
            "protocol": transaction.networkProtocolName ?? "unknown",
            "reused": transaction.isReusedConnection,
        ])
    }
}

extension VBoardPerformanceTrace {
    func metricsDelegate(endpoint: String, attempt: String) -> URLSessionTaskDelegate {
        VBoardTaskMetricsDelegate(trace: self, endpoint: endpoint, attempt: attempt)
    }
}

struct LibraryLoadSettlementTracker: Equatable {
    private(set) var inFlightThumbnails = 0
    private(set) var hasRenderedFirstFrame = false

    mutating func thumbnailStarted() { inFlightThumbnails += 1 }
    mutating func thumbnailFinished() { inFlightThumbnails = max(0, inFlightThumbnails - 1) }
    mutating func firstFrameRendered() { hasRenderedFirstFrame = true }

    var canSettle: Bool { hasRenderedFirstFrame && inFlightThumbnails == 0 }
}

/// A single cold-launch timeline. It deliberately records only stage names,
/// counts, durations, and asset byte sizes; account and board content never
/// enters diagnostics.
@MainActor
final class VBoardColdLaunchTrace {
    static let shared = VBoardColdLaunchTrace()

    private let trace = VBoardPerformanceTrace(operation: "cold_launch")
    private var tracker = LibraryLoadSettlementTracker()
    private var settleTask: Task<Void, Never>?

    func event(_ stage: String, durationMilliseconds: Double? = nil,
               fields: [String: CustomStringConvertible] = [:], once: Bool = true) {
        trace.event(stage, durationMilliseconds: durationMilliseconds,
                    fields: fields, once: once)
    }

    func libraryMetadataReady(boardCount: Int, folderCount: Int) {
        event("library_metadata_ready", fields: ["boards": boardCount, "folders": folderCount])
        scheduleSettlement()
    }

    func firstLibraryFrameRendered() {
        tracker.firstFrameRendered()
        event("first_library_frame")
        scheduleSettlement()
    }

    func thumbnailStarted(path: String) -> TimeInterval {
        tracker.thumbnailStarted()
        settleTask?.cancel()
        event("thumbnail_request", fields: ["asset": Self.safeAssetKind(path)], once: false)
        return ProcessInfo.processInfo.systemUptime
    }

    func thumbnailFinished(startedAt: TimeInterval, byteCount: Int, decoded: Bool) {
        tracker.thumbnailFinished()
        event("thumbnail_decode", durationMilliseconds:
                (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
              fields: ["bytes": byteCount, "decoded": decoded], once: false)
        scheduleSettlement()
    }

    private func scheduleSettlement() {
        settleTask?.cancel()
        guard tracker.canSettle else { return }
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, self.tracker.canSettle else { return }
            self.event("library_settled")
        }
    }

    private static func safeAssetKind(_ path: String) -> String {
        (path as NSString).pathExtension.lowercased().isEmpty
            ? "unknown" : (path as NSString).pathExtension.lowercased()
    }
}
