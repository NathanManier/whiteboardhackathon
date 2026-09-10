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
    @State private var image: UIImage?
    @State private var pdfData: Data?
    @State private var pdfFilename = "Freeform.pdf"
    @State private var pdfPageCount = 0
    @State private var importFileKind: ImportFileKind = .image
    @State private var fileImporter = false
    @State private var showCamera = false
    @State private var name = ""
    @State private var stage: ImportStage = .choose
    @State private var boardID: String?
    @State private var corners: [CGPoint] = [CGPoint(x: 0.05, y: 0.05), CGPoint(x: 0.95, y: 0.05), CGPoint(x: 0.95, y: 0.95), CGPoint(x: 0.05, y: 0.95)]
    @State private var error: String?
    @State private var availableLectures: [LectureFolder] = []
    @State private var selectedFolderID: String?
    @State private var createLecture = false
    @State private var newLectureName = ""
    init(folderID: String? = nil, pendingImport: PendingImport? = nil,
         onComplete: @escaping (LibraryBoard) -> Void) {
        self.folderID = folderID; self.pendingImport = pendingImport; self.onComplete = onComplete
    }
    var body: some View {
        NavigationStack { Group { switch stage { case .choose: chooseView; case .preview: previewView; case .corners: cornerView; case .processing: processingView } }.navigationTitle(stage.title).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(stage == .processing) } } }
            .fileImporter(isPresented: $fileImporter, allowedContentTypes: importFileKind == .pdf ? [.pdf] : [.image]) { result in if case .success(let url) = result { Task { await loadFile(url) } } }
            .sheet(isPresented: $showCamera) { CameraCaptureView { data in showCamera = false; Task { await loadImageData(data) } } }
            .onChange(of: pickerItem) { _, item in guard let item else { return }; Task { if let data = try? await item.loadTransferable(type: Data.self) { await loadImageData(data) } } }
            .task {
                if folderID == nil { availableLectures = (try? await api.library().folders) ?? [] }
                if let pendingImport, let url = PendingImportStore.fileURL(for: pendingImport) {
                    await loadFile(url)
                }
            }
    }
    private var chooseView: some View { VStack(spacing: 18) { Image(systemName: "photo.badge.plus").font(.system(size: 52)).foregroundStyle(.tint); Text("Add to V-Board").font(.largeTitle.bold()); Text(folderID == nil ? "Import a physical whiteboard or a digital canvas." : "Add another board to this lecture.").foregroundStyle(.secondary); VStack(spacing: 12) { Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }.buttonStyle(.borderedProminent).controlSize(.large); PhotosPicker(selection: $pickerItem, matching: .images) { Label("Choose from Photos", systemImage: "photo.on.rectangle") }.buttonStyle(.bordered).controlSize(.large); Button { importFileKind = .pdf; fileImporter = true } label: { Label("Freeform / PDF", systemImage: "doc.richtext") }.buttonStyle(.bordered).controlSize(.large); Button { importFileKind = .image; fileImporter = true } label: { Label("Import Image File", systemImage: "folder") }.buttonStyle(.bordered).controlSize(.large) }.padding(.top, 12); Text("In Freeform, export your board as a PDF and share or import it into V-Board.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: 520).padding(30) }
    private var previewView: some View { ScrollView { VStack(spacing: 18) { if let image { Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal) }; if pdfData != nil { Label(pdfPageCount == 1 ? "1 PDF page" : "\(pdfPageCount) PDF pages", systemImage: "doc.richtext").font(.headline); if pdfPageCount > 1 { Text("Each page will become a separate board in source order.").font(.subheadline).foregroundStyle(.secondary) } }; TextField("Board name (optional)", text: $name).textFieldStyle(.roundedBorder).padding(.horizontal); destinationControls; Button(pdfData == nil ? "Use This Photo" : "Import PDF") { Task { pdfData == nil ? await upload() : await uploadPDF() } }.buttonStyle(.borderedProminent).controlSize(.large); if let error { Text(error).foregroundStyle(.red).multilineTextAlignment(.center) } }.padding(.vertical, 20).frame(maxWidth: 700) }.frame(maxWidth: .infinity) }
    @ViewBuilder private var destinationControls: some View { if folderID == nil { VStack(alignment: .leading, spacing: 10) { Toggle("Create a new lecture", isOn: $createLecture); if createLecture { TextField("Lecture name", text: $newLectureName).textFieldStyle(.roundedBorder) } else if !availableLectures.isEmpty { Picker("Add to lecture", selection: $selectedFolderID) { Text("No lecture").tag(String?.none); ForEach(availableLectures) { lecture in Text(lecture.name).tag(Optional(lecture.id)) } }.pickerStyle(.menu) } }.padding(.horizontal) } }
    private var cornerView: some View { VStack(spacing: 0) { if let image { GeometryReader { proxy in ZStack { Image(uiImage: image).resizable().scaledToFit(); Path { path in for i in 0..<4 { let p = point(corners[i], in: proxy.size); i == 0 ? path.move(to: p) : path.addLine(to: p) }; path.closeSubpath() }.stroke(.yellow, lineWidth: 3); ForEach(0..<4, id: \.self) { index in Circle().fill(.yellow).frame(width: 30, height: 30).position(point(corners[index], in: proxy.size)).gesture(DragGesture().onChanged { value in corners[index] = normalized(value.location, in: proxy.size) }) } } }.padding() }; VStack(spacing: 8) { Text("Drag the corners to fit the board").foregroundStyle(.secondary); Button("Process Whiteboard") { Task { await process() } }.buttonStyle(.borderedProminent).controlSize(.large) }.padding(.bottom, 18) } }
    private var processingView: some View { VStack(spacing: 22) { ProgressView().controlSize(.large); Text(pdfData == nil ? "Creating your editable board…" : "Importing your PDF…").font(.title2.weight(.semibold)); Text(pdfData == nil ? "Preparing image • Correcting perspective • Finding ink • Creating vectors" : "Preserving source quality • Preparing page previews • Adding boards to your lecture").multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 30) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
    private func point(_ normalized: CGPoint, in size: CGSize) -> CGPoint { CGPoint(x: normalized.x * size.width, y: normalized.y * size.height) }
    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint { CGPoint(x: min(max(point.x / max(size.width, 1), 0), 1), y: min(max(point.y / max(size.height, 1), 0), 1)) }
    private func loadImageData(_ data: Data) async { guard let normalized = normalize(data) else { error = "That image could not be read."; return }; pdfData = nil; image = normalized.image; stage = .preview }
    private func loadFile(_ url: URL) async { let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }; do { let data = try Data(contentsOf: url, options: .mappedIfSafe); if url.pathExtension.lowercased() == "pdf" { guard let document = PDFDocument(data: data), document.pageCount > 0, let page = document.page(at: 0) else { self.error = "That PDF could not be read."; return }; pdfData = data; pdfFilename = url.lastPathComponent; pdfPageCount = document.pageCount; image = page.thumbnail(of: CGSize(width: 1100, height: 1100), for: .cropBox); if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }; stage = .preview } else { await loadImageData(data) } } catch { self.error = "The selected file could not be opened." } }
    private func resolvedFolderID() async throws -> String? { if let folderID { return folderID }; if createLecture { let trimmed = newLectureName.trimmingCharacters(in: .whitespacesAndNewlines); guard !trimmed.isEmpty else { throw ImportUIError.missingLectureName }; return try await api.createLecture(name: trimmed).id }; return selectedFolderID }
    private func upload() async { guard let image, let data = image.jpegData(compressionQuality: 0.94) else { return }; stage = .processing; do { let target = try await resolvedFolderID(); let result = try await api.upload(imageData: data, filename: "whiteboard.jpg", mimeType: "image/jpeg", folderID: target, name: name.isEmpty ? nil : name); boardID = result.id; let record = try await api.board(id: result.id); corners = record.suggestedCorners?.map { CGPoint(x: CGFloat(($0.first ?? 0) / max(Double(image.size.width), 1)), y: CGFloat(($0.dropFirst().first ?? 0) / max(Double(image.size.height), 1))) } ?? corners; stage = result.status == "ready" ? .processing : .corners } catch { stage = .preview; self.error = error is ImportUIError ? error.localizedDescription : "Couldn’t upload this photo. Try again." } }
    private func uploadPDF() async { guard let pdfData else { return }; stage = .processing; do { let target = try await resolvedFolderID(); let result = try await api.importPDF(data: pdfData, filename: pdfFilename, folderID: target, name: name.isEmpty ? nil : name); guard let first = result.boards.first else { throw ImportUIError.emptyImport }; onComplete(first) } catch { stage = .preview; self.error = error is ImportUIError ? error.localizedDescription : "Couldn’t import this PDF. Your selected file is still here so you can try again." } }
    private func process() async { guard let boardID, let image else { return }; stage = .processing; do { let pixels: [[Double]] = corners.map { [Double($0.x) * Double(image.size.width), Double($0.y) * Double(image.size.height)] }; _ = try await api.processCorners(boardID: boardID, corners: pixels); let result = try await api.library(); if let board = result.boards.first(where: { $0.id == boardID }) { onComplete(board) } else { self.error = "The board was processed, but could not be reopened."; stage = .corners } } catch { stage = .corners; self.error = "Couldn’t process this whiteboard. Adjust the corners and try again." } }
    private func normalize(_ data: Data) -> (image: UIImage, data: Data)? { guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.94) else { return nil }; return (image, jpeg) }
}

private enum ImportFileKind { case image, pdf }
private enum ImportUIError: LocalizedError {
    case missingLectureName, emptyImport
    var errorDescription: String? { switch self { case .missingLectureName: return "Enter a name for the new lecture."; case .emptyImport: return "The PDF did not contain an importable page." } }
}

private enum ImportStage { case choose, preview, corners, processing; var title: String { switch self { case .choose: return "New Whiteboard"; case .preview: return "Preview"; case .corners: return "Confirm Board"; case .processing: return "Processing" } } }

private struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController { let picker = UIImagePickerController(); picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary; picker.delegate = context.coordinator; return picker }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate { let onCapture: (Data) -> Void; init(onCapture: @escaping (Data) -> Void) { self.onCapture = onCapture }; func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) { if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.94) { onCapture(data) } }; func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {} }
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
