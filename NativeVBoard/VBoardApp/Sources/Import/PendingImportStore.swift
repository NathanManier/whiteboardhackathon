import Foundation
import UniformTypeIdentifiers

struct PendingImport: Codable, Identifiable, Hashable {
    let id: String
    let filename: String
    let contentType: String
    let createdAt: Double

    var isPDF: Bool { UTType(contentType)?.conforms(to: .pdf) == true || filename.lowercased().hasSuffix(".pdf") }
}

enum PendingImportStore {
    static let appGroupID = "group.com.vboard.ipad"
    private static let retention: TimeInterval = 7 * 24 * 60 * 60

    static func pendingDirectory(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("PendingImports", isDirectory: true)
    }

    static func current(fileManager: FileManager = .default) -> PendingImport? {
        cleanup(fileManager: fileManager)
        guard let directory = pendingDirectory(fileManager: fileManager),
              let manifests = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
              ) else { return nil }
        return manifests
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(PendingImport.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
            .first
    }

    static func fileURL(for item: PendingImport, fileManager: FileManager = .default) -> URL? {
        pendingDirectory(fileManager: fileManager)?
            .appendingPathComponent(item.id, isDirectory: true)
            .appendingPathComponent(item.filename)
    }

    static func remove(_ item: PendingImport, fileManager: FileManager = .default) {
        guard let directory = pendingDirectory(fileManager: fileManager) else { return }
        try? fileManager.removeItem(at: directory.appendingPathComponent(item.id, isDirectory: true))
        try? fileManager.removeItem(at: directory.appendingPathComponent("\(item.id).json"))
    }

    static func cleanup(fileManager: FileManager = .default, now: Date = Date()) {
        guard let directory = pendingDirectory(fileManager: fileManager),
              let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        let cutoff = now.timeIntervalSince1970 - retention
        for manifestURL in files where manifestURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: manifestURL),
                  let item = try? JSONDecoder().decode(PendingImport.self, from: data),
                  item.createdAt < cutoff else { continue }
            remove(item, fileManager: fileManager)
        }
    }
}
