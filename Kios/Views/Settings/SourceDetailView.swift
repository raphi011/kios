import SwiftUI

/// Per-source detail. Lets the user rename, view kind / connection info,
/// and delete (server sources only — Local is the immutable singleton).
/// Credential editing is intentionally out of scope; users delete + re-add
/// a source to change credentials.
struct SourceDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @Bindable var source: Source

    @State private var showDeleteConfirm = false
    @State private var isDeleting = false

    var body: some View {
        Form {
            Section("Name") {
                TextField("Display name", text: $source.displayName)
                    .textInputAutocapitalization(.words)
            }
            Section("Kind") {
                LabeledContent("Kind", value: kindLabel)
                if let url = source.serverURL {
                    LabeledContent("URL", value: url.absoluteString)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if source.needsAttention {
                Section {
                    Label(
                        "Last operation failed. Try a refresh, or delete and re-add to update credentials.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }
            if source.kind != .local {
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        if isDeleting {
                            HStack {
                                ProgressView()
                                Text("Deleting…")
                            }
                        } else {
                            Text("Delete source")
                        }
                    }
                    .disabled(isDeleting)
                }
            }
        }
        .navigationTitle(source.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            deleteConfirmTitle,
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(source.books.count) book\(source.books.count == 1 ? "" : "s")",
                   role: .destructive,
                   action: performDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All books from this source — and their reading progress — will be removed. Other sources are unaffected.")
        }
    }

    private var kindLabel: String {
        switch source.kind {
        case .local: return "Local imports"
        case .opdsReadOnly: return "OPDS (read-only)"
        case .kosync: return "KOReader sync (kosync)"
        case .kobo: return "Kobo sync"
        }
    }

    private var deleteConfirmTitle: String {
        "Delete \"\(source.displayName)\"?"
    }

    private func performDelete() {
        isDeleting = true
        let id = source.id
        Task {
            do {
                try await env.removeSource(id: id)
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run { isDeleting = false }
            }
        }
    }
}
