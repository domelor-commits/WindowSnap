import Cocoa

extension AppDelegate {
    func performRestore(layoutID: String) {
        DispatchQueue.main.async {
            let match: Layout?
            if LayoutManager.isPinned(layoutID) {
                match = LayoutManager.loadPinned(layoutID)
            } else {
                match = LayoutManager.loadAll().first(where: { $0.id == layoutID })
            }
            guard let layout = match else { return }
            LayoutManager.restore(layout)
        }
    }

    /// Restore a pinned layout by id, with a helpful notice if it's empty.
    func restorePinned(_ id: String) {
        DispatchQueue.main.async {
            if let layout = LayoutManager.loadPinned(id) {
                LayoutManager.restore(layout)
            } else {
                let name = LayoutManager.pinnedName(for: id)
                LayoutManager.notify("No \(name) layout",
                                     "Select \(name) in the Layouts tab and Save New to capture it.")
            }
        }
    }
}
