import SwiftUI

/// Editorial search bar shown above the library list when search is active.
/// Owns no state — the parent passes a binding for the query and a focus
/// binding; the bar surfaces a "Cancel" affordance that the parent wires
/// to whatever close behaviour fits (clears the query, drops focus, etc.).
struct LibrarySearchBar: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(EditorialTheme.muted)
            TextField("Search title or author", text: $query)
                .focused(focused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(EditorialTheme.ink)
            if !query.isEmpty {
                Button {
                    query = ""
                    focused.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(EditorialTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
            Button("Cancel", action: onCancel)
                .foregroundStyle(EditorialTheme.accent)
        }
        .padding(.horizontal, EditorialTheme.listSidePad)
        .padding(.vertical, 8)
    }
}
