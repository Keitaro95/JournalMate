import SwiftUI

/// 1 つのディレクトリの、1 つの層。ここが最下層の .md 一覧。
struct LayerScreen: View {

    @Environment(Store.self) private var store
    @Environment(Entitlement.self) private var entitlement

    let node: Node
    let layer: Layer

    @State private var notes: [Note] = []
    @State private var newNote: Note?
    @State private var errorMessage: String?
    /// 「自分の傾向」を AI で書くときの材料。knowledge の層でだけ使う。
    @State private var material: KnowledgeGenerator.Material?
    @State private var isGenerating = false
    /// 生成したノート。書き終わったらそのまま開く（編集モードにはしない）。
    @State private var generatedNote: Note?
    @State private var paywall: ProFeature?

    var body: some View {
        List {
            if layer == .knowledge {
                generateSection
            }
            if notes.isEmpty {
                ContentUnavailableView(
                    "Nothing Here Yet",
                    systemImage: layer.symbol,
                    description: Text(layer.summary))
            }
            ForEach(notes) { note in
                NavigationLink {
                    NoteDetailScreen(note: note, node: node)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title).appFont(.headline)
                        Text(note.filename)
                            .appFont(.caption1, monospacedDigits: true)
                            .foregroundStyle(.secondary)
                        if !note.preview.isEmpty {
                            Text(note.preview)
                                .appFont(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("\(node.code) / \(layer.title)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", systemImage: "square.and.pencil") { create() }
            }
        }
        .navigationDestination(item: $newNote) { note in
            NoteDetailScreen(note: note, node: node, startsEditing: true)
        }
        .navigationDestination(item: $generatedNote) { note in
            NoteDetailScreen(note: note, node: node)
        }
        .sheet(item: $paywall) { feature in
            PaywallSheet(feature: feature)
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear { reload() }
    }

    // MARK: - 自分の傾向の生成

    private var generateSection: some View {
        Section {
            Button {
                Task { await generate() }
            } label: {
                HStack {
                    Label("Generate with AI", systemImage: "sparkles")
                    Spacer()
                    if isGenerating {
                        ProgressView()
                    }
                }
            }
            .disabled(isGenerating || material?.isEmpty != false)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Blends raw data (life principles and direction) with journals (your own records), in date order, and the AI writes out your patterns and the path to head toward. Originals are never rewritten.")
                if let material {
                    if material.isEmpty {
                        Text("Available once there is at least one raw data or journal note in this folder.")
                    } else {
                        Text("Uses \(material.raw.count) raw data and \(material.journals.count) journals in this folder and its subfolders.")
                    }
                }
            }
        }
    }

    private func generate() async {
        guard let material, !material.isEmpty else { return }
        guard entitlement.access(to: .knowledge, in: store).isAllowed,
              let client = entitlement.client(meter: store, for: .knowledge) else {
            paywall = .knowledge
            return
        }
        if let budget = entitlement.exhaustedBudget(in: store) {
            errorMessage = budget.exhaustedMessage
            return
        }

        isGenerating = true
        defer { isGenerating = false }
        do {
            let result = try await KnowledgeGenerator(client: client).generate(from: material, folder: node)
            let note = try store.createNote(in: node, layer: .knowledge, title: result.title, body: result.body)
            reload()
            generatedNote = note
        } catch ClaudeClient.Failure.needsPro {
            paywall = .knowledge
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reload() {
        do {
            notes = try store.notes(in: node, layer: layer)
            if layer == .knowledge {
                material = try KnowledgeGenerator.material(in: node, store: store)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func create() {
        guard entitlement.isPro else {
            paywall = .journalWrite
            return
        }
        do {
            let title = layer == .journal ? String(localized: "New Journal") : String(localized: "New Note")
            newNote = try store.createNote(in: node, layer: layer, title: title, body: "")
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(at offsets: IndexSet) {
        do {
            for index in offsets {
                try store.deleteNote(notes[index])
            }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
