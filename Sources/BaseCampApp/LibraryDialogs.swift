import BaseCampCore
import SwiftUI

extension LibraryNode: Identifiable {
    var id: Self { self }
}

extension ListChoice: Identifiable {
    var id: UUID { folder }
}

/// The questions BaseCamp asks while organising My Collection, worded after its own: renaming a list or folder,
/// removing one (and whether its items in no other list go too), duplicating a list (and whether its items are
/// copied), deleting items from a list or from My Collection, and which list of a folder new items go into.
struct LibraryDialogs: ViewModifier {
    @Environment(LibraryStore.self) private var store

    func body(content: Content) -> some View {
        @Bindable var store = store
        content
            .sheet(item: $store.renaming) { node in
                RenameSheet(node: node, name: store.name(of: node)) { name in
                    store.rename(node, to: name)
                }
            }
            .sheet(item: $store.pendingListChoice) { choice in
                ListChoiceSheet(choice: choice)
            }
            .alert(removalTitle, isPresented: isPresented(\.pendingNodeRemoval), presenting: store.pendingNodeRemoval) { node in
                let kind = node.isFolder ? "Folder" : "List"
                if store.uniqueItems(of: node) > 0 {
                    Button("Delete \(kind) and Contents", role: .destructive) { store.remove(node, deletingUniqueItems: true) }
                    Button("Remove \(kind) Only") { store.remove(node, deletingUniqueItems: false) }
                } else {
                    Button("Remove \(kind)") { store.remove(node, deletingUniqueItems: false) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { node in
                Text(removalMessage(node))
            }
            .alert("Duplicate List Data?", isPresented: isPresented(\.pendingListDuplication), presenting: store.pendingListDuplication) { id in
                Button("Duplicate Data") { store.duplicateList(id, copyingItems: true) }
                Button("List Only") { store.duplicateList(id, copyingItems: false) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Would you like to duplicate Waypoints, Routes, and Tracks contained in the List as well?")
            }
            .alert(deletionTitle, isPresented: isPresented(\.pendingItemDeletion), presenting: store.pendingItemDeletion) { deletion in
                if let list = deletion.list {
                    Button("Remove from List") {
                        store.selectedItems = deletion.items
                        if store.selectedListID == list { store.removeSelectionFromList() }
                    }
                }
                Button("Delete from My Collection", role: .destructive) { store.deleteFromMyCollection(deletion.items) }
                Button("Cancel", role: .cancel) {}
            } message: { deletion in
                Text(deletion.list == nil
                    ? "The My Collection list is special. Items deleted from the My Collection list will be deleted from ALL lists."
                    : "Remove from List keeps the items in My Collection and in their other lists. Delete from My Collection deletes them from ALL lists.")
            }
    }

    private func isPresented<Value>(_ path: ReferenceWritableKeyPath<LibraryStore, Value?>) -> Binding<Bool> {
        Binding(get: { store[keyPath: path] != nil }, set: { if !$0 { store[keyPath: path] = nil } })
    }

    private var removalTitle: String {
        guard let node = store.pendingNodeRemoval else { return "" }
        return "Remove \(node.isFolder ? "the folder" : "the list") '\(store.name(of: node))'?"
    }

    private func removalMessage(_ node: LibraryNode) -> String {
        let kind = node.isFolder ? "folder" : "list"
        let unique = store.uniqueItems(of: node)
        if unique > 0 {
            let others = node.isFolder ? "lists outside it" : "other lists"
            return "You are about to delete a \(kind) which contains items not found in your \(others) (\(unique)). Delete this \(kind)'s unique items from My Collection, or keep them there?"
        }
        return "This will remove the \(kind) '\(store.name(of: node))'. Data contained will still be available in My Collection."
    }

    private var deletionTitle: String {
        guard let deletion = store.pendingItemDeletion else { return "" }
        let what = deletion.items.count == 1 ? "'\(store.name(of: deletion.items.first!))'" : "\(deletion.items.count) items"
        if let list = deletion.list {
            return "Remove \(what) from '\(store.name(of: .list(list)))' or delete from My Collection?"
        }
        return "Delete \(what) from My Collection?"
    }
}

/// Renames a list or folder.
private struct RenameSheet: View {
    let node: LibraryNode
    @State var name: String
    let rename: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(node.isFolder ? "Folder Rename" : "List Rename")
                .font(.headline)
            TextField(node.isFolder ? "Folder name" : "List Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func commit() {
        rename(name)
        dismiss()
    }
}

/// New items made while a list folder was selected: BaseCamp asks for a list in that folder to put them in.
private struct ListChoiceSheet: View {
    let choice: ListChoice
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var existing: UUID?
    @State private var createNew = false
    @State private var newName = "New List"

    var body: some View {
        let lists = store.library.lists(inFolder: choice.folder)
        VStack(alignment: .leading, spacing: 12) {
            Text("You have a list folder selected. List folders contain and organize lists of data, but can't contain data themselves. Please select or create a list in '\(store.name(of: .folder(choice.folder)))' to put your data:")
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $createNew) {
                Text("Choose an existing list:").tag(false)
                Text("Create a new list:").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(lists.isEmpty)
            if createNew || lists.isEmpty {
                TextField("List Name", text: $newName)
                    .textFieldStyle(.roundedBorder)
            } else {
                Picker("List", selection: $existing) {
                    ForEach(lists) { list in
                        Text(store.path(ofList: list.id)).tag(UUID?.some(list.id))
                    }
                }
                .labelsHidden()
            }
            Text("The new items are in My Collection whatever you choose.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    store.placeItems(choice, inList: createNew || lists.isEmpty ? nil : existing, newListName: newName)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!createNew && !lists.isEmpty && existing == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            existing = lists.first?.id
            createNew = lists.isEmpty
        }
    }
}
