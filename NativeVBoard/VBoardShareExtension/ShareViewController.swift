import UIKit
import UniformTypeIdentifiers

private struct PendingImport: Codable {
    let id: String
    let filename: String
    let contentType: String
    let createdAt: Double
}

final class ShareViewController: UIViewController {
    private let appGroupID = "group.com.vboard.ipad"
    private let statusLabel = UILabel()
    private let importButton = UIButton(type: .system)
    private var provider: NSItemProvider?
    private var typeIdentifier: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.text = "Preparing your Freeform export…"
        importButton.configuration = .filled()
        importButton.configuration?.title = "Import into V-Board"
        importButton.addTarget(self, action: #selector(importItem), for: .touchUpInside)
        importButton.isEnabled = false
        let stack = UIStackView(arrangedSubviews: [statusLabel, importButton])
        stack.axis = .vertical; stack.spacing = 22; stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            importButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])
        resolveAttachment()
    }

    private func resolveAttachment() {
        let providers = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []
        let accepted = [UTType.pdf.identifier, UTType.image.identifier]
        for provider in providers {
            if let identifier = accepted.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) {
                self.provider = provider; typeIdentifier = identifier
                statusLabel.text = identifier == UTType.pdf.identifier
                    ? "Import this PDF into V-Board. You’ll choose its lecture in the app."
                    : "Import this image into V-Board. You’ll confirm it in the app."
                importButton.isEnabled = true
                return
            }
        }
        statusLabel.text = "V-Board can import PDFs and images."
    }

    @objc private func importItem() {
        guard let provider, let typeIdentifier else { return }
        importButton.isEnabled = false
        statusLabel.text = "Saving for V-Board…"
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] source, error in
            guard let self, let source, error == nil else {
                DispatchQueue.main.async { self?.showFailure() }
                return
            }
            do {
                let manager = FileManager.default
                guard let root = manager.containerURL(forSecurityApplicationGroupIdentifier: self.appGroupID)?
                    .appendingPathComponent("PendingImports", isDirectory: true) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let id = UUID().uuidString.lowercased()
                let itemDirectory = root.appendingPathComponent(id, isDirectory: true)
                try manager.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
                let fallback = typeIdentifier == UTType.pdf.identifier ? "Freeform.pdf" : "Whiteboard.jpg"
                let rawName = source.lastPathComponent.isEmpty ? fallback : source.lastPathComponent
                let filename = rawName.replacingOccurrences(of: "/", with: "-")
                try manager.copyItem(at: source, to: itemDirectory.appendingPathComponent(filename))
                let item = PendingImport(id: id, filename: filename, contentType: typeIdentifier,
                                         createdAt: Date().timeIntervalSince1970)
                let manifest = try JSONEncoder().encode(item)
                try manifest.write(to: root.appendingPathComponent("\(id).json"), options: .atomic)
                DispatchQueue.main.async {
                    self.statusLabel.text = "Ready in V-Board"
                    self.extensionContext?.completeRequest(returningItems: nil)
                }
            } catch {
                DispatchQueue.main.async { self.showFailure() }
            }
        }
    }

    private func showFailure() {
        statusLabel.text = "This item couldn’t be prepared. Try sharing it again."
        importButton.isEnabled = true
    }
}
