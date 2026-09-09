import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct LibraryView: View {
    @EnvironmentObject private var api: APIClient
    @State private var library: LibraryResponse?
    @State private var error: String?
    @State private var showImporter = false
    @State private var showNewLecture = false
    @State private var launchBoard: LibraryBoard?

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
                                                NavigationLink { LectureView(folder: folder) } label: { LectureCard(folder: folder) }.buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack { Label("Recent whiteboards", systemImage: "rectangle.on.rectangle").font(.title3.weight(.semibold)); Spacer(); Text("\(library.boards.count)").foregroundStyle(.secondary) }
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
                                        ForEach(library.boards) { board in
                                            NavigationLink { BoardView(board: board) } label: { BoardCard(board: board) }.buttonStyle(.plain)
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
            .toolbar { ToolbarItem(placement: .primaryAction) { Menu { Button { showImporter = true } label: { Label("New Whiteboard", systemImage: "photo.badge.plus") }; Button { showNewLecture = true } label: { Label("New Lecture", systemImage: "books.vertical") } } label: { Label("Create", systemImage: "plus") }.buttonStyle(.borderedProminent) }; ToolbarItem(placement: .secondaryAction) { Button { load() } label: { Image(systemName: "arrow.clockwise") } } }
            .sheet(isPresented: $showImporter) { ImportFlowView { board in launchBoard = board; showImporter = false; load() } }
            .sheet(isPresented: $showNewLecture) { NewLectureView { showNewLecture = false; load() } }
            .navigationDestination(item: $launchBoard) { BoardView(board: $0) }
            .task { load() }
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
}

private struct LibraryHero: View {
    let add: () -> Void
    var body: some View { HStack(spacing: 20) { VStack(alignment: .leading, spacing: 8) { Text("Turn any whiteboard into a study canvas.").font(.system(size: 34, weight: .bold, design: .rounded)).fixedSize(horizontal: false, vertical: true); Text("Import a photo, preserve the professor’s ink as editable geometry, and study from the same board.").font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true); Button(action: add) { Label("New Whiteboard", systemImage: "plus") }.buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 8) }; Spacer(minLength: 10); Image(systemName: "square.and.pencil").font(.system(size: 82, weight: .light)).foregroundStyle(.tint).symbolRenderingMode(.hierarchical).accessibilityHidden(true) }.padding(28).background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 24, style: .continuous)) }
}

private struct EmptyLibraryView: View {
    let add: () -> Void
    var body: some View { VStack(spacing: 14) { Image(systemName: "photo.on.rectangle.angled").font(.system(size: 48)).foregroundStyle(.tint); Text("No whiteboards yet").font(.title2.weight(.semibold)); Text("Photograph or import a physical whiteboard to create an editable study canvas.").multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 430); Button("Add Whiteboard", action: add).buttonStyle(.borderedProminent).controlSize(.large) }.frame(maxWidth: .infinity).padding(.vertical, 64) }
}

private struct LectureCard: View {
    let folder: LectureFolder
    var body: some View { VStack(alignment: .leading, spacing: 10) { Image(systemName: "books.vertical.fill").font(.title2).foregroundStyle(.tint); Text(folder.name).font(.headline); Text("\(folder.boardOrder.count) whiteboard\(folder.boardOrder.count == 1 ? "" : "s")").font(.subheadline).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
}

private struct BoardCard: View {
    let board: LibraryBoard
    var body: some View { VStack(alignment: .leading, spacing: 10) { if let raw = board.thumbnailURL, let url = URL(string: raw, relativeTo: URL(string: "https://chsinteract.com")) { AsyncImage(url: url) { phase in switch phase { case .success(let image): image.resizable().scaledToFill(); default: Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary) } }.frame(height: 130).clipped().clipShape(RoundedRectangle(cornerRadius: 12)) } else { RoundedRectangle(cornerRadius: 12).fill(.gray.opacity(0.14)).frame(height: 130).overlay { Image(systemName: board.status == "ready" ? "checkmark.circle" : "clock").font(.largeTitle).foregroundStyle(board.status == "ready" ? .green : .orange) } }; Text(board.name).font(.headline).lineLimit(2); Text(board.status.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
}

struct LectureView: View {
    @EnvironmentObject private var api: APIClient
    let folder: LectureFolder
    @State private var lecture: LectureResponse?
    @State private var error: String?
    @State private var showImporter = false
    @State private var showGuide = false
    @State private var showRename = false
    @State private var showDelete = false
    @State private var renameText = ""
    @State private var renameBoard: LibraryBoard?
    var body: some View {
        Group {
            if lecture != nil { loadedView }
            else if let error { ContentUnavailableView("Couldn’t load lecture", systemImage: "rectangle.stack.badge.exclamationmark", description: Text(error)).overlay(alignment: .bottom) { Button("Retry") { load() }.buttonStyle(.borderedProminent).padding(.bottom, 30) } }
            else { ProgressView("Loading lecture…") }
        }.navigationTitle(folder.name).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .primaryAction) { Menu { Button { renameText = lecture?.folder.name ?? folder.name; showRename = true } label: { Label("Rename Lecture", systemImage: "pencil") }; Button(role: .destructive) { showDelete = true } label: { Label("Delete Lecture", systemImage: "trash") } } label: { Image(systemName: "ellipsis.circle") } } }.sheet(isPresented: $showImporter) { ImportFlowView(folderID: folder.id) { _ in showImporter = false; load() } }.sheet(isPresented: $showGuide) { StudyGuideView(folderID: folder.id, guide: lecture?.studyGuide) }.sheet(isPresented: $showRename) { RenamePrompt(title: "Rename Lecture", value: renameText) { value in Task { do { _ = try await api.renameLecture(id: folder.id, name: value); showRename = false; load() } catch { self.error = "That lecture name could not be saved." } } } }.sheet(item: $renameBoard) { board in RenamePrompt(title: "Rename Whiteboard", value: board.name) { value in Task { do { _ = try await api.updateBoard(id: board.id, name: value); renameBoard = nil; load() } catch { self.error = "That board name could not be saved." } } } }.alert("Delete lecture?", isPresented: $showDelete) { Button("Delete", role: .destructive) { Task { await deleteLecture() } }; Button("Cancel", role: .cancel) {} } message: { Text("A lecture can only be deleted when it is empty.") }.task { load() }
    }
    @ViewBuilder private var loadedView: some View {
        if let lecture {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack { VStack(alignment: .leading) { Text(lecture.folder.name).font(.largeTitle.bold()); Text("Your ordered whiteboards").foregroundStyle(.secondary) }; Spacer(); Button { showImporter = true } label: { Label("Add Board", systemImage: "plus") }.buttonStyle(.borderedProminent) }.padding(.horizontal)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                        ForEach(lecture.boards) { board in
                            NavigationLink { BoardView(board: board) } label: { BoardCard(board: board) }.buttonStyle(.plain).contextMenu { Button { renameBoard = board } label: { Label("Rename", systemImage: "pencil") }; Button(role: .destructive) { Task { await delete(board) } } label: { Label("Delete", systemImage: "trash") } }
                        }
                    }.padding(.horizontal)
                    Button { showGuide = true } label: { Label(lecture.studyGuide == nil ? "Create Study Guide" : "Open Study Guide", systemImage: "text.book.closed") }.buttonStyle(.bordered).padding(.horizontal)
                }.padding(.vertical, 24)
            }
        }
    }
    private func load() { Task { do { lecture = try await api.lecture(id: folder.id); error = nil } catch { self.error = "Your lecture could not be loaded." } } }
    private func deleteLecture() async { do { try await api.deleteLecture(id: folder.id); dismissLecture() } catch { self.error = "The lecture could not be deleted. Remove its boards first." } }
    private func delete(_ board: LibraryBoard) async { do { try await api.deleteBoard(id: board.id); load() } catch { self.error = "The whiteboard could not be deleted." } }
    @Environment(\.dismiss) private var dismiss
    private func dismissLecture() { dismiss() }
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
    let onComplete: (LibraryBoard) -> Void
    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var fileImporter = false
    @State private var showCamera = false
    @State private var name = ""
    @State private var stage: ImportStage = .choose
    @State private var boardID: String?
    @State private var corners: [CGPoint] = [CGPoint(x: 0.05, y: 0.05), CGPoint(x: 0.95, y: 0.05), CGPoint(x: 0.95, y: 0.95), CGPoint(x: 0.05, y: 0.95)]
    @State private var error: String?
    init(folderID: String? = nil, onComplete: @escaping (LibraryBoard) -> Void) { self.folderID = folderID; self.onComplete = onComplete }
    var body: some View {
        NavigationStack { Group { switch stage { case .choose: chooseView; case .preview: previewView; case .corners: cornerView; case .processing: processingView } }.navigationTitle(stage.title).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(stage == .processing) } } }
            .fileImporter(isPresented: $fileImporter, allowedContentTypes: [.image]) { result in if case .success(let url) = result { Task { await loadFile(url) } } }
            .sheet(isPresented: $showCamera) { CameraCaptureView { data in showCamera = false; Task { await loadImageData(data) } } }
            .onChange(of: pickerItem) { _, item in guard let item else { return }; Task { if let data = try? await item.loadTransferable(type: Data.self) { await loadImageData(data) } } }
    }
    private var chooseView: some View { VStack(spacing: 18) { Image(systemName: "photo.badge.plus").font(.system(size: 52)).foregroundStyle(.tint); Text("Add a whiteboard").font(.largeTitle.bold()); Text(folderID == nil ? "Bring a physical whiteboard into V-Board." : "Add another board to this lecture.").foregroundStyle(.secondary); VStack(spacing: 12) { Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }.buttonStyle(.borderedProminent).controlSize(.large); PhotosPicker(selection: $pickerItem, matching: .images) { Label("Choose from Photos", systemImage: "photo.on.rectangle") }.buttonStyle(.bordered).controlSize(.large); Button { fileImporter = true } label: { Label("Import File", systemImage: "folder") }.buttonStyle(.bordered).controlSize(.large) }.padding(.top, 12) }.frame(maxWidth: 520).padding(30) }
    private var previewView: some View { VStack(spacing: 18) { if let image { Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal) }; TextField("Board name (optional)", text: $name).textFieldStyle(.roundedBorder).padding(.horizontal); Button("Use This Photo") { Task { await upload() } }.buttonStyle(.borderedProminent).controlSize(.large); if let error { Text(error).foregroundStyle(.red).multilineTextAlignment(.center) } }.padding(.vertical, 20) }
    private var cornerView: some View { VStack(spacing: 0) { if let image { GeometryReader { proxy in ZStack { Image(uiImage: image).resizable().scaledToFit(); Path { path in for i in 0..<4 { let p = point(corners[i], in: proxy.size); i == 0 ? path.move(to: p) : path.addLine(to: p) }; path.closeSubpath() }.stroke(.yellow, lineWidth: 3); ForEach(0..<4, id: \.self) { index in Circle().fill(.yellow).frame(width: 30, height: 30).position(point(corners[index], in: proxy.size)).gesture(DragGesture().onChanged { value in corners[index] = normalized(value.location, in: proxy.size) }) } } }.padding() }; VStack(spacing: 8) { Text("Drag the corners to fit the board").foregroundStyle(.secondary); Button("Process Whiteboard") { Task { await process() } }.buttonStyle(.borderedProminent).controlSize(.large) }.padding(.bottom, 18) } }
    private var processingView: some View { VStack(spacing: 22) { ProgressView().controlSize(.large); Text("Creating your editable board…").font(.title2.weight(.semibold)); Text("Preparing image • Correcting perspective • Finding ink • Creating vectors").multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 30) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
    private func point(_ normalized: CGPoint, in size: CGSize) -> CGPoint { CGPoint(x: normalized.x * size.width, y: normalized.y * size.height) }
    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint { CGPoint(x: min(max(point.x / max(size.width, 1), 0), 1), y: min(max(point.y / max(size.height, 1), 0), 1)) }
    private func loadImageData(_ data: Data) async { guard let normalized = normalize(data) else { error = "That image could not be read."; return }; image = normalized.image; stage = .preview }
    private func loadFile(_ url: URL) async { guard url.startAccessingSecurityScopedResource() else { self.error = "The selected file could not be opened."; return }; defer { url.stopAccessingSecurityScopedResource() }; do { await loadImageData(try Data(contentsOf: url)) } catch { self.error = "The selected file could not be opened." } }
    private func upload() async { guard let image, let data = image.jpegData(compressionQuality: 0.94) else { return }; stage = .processing; do { let result = try await api.upload(imageData: data, filename: "whiteboard.jpg", mimeType: "image/jpeg", folderID: folderID, name: name.isEmpty ? nil : name); boardID = result.id; let record = try await api.board(id: result.id); corners = record.suggestedCorners?.map { CGPoint(x: CGFloat(($0.first ?? 0) / max(Double(image.size.width), 1)), y: CGFloat(($0.dropFirst().first ?? 0) / max(Double(image.size.height), 1))) } ?? corners; stage = result.status == "ready" ? .processing : .corners } catch { stage = .preview; self.error = "Couldn’t upload this photo. Try again." } }
    private func process() async { guard let boardID, let image else { return }; stage = .processing; do { let pixels: [[Double]] = corners.map { [Double($0.x) * Double(image.size.width), Double($0.y) * Double(image.size.height)] }; _ = try await api.processCorners(boardID: boardID, corners: pixels); let result = try await api.library(); if let board = result.boards.first(where: { $0.id == boardID }) { onComplete(board) } else { self.error = "The board was processed, but could not be reopened."; stage = .corners } } catch { stage = .corners; self.error = "Couldn’t process this whiteboard. Adjust the corners and try again." } }
    private func normalize(_ data: Data) -> (image: UIImage, data: Data)? { guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.94) else { return nil }; return (image, jpeg) }
}

private enum ImportStage { case choose, preview, corners, processing; var title: String { switch self { case .choose: return "New Whiteboard"; case .preview: return "Preview"; case .corners: return "Confirm Board"; case .processing: return "Processing" } } }

private struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController { let picker = UIImagePickerController(); picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary; picker.delegate = context.coordinator; return picker }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate { let onCapture: (Data) -> Void; init(onCapture: @escaping (Data) -> Void) { self.onCapture = onCapture }; func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) { if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.94) { onCapture(data) } }; func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {} }
}

private struct StudyGuideView: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    let folderID: String
    let guide: StudyGuide?
    @State private var current: StudyGuide?
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Group { if let current { ScrollView { Text(current.content ?? "No guide content yet.").frame(maxWidth: 760, alignment: .leading).padding(24) } } else if loading { ProgressView("Preparing your study guide…") } else { ContentUnavailableView("No study guide yet", systemImage: "text.book.closed", description: Text("Generate a concise guide from this lecture’s whiteboards.")) } }
                .navigationTitle("Study Guide")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }; ToolbarItem(placement: .primaryAction) { Button(guide == nil ? "Generate" : "Regenerate") { generate() }.disabled(loading) } }
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
