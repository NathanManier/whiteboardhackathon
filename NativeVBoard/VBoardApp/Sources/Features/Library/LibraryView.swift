import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import PDFKit

struct LibraryView: View {
    @EnvironmentObject private var api: APIClient
    let account: AccountUser
    @State private var library: LibraryResponse?
    @State private var error: String?
    @State private var showImporter = false
    @State private var showNewLecture = false
    @State private var launchBoard: LibraryBoard?
    @State private var showAccount = false
    @State private var pendingImport: PendingImport?

    var body: some View {
        NavigationStack {
            Group {
                if let library {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            LibraryHero { showImporter = true }
                            if library.folders.isEmpty && library.boards.isEmpty {
                                EmptyLibraryView { showImporter = true }
                            } else {
                                if !library.folders.isEmpty {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Label("Lectures", systemImage: "rectangle.stack.fill").font(.title3.weight(.semibold))
                                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                                            ForEach(library.folders) { folder in
                                                NavigationLink { LectureWorkspaceView(folder: folder) } label: { LectureCard(folder: folder) }.buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack { Label("Recent whiteboards", systemImage: "rectangle.on.rectangle").font(.title3.weight(.semibold)); Spacer(); Text("\(library.boards.count)").foregroundStyle(.secondary) }
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
                                        ForEach(library.boards) { board in
                                            NavigationLink { destination(for: board, in: library) } label: { BoardCard(board: board) }.buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }.padding(24).frame(maxWidth: 1100, alignment: .leading)
                    }
                } else if let error {
                    ContentUnavailableView("Couldn’t load your library", systemImage: "wifi.exclamationmark", description: Text(error)).overlay(alignment: .bottom) { Button("Retry") { load() }.buttonStyle(.borderedProminent).padding(.bottom, 32) }
                } else { ProgressView("Loading your library…") }
            }
            .navigationTitle("V-Board")
            .toolbar { ToolbarItem(placement: .primaryAction) { Menu { Button { showImporter = true } label: { Label("Import Whiteboard", systemImage: "photo.badge.plus") }; Button { showNewLecture = true } label: { Label("New Lecture", systemImage: "books.vertical") } } label: { Image(systemName: "plus") }.accessibilityLabel("Add to V-Board") }; ToolbarItemGroup(placement: .secondaryAction) { Button { load() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh library"); Button { showAccount = true } label: { Image(systemName: "person.crop.circle") }.accessibilityLabel("Account") } }
            .sheet(isPresented: $showImporter) { ImportFlowView { board in launchBoard = board; showImporter = false; load() } }
            .sheet(isPresented: $showNewLecture) { NewLectureView { showNewLecture = false; load() } }
            .sheet(isPresented: $showAccount) { AccountView(user: account) }
            .sheet(item: $pendingImport) { item in
                ImportFlowView(pendingImport: item) { board in
                    PendingImportStore.remove(item)
                    pendingImport = nil
                    launchBoard = board
                    load()
                }
            }
            .navigationDestination(item: $launchBoard) { board in
                if let library { destination(for: board, in: library) }
                else { BoardView(board: board) }
            }
            .task { load(); discoverPendingImport() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in discoverPendingImport() }
        }
    }

    private func load() {
        Task {
            do {
                let result = try await api.library(); library = result; error = nil
                if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-VBoardOpenID"), index + 1 < ProcessInfo.processInfo.arguments.count { launchBoard = result.boards.first(where: { $0.id == ProcessInfo.processInfo.arguments[index + 1] }) }
            } catch { self.error = "Check your connection and try again." }
        }
    }

    private func discoverPendingImport() {
        guard !showImporter, pendingImport == nil else { return }
        pendingImport = PendingImportStore.current()
    }

    @ViewBuilder
    private func destination(for board: LibraryBoard, in library: LibraryResponse) -> some View {
        if let folderID = board.folderID,
           let folder = library.folders.first(where: { $0.id == folderID }) {
            LectureWorkspaceView(folder: folder, focusBoardID: board.id)
        } else {
            BoardView(board: board)
        }
    }
}

private struct LibraryHero: View {
    let add: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("V-Board").font(.title.weight(.semibold))
            Text("Turn a physical whiteboard into editable ink you can study.").font(.title2).fixedSize(horizontal: false, vertical: true)
            Text("Import a photo, keep the professor’s geometry intact, and annotate the same board.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(action: add) { Label("Import Whiteboard", systemImage: "photo.badge.plus") }.buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 4)
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(.vertical, 12)
    }
}

private struct EmptyLibraryView: View {
    let add: () -> Void
    var body: some View { VStack(spacing: 14) { Image(systemName: "photo.on.rectangle.angled").font(.system(size: 48)).foregroundStyle(.tint); Text("No whiteboards yet").font(.title2.weight(.semibold)); Text("Photograph or import a physical whiteboard to create an editable study canvas.").multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 430); Button("Add Whiteboard", action: add).buttonStyle(.borderedProminent).controlSize(.large) }.frame(maxWidth: .infinity).padding(.vertical, 64) }
}

private struct LectureCard: View {
    let folder: LectureFolder
    var body: some View { VStack(alignment: .leading, spacing: 8) { Label(folder.name, systemImage: "books.vertical").font(.headline); Text("\(folder.boardOrder.count) whiteboard\(folder.boardOrder.count == 1 ? "" : "s")").font(.subheadline).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14).overlay(alignment: .bottom) { Rectangle().fill(.quaternary).frame(height: 1) } }
}

private struct BoardCard: View {
    @EnvironmentObject private var api: APIClient
    let board: LibraryBoard
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(0.45))
                .frame(height: 130)
                .overlay {
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Image(systemName: board.status == "ready" ? "photo" : "clock")
                            .font(.title2).foregroundStyle(.secondary)
                    }
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(board.name).font(.headline).lineLimit(2)
            Text(board.status.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: board.thumbnailURL) {
            guard let path = board.thumbnailURL else { return }
            thumbnail = (try? await api.authorizedAsset(path: path)).flatMap(UIImage.init(data:))
        }
    }
}

private struct RenamePrompt: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onSave: (String) -> Void
    @State private var value: String
    init(title: String, value: String, onSave: @escaping (String) -> Void) { self.title = title; self.onSave = onSave; _value = State(initialValue: value) }
    var body: some View { NavigationStack { Form { TextField("Name", text: $value) }.navigationTitle(title).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines); if !trimmed.isEmpty { onSave(trimmed); dismiss() } }.disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } } } }
}

struct ImportFlowView: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let folderID: String?
    let pendingImport: PendingImport?
    let onComplete: (LibraryBoard) -> Void
    @State private var pickerItem: PhotosPickerItem?
    @State private var imageAsset: NormalizedImageAsset?
    @State private var previewImage: UIImage?
    @State private var pdfData: Data?
    @State private var pdfFilename = "Freeform.pdf"
    @State private var pdfPageCount = 0
    @State private var importFileKind: ImportFileKind = .image
    @State private var fileImporter = false
    @State private var showCamera = false
    @State private var name = ""
    @State private var importState = ImportFlowStateMachine()
    @State private var boardID: String?
    @State private var sourcePixelSize = CGSize.zero
    @State private var corners: [CGPoint] = []
    @State private var cornerPreviewRect = CGRect.zero
    @State private var cornerPreviewGlobalOrigin = CGPoint.zero
    @State private var error: String?
    @State private var availableLectures: [LectureFolder] = []
    @State private var selectedFolderID: String?
    @State private var createLecture = false
    @State private var newLectureName = ""
    @State private var activeTask: Task<Void, Never>?
    init(folderID: String? = nil, pendingImport: PendingImport? = nil,
         onComplete: @escaping (LibraryBoard) -> Void) {
        self.folderID = folderID; self.pendingImport = pendingImport; self.onComplete = onComplete
    }
    var body: some View {
        NavigationStack { Group { switch importState.phase { case .choosing: chooseView; case .previewing: previewView; case .needsCorners: cornerView; case .uploading, .submittingCorners, .importingPDF, .completed: processingView } }.navigationTitle(importState.phase.title).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancelAndDismiss() } } } }
            .fileImporter(isPresented: $fileImporter, allowedContentTypes: importFileKind == .pdf ? [.pdf] : [.image]) { result in
                if case .success(let url) = result { Task { await loadFile(url) } }
            }
            .sheet(isPresented: $showCamera) {
                CameraCaptureView(onCapture: { captured in
                    showCamera = false
                    Task { await loadCapturedImage(captured) }
                }, onCancel: { showCamera = false })
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    defer { pickerItem = nil }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            error = "That photo could not be opened."
                            return
                        }
                        await loadImageData(data)
                    } catch {
                        self.error = "That photo could not be opened."
                    }
                }
            }
            .task {
                if folderID == nil { availableLectures = (try? await api.library().folders) ?? [] }
                if let pendingImport, let url = PendingImportStore.fileURL(for: pendingImport) {
                    await loadFile(url)
                }
            }
            .onDisappear {
                activeTask?.cancel()
                activeTask = nil
                pickerItem = nil
                fileImporter = false
                showCamera = false
                importState.cancel()
            }
    }
    private var chooseView: some View { VStack(spacing: 18) { Image(systemName: "photo.badge.plus").font(.system(size: 52)).foregroundStyle(.tint); Text("Add to V-Board").font(.largeTitle.bold()); Text(folderID == nil ? "Import a physical whiteboard or a digital canvas." : "Add another board to this lecture.").foregroundStyle(.secondary); VStack(spacing: 12) { Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }.buttonStyle(.borderedProminent).controlSize(.large); PhotosPicker(selection: $pickerItem, matching: .images) { Label("Choose from Photos", systemImage: "photo.on.rectangle") }.buttonStyle(.bordered).controlSize(.large); Button { importFileKind = .pdf; fileImporter = true } label: { Label("Freeform / PDF", systemImage: "doc.richtext") }.buttonStyle(.bordered).controlSize(.large); Button { importFileKind = .image; fileImporter = true } label: { Label("Import Image File", systemImage: "folder") }.buttonStyle(.bordered).controlSize(.large) }.padding(.top, 12); Text("In Freeform, export your board as a PDF and share or import it into V-Board.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: 520).padding(30) }
    private var previewView: some View { ScrollView { VStack(spacing: 18) { if let previewImage { Image(uiImage: previewImage).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal) }; if pdfData != nil { Label(pdfPageCount == 1 ? "1 PDF page" : "\(pdfPageCount) PDF pages", systemImage: "doc.richtext").font(.headline); if pdfPageCount > 1 { Text("Each page will become a separate board in source order.").font(.subheadline).foregroundStyle(.secondary) } }; TextField("Board name (optional)", text: $name).textFieldStyle(.roundedBorder).padding(.horizontal); destinationControls; Button(pdfData == nil ? "Use This Photo" : "Import PDF") { pdfData == nil ? beginImageUpload() : beginPDFUpload() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(importState.phase.isBusy); if let error { Text(error).foregroundStyle(.red).multilineTextAlignment(.center) } }.padding(.vertical, 20).frame(maxWidth: 700) }.frame(maxWidth: .infinity) }
    @ViewBuilder private var destinationControls: some View { if folderID == nil { VStack(alignment: .leading, spacing: 10) { Toggle("Create a new lecture", isOn: $createLecture); if createLecture { TextField("Lecture name", text: $newLectureName).textFieldStyle(.roundedBorder) } else if !availableLectures.isEmpty { Picker("Add to lecture", selection: $selectedFolderID) { Text("No lecture").tag(String?.none); ForEach(availableLectures) { lecture in Text(lecture.name).tag(Optional(lecture.id)) } }.pickerStyle(.menu) } }.padding(.horizontal) } }
    private var cornerView: some View {
        VStack(spacing: 0) {
            if let imageAsset {
                GeometryReader { proxy in
                    let mapper = AspectFitImageTransform(sourcePixelSize: sourcePixelSize,
                                                         containerRect: CGRect(origin: .zero, size: proxy.size))
                    ZStack {
                        Image(uiImage: imageAsset.image)
                            .resizable()
                            .frame(width: mapper.imageRect.width, height: mapper.imageRect.height)
                            .position(x: mapper.imageRect.midX, y: mapper.imageRect.midY)
                        Path { path in
                            for index in corners.indices {
                                let point = mapper.sourcePixelToView(corners[index])
                                index == corners.startIndex ? path.move(to: point) : path.addLine(to: point)
                            }
                            if corners.count == 4 { path.closeSubpath() }
                        }
                        .stroke(.yellow, lineWidth: 3)
                        .allowsHitTesting(false)
                        ForEach(corners.indices, id: \.self) { index in
                            Circle()
                                .fill(.yellow)
                                .overlay(Text(CornerRole(index: index).label).font(.caption2.bold()).foregroundStyle(.black))
                                .frame(width: 36, height: 36)
                                .contentShape(Circle().inset(by: -12))
                                .position(mapper.sourcePixelToView(corners[index]))
                                .gesture(DragGesture(coordinateSpace: .named("cornerPreview"))
                                    .onChanged { value in corners[index] = mapper.viewToSourcePixel(value.location) })
                        }
                    }
                    .coordinateSpace(name: "cornerPreview")
                    .onAppear { rememberCornerPreview(proxy: proxy, mapper: mapper) }
                    .onChange(of: proxy.size) { _, _ in rememberCornerPreview(proxy: proxy, mapper: mapper) }
                }
                .padding()
            }
            VStack(spacing: 8) {
                Text("Drag the corners to fit the board").foregroundStyle(.secondary)
                Button("Process Whiteboard") { beginCornerSubmission() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(importState.phase.isBusy)
                if let error { Text(error).foregroundStyle(.red).multilineTextAlignment(.center) }
            }
            .padding(.bottom, 18)
        }
    }
    private var processingView: some View { VStack(spacing: 22) { ProgressView().controlSize(.large); Text(importState.phase.processingTitle).font(.title2.weight(.semibold)); Text(pdfData == nil ? "Preparing image • Correcting perspective • Finding ink • Creating vectors" : "Preserving source quality • Preparing page previews • Adding boards to your lecture").multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 30) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
    private func loadImageData(_ data: Data) async {
        let normalized = await Task.detached(priority: .userInitiated) {
            NormalizedImageAsset.make(data: data)
        }.value
        guard let normalized else {
            error = "That image could not be read."
            return
        }
        install(normalized)
    }
    private func loadCapturedImage(_ image: UIImage) async {
        let normalized = await Task.detached(priority: .userInitiated) {
            NormalizedImageAsset.make(image: image)
        }.value
        guard let normalized else {
            error = "That photo could not be prepared."
            return
        }
        install(normalized)
    }
    private func install(_ normalized: NormalizedImageAsset) {
        activeTask?.cancel(); activeTask = nil
        pdfData = nil
        pdfPageCount = 0
        imageAsset = normalized
        previewImage = normalized.image
        sourcePixelSize = normalized.pixelSize
        corners = CornerGeometry.defaultCorners(sourceSize: normalized.pixelSize)
        boardID = nil
        error = nil
        importState.sourceSelected()
    }
    private func loadFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url, options: .mappedIfSafe)
            }.value
            if url.pathExtension.lowercased() == "pdf" {
                guard let document = PDFDocument(data: data), document.pageCount > 0,
                      let page = document.page(at: 0) else {
                    self.error = "That PDF could not be read."
                    return
                }
                imageAsset = nil
                sourcePixelSize = .zero
                corners = []
                pdfData = data
                pdfFilename = url.lastPathComponent
                pdfPageCount = document.pageCount
                previewImage = page.thumbnail(of: CGSize(width: 1100, height: 1100), for: .cropBox)
                if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
                error = nil
                importState.sourceSelected()
            } else {
                await loadImageData(data)
            }
        } catch {
            self.error = "The selected file could not be opened."
        }
    }
    private func resolvedFolderID() async throws -> String? { if let folderID { return folderID }; if createLecture { let trimmed = newLectureName.trimmingCharacters(in: .whitespacesAndNewlines); guard !trimmed.isEmpty else { throw ImportUIError.missingLectureName }; return try await api.createLecture(name: trimmed).id }; return selectedFolderID }
    private func beginImageUpload() {
        guard imageAsset != nil, pdfData == nil else { return }
        let operationID = UUID()
        guard importState.beginImageUpload(operationID) else { return }
        error = nil
        activeTask = Task { await upload(operationID: operationID) }
    }
    private func beginPDFUpload() {
        guard pdfData != nil else { return }
        let operationID = UUID()
        guard importState.beginPDFUpload(operationID) else { return }
        error = nil
        activeTask = Task { await uploadPDF(operationID: operationID) }
    }
    private func beginCornerSubmission() {
        guard let boardID else { return }
        if let reason = CornerGeometry.validationMessage(corners, sourceSize: sourcePixelSize) {
            error = reason
            return
        }
        let operationID = UUID()
        guard importState.beginCornerSubmission(operationID) else { return }
        error = nil
        debugCornerSubmission(boardID: boardID, operationID: operationID)
        activeTask = Task { await process(operationID: operationID) }
    }
    private func upload(operationID: UUID) async {
        guard let imageAsset else { return }
        do {
            let target = try await resolvedFolderID()
            let result = try await api.upload(imageData: imageAsset.uploadData, filename: "whiteboard.jpg", mimeType: "image/jpeg", folderID: target, name: name.isEmpty ? nil : name)
            guard importState.phase == .uploading(operationID), !Task.isCancelled else { return }
            boardID = result.id
            let record = try await api.board(id: result.id)
            guard importState.phase == .uploading(operationID), !Task.isCancelled else { return }
            let serverSize = record.dimensions.map { CGSize(width: $0.width, height: $0.height) } ?? imageAsset.pixelSize
            #if DEBUG
            let cgPixels = imageAsset.image.cgImage.map { "\($0.width)x\($0.height)" } ?? "missing"
            print("[VBoard] IMAGE UPLOAD CONTRACT board=\(result.id) normalizedPixels=\(imageAsset.pixelSize) serverPixels=\(serverSize) uiOrientation=\(imageAsset.image.imageOrientation.rawValue) cgPixels=\(cgPixels)")
            #endif
            sourcePixelSize = serverSize
            corners = record.suggestedCorners?.compactMap { point in
                guard point.count == 2 else { return nil }
                return CGPoint(x: point[0], y: point[1])
            } ?? CornerGeometry.defaultCorners(sourceSize: serverSize)
            if corners.count != 4 { corners = CornerGeometry.defaultCorners(sourceSize: serverSize) }
            activeTask = nil
            _ = importState.requireCorners(after: operationID)
        } catch {
            guard importState.phase == .uploading(operationID), !Task.isCancelled else { return }
            activeTask = nil
            _ = importState.failToPreview(operationID)
            self.error = error is ImportUIError ? error.localizedDescription : "Couldn’t upload this photo. Try again."
        }
    }
    private func uploadPDF(operationID: UUID) async {
        guard let pdfData else { return }
        do {
            let target = try await resolvedFolderID()
            let result = try await api.importPDF(data: pdfData, filename: pdfFilename, folderID: target, name: name.isEmpty ? nil : name)
            guard importState.phase == .importingPDF(operationID), !Task.isCancelled else { return }
            guard let first = result.boards.first else { throw ImportUIError.emptyImport }
            activeTask = nil
            _ = importState.complete(operationID)
            onComplete(first)
        } catch {
            guard importState.phase == .importingPDF(operationID), !Task.isCancelled else { return }
            activeTask = nil
            _ = importState.failToPreview(operationID)
            self.error = error is ImportUIError ? error.localizedDescription : "Couldn’t import this PDF. Your selected file is still here so you can try again."
        }
    }
    private func process(operationID: UUID) async {
        guard let boardID else { return }
        let pixels = corners.map { [Double($0.x), Double($0.y)] }
        let normalized = corners.map {
            ["x": Double($0.x) / max(Double(sourcePixelSize.width - 1), 1),
             "y": Double($0.y) / max(Double(sourcePixelSize.height - 1), 1)]
        }
        do {
            _ = try await api.processCorners(boardID: boardID, corners: pixels, normalizedCorners: normalized)
            guard importState.phase == .submittingCorners(operationID), !Task.isCancelled else { return }
            let result = try await api.library()
            guard importState.phase == .submittingCorners(operationID), !Task.isCancelled else { return }
            if let board = result.boards.first(where: { $0.id == boardID }) {
                activeTask = nil
                _ = importState.complete(operationID)
                onComplete(board)
            } else {
                activeTask = nil
                self.error = "The board was processed, but could not be reopened."
                _ = importState.failToCorners(operationID)
            }
        } catch {
            guard importState.phase == .submittingCorners(operationID), !Task.isCancelled else { return }
            activeTask = nil
            _ = importState.failToCorners(operationID)
            self.error = "Those corners couldn’t be used. Adjust them and try again."
        }
    }
    private func rememberCornerPreview(proxy: GeometryProxy, mapper: AspectFitImageTransform) {
        cornerPreviewRect = mapper.imageRect
        cornerPreviewGlobalOrigin = proxy.frame(in: .global).origin
    }
    private func debugCornerSubmission(boardID: String, operationID: UUID) {
        #if DEBUG
        let actualLocal = corners.map { point in
            CGPoint(
                x: cornerPreviewRect.minX + point.x / max(sourcePixelSize.width - 1, 1) * cornerPreviewRect.width,
                y: cornerPreviewRect.minY + point.y / max(sourcePixelSize.height - 1, 1) * cornerPreviewRect.height
            )
        }
        let screen = actualLocal.map { CGPoint(x: $0.x + cornerPreviewGlobalOrigin.x, y: $0.y + cornerPreviewGlobalOrigin.y) }
        let payload = corners.map { [Double($0.x), Double($0.y)] }
        let cgPixels = imageAsset?.image.cgImage.map { "\($0.width)x\($0.height)" } ?? "missing"
        print("[VBoard] CORNER SUBMISSION request=\(operationID.uuidString) board=\(boardID) encodedPixels=\(sourcePixelSize) displayedOrientation=up uiOrientation=\(imageAsset?.image.imageOrientation.rawValue ?? -1) cgPixels=\(cgPixels) previewImageRect=\(cornerPreviewRect) handlePreviewLocal=\(actualLocal) handleScreen=\(screen) normalized=\(corners.map { CGPoint(x: $0.x / max(sourcePixelSize.width - 1, 1), y: $0.y / max(sourcePixelSize.height - 1, 1)) }) sourcePixels=\(payload)")
        #endif
    }
    private func cancelAndDismiss() {
        activeTask?.cancel()
        activeTask = nil
        importState.cancel()
        pickerItem = nil
        fileImporter = false
        showCamera = false
        dismiss()
    }
}

private enum ImportFileKind { case image, pdf }
private enum ImportUIError: LocalizedError {
    case missingLectureName, emptyImport
    var errorDescription: String? { switch self { case .missingLectureName: return "Enter a name for the new lecture."; case .emptyImport: return "The PDF did not contain an importable page." } }
}

enum ImportFlowPhase: Equatable {
    case choosing
    case previewing
    case uploading(UUID)
    case needsCorners
    case submittingCorners(UUID)
    case importingPDF(UUID)
    case completed

    var isBusy: Bool {
        switch self {
        case .uploading, .submittingCorners, .importingPDF: return true
        default: return false
        }
    }
    var title: String {
        switch self {
        case .choosing: return "New Whiteboard"
        case .previewing: return "Preview"
        case .needsCorners: return "Confirm Board"
        case .uploading, .submittingCorners, .importingPDF, .completed: return "Processing"
        }
    }
    var processingTitle: String {
        switch self {
        case .uploading: return "Uploading photo…"
        case .submittingCorners: return "Creating your editable board…"
        case .importingPDF: return "Importing your PDF…"
        default: return "Finishing import…"
        }
    }
}

struct ImportFlowStateMachine: Equatable {
    private(set) var phase: ImportFlowPhase = .choosing

    mutating func sourceSelected() { phase = .previewing }

    mutating func beginImageUpload(_ id: UUID) -> Bool {
        guard phase == .previewing else { return false }
        phase = .uploading(id)
        return true
    }

    mutating func beginPDFUpload(_ id: UUID) -> Bool {
        guard phase == .previewing else { return false }
        phase = .importingPDF(id)
        return true
    }

    mutating func beginCornerSubmission(_ id: UUID) -> Bool {
        guard phase == .needsCorners else { return false }
        phase = .submittingCorners(id)
        return true
    }

    mutating func requireCorners(after id: UUID) -> Bool {
        guard phase == .uploading(id) else { return false }
        phase = .needsCorners
        return true
    }

    mutating func failToPreview(_ id: UUID) -> Bool {
        guard phase == .uploading(id) || phase == .importingPDF(id) else { return false }
        phase = .previewing
        return true
    }

    mutating func failToCorners(_ id: UUID) -> Bool {
        guard phase == .submittingCorners(id) else { return false }
        phase = .needsCorners
        return true
    }

    mutating func complete(_ id: UUID) -> Bool {
        guard phase == .submittingCorners(id) || phase == .importingPDF(id) else { return false }
        phase = .completed
        return true
    }

    mutating func cancel() { phase = .choosing }
}

struct AspectFitImageTransform: Equatable {
    let sourcePixelSize: CGSize
    let containerRect: CGRect

    var imageRect: CGRect {
        guard sourcePixelSize.width > 0, sourcePixelSize.height > 0,
              containerRect.width > 0, containerRect.height > 0 else { return .zero }
        let scale = min(containerRect.width / sourcePixelSize.width,
                        containerRect.height / sourcePixelSize.height)
        let size = CGSize(width: sourcePixelSize.width * scale,
                          height: sourcePixelSize.height * scale)
        return CGRect(x: containerRect.midX - size.width / 2,
                      y: containerRect.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    func sourcePixelToView(_ point: CGPoint) -> CGPoint {
        let rect = imageRect
        let maxX = max(sourcePixelSize.width - 1, 1)
        let maxY = max(sourcePixelSize.height - 1, 1)
        return CGPoint(x: rect.minX + point.x / maxX * rect.width,
                       y: rect.minY + point.y / maxY * rect.height)
    }

    func viewToSourcePixel(_ point: CGPoint) -> CGPoint {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return .zero }
        let x = min(max(point.x, rect.minX), rect.maxX)
        let y = min(max(point.y, rect.minY), rect.maxY)
        return CGPoint(x: (x - rect.minX) / rect.width * max(sourcePixelSize.width - 1, 1),
                       y: (y - rect.minY) / rect.height * max(sourcePixelSize.height - 1, 1))
    }
}

struct NormalizedImageAsset: @unchecked Sendable {
    let image: UIImage
    let uploadData: Data
    let pixelSize: CGSize

    static func make(data: Data) -> NormalizedImageAsset? {
        guard let image = UIImage(data: data) else { return nil }
        return make(image: image)
    }

    static func make(image: UIImage) -> NormalizedImageAsset? {
        guard let source = image.cgImage else { return nil }
        let swapsAxes: Bool
        switch image.imageOrientation {
        case .left, .leftMirrored, .right, .rightMirrored: swapsAxes = true
        default: swapsAxes = false
        }
        let pixelSize = CGSize(width: swapsAxes ? source.height : source.width,
                               height: swapsAxes ? source.width : source.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        let normalized = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pixelSize))
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
        guard normalized.imageOrientation == .up,
              let cgImage = normalized.cgImage,
              cgImage.width == Int(pixelSize.width), cgImage.height == Int(pixelSize.height),
              let jpeg = normalized.jpegData(compressionQuality: 0.96) else { return nil }
        return NormalizedImageAsset(image: normalized, uploadData: jpeg, pixelSize: pixelSize)
    }
}

enum CornerGeometry {
    static func defaultCorners(sourceSize: CGSize) -> [CGPoint] {
        let maxX = max(sourceSize.width - 1, 0)
        let maxY = max(sourceSize.height - 1, 0)
        return [CGPoint(x: maxX * 0.05, y: maxY * 0.05),
                CGPoint(x: maxX * 0.95, y: maxY * 0.05),
                CGPoint(x: maxX * 0.95, y: maxY * 0.95),
                CGPoint(x: maxX * 0.05, y: maxY * 0.95)]
    }

    static func validationMessage(_ points: [CGPoint], sourceSize: CGSize) -> String? {
        guard points.count == 4 else { return "Four corners are required." }
        let maxX = sourceSize.width - 1
        let maxY = sourceSize.height - 1
        guard maxX > 0, maxY > 0 else { return "The source image dimensions are invalid." }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return "Every corner must be a finite point." }
        guard points.allSatisfy({ $0.x >= 0 && $0.x <= maxX && $0.y >= 0 && $0.y <= maxY }) else { return "Keep every corner inside the photo." }
        let minimumSeparation = max(2, min(sourceSize.width, sourceSize.height) * 0.005)
        for first in points.indices {
            for second in points.indices where second > first {
                if hypot(points[first].x - points[second].x, points[first].y - points[second].y) < minimumSeparation {
                    return "Move the corner handles farther apart."
                }
            }
        }
        guard !segmentsIntersect(points[0], points[1], points[2], points[3]),
              !segmentsIntersect(points[1], points[2], points[3], points[0]) else {
            return "The board outline cannot cross itself."
        }
        let crosses = points.indices.map { index -> CGFloat in
            let a = points[index]
            let b = points[(index + 1) % points.count]
            let c = points[(index + 2) % points.count]
            return cross(a, b, c)
        }
        guard crosses.allSatisfy({ $0 > 0 }) || crosses.allSatisfy({ $0 < 0 }) else {
            return "The corners must form a valid board outline."
        }
        let area = abs(points.indices.reduce(CGFloat.zero) { partial, index in
            let next = points[(index + 1) % points.count]
            return partial + points[index].x * next.y - next.x * points[index].y
        }) / 2
        guard area >= sourceSize.width * sourceSize.height * 0.01 else { return "The selected board area is too small." }
        return nil
    }

    private static func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
    private static func segmentsIntersect(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        let abC = cross(a, b, c), abD = cross(a, b, d)
        let cdA = cross(c, d, a), cdB = cross(c, d, b)
        return abC * abD < 0 && cdA * cdB < 0
    }
}

private struct CornerRole {
    let index: Int
    var label: String { ["TL", "TR", "BR", "BL"][min(max(index, 0), 3)] }
}

private struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController { let picker = UIImagePickerController(); picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary; picker.delegate = context.coordinator; return picker }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture, onCancel: onCancel) }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let onCancel: () -> Void
        init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) { self.onCapture = onCapture; self.onCancel = onCancel }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            guard let image = info[.originalImage] as? UIImage else { onCancel(); picker.dismiss(animated: true); return }
            onCapture(image)
            picker.dismiss(animated: true)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onCancel(); picker.dismiss(animated: true) }
    }
}

struct StudyGuideView: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let folderID: String
    let guide: StudyGuide?
    @State private var current: StudyGuide?
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Group {
                if let current {
                    VStack(spacing: 0) {
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity)
                                .background(.orange.opacity(0.10))
                        }
                        ScrollView { StudyContentView(source: current.content ?? "No guide content yet.").padding(24) }
                    }
                } else if loading {
                    ProgressView("Preparing your study guide…")
                } else if let error {
                    ContentUnavailableView {
                        Label("Couldn’t create study guide", systemImage: "text.book.closed.fill")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { generate() }.buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView("No study guide yet", systemImage: "text.book.closed", description: Text("Generate a concise guide from this lecture’s whiteboards."))
                }
            }
                .navigationTitle("Study Guide")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }; ToolbarItem(placement: .primaryAction) { Button(current == nil ? "Generate" : "Regenerate") { generate() }.disabled(loading) } }
        }.onAppear { current = guide }
    }
    private func generate() { loading = true; error = nil; Task { do { current = try await api.generateStudyGuide(folderID: folderID); loading = false } catch { loading = false; self.error = "Study Guide is temporarily unavailable." } } }
}

private struct NewLectureView: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let onCreated: () -> Void
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?
    var body: some View { NavigationStack { Form { Section("Lecture") { TextField("Lecture name", text: $name); if let error { Text(error).foregroundStyle(.red) } }; Section { Button(saving ? "Creating…" : "Create Lecture") { create() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving) } }.navigationTitle("New Lecture").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } } } }
    private func create() { saving = true; Task { do { _ = try await api.createLecture(name: name.trimmingCharacters(in: .whitespacesAndNewlines)); saving = false; onCreated() } catch { saving = false; self.error = "Couldn’t create lecture." } } }
}
