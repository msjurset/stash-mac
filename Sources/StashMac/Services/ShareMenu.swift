import AppKit

/// Context-sensitive share menu. Replaces the default
/// `NSSharingServicePicker` flow (which only surfaces apps that
/// registered as share targets — Signal et al. don't) with a
/// Stash-curated menu whose entries vary by item type:
///
///   image  — Image with caption / Collage / Image / Notes
///   url    — Link with title / Link / Notes
///   snippet— Text with title / Text
///   file   — File / Notes
///   email  — Email body / Subject and body
///
/// "macOS share sheet…" is always last as a fallback for the
/// rare case where the user wants AirDrop, Reminders, etc.
/// Each action writes the appropriate pasteboard representation
/// via `ClipboardComposer`.
@MainActor
enum ShareMenu {

    /// Build an `NSMenu` for the given item. Caller pops the menu
    /// from a button or context menu site.
    static func menu(for item: StashItem) -> NSMenu {
        let menu = NSMenu()

        // Per-type actions. Each AddIfApplicable closure adds the
        // item only when there's actually something to copy (no
        // empty notes row, no link row on a snippet, etc.).
        switch item.type {
        case .image:
            addImageActions(to: menu, item: item)
        case .url:
            addURLActions(to: menu, item: item)
        case .snippet:
            addSnippetActions(to: menu, item: item)
        case .file:
            addFileActions(to: menu, item: item)
        case .email:
            addEmailActions(to: menu, item: item)
        }

        // Fallback: open the native share sheet. Useful when
        // the user wants AirDrop or has a third-party share
        // extension registered. Skipped if we can't build a
        // payload (purely-empty item).
        let nativePayload = SharePayload.build(for: item)
        if !nativePayload.isEmpty {
            menu.addItem(.separator())
            let native = NSMenuItem(title: "macOS share sheet…",
                                    action: #selector(MenuTarget.openNativePicker(_:)),
                                    keyEquivalent: "")
            native.representedObject = NativePickerPayload(items: nativePayload)
            native.target = MenuTarget.shared
            menu.addItem(native)
        }
        return menu
    }

    // MARK: - Per-type rows

    private static func addImageActions(to menu: NSMenu, item: StashItem) {
        let hasMultiple = (item.files?.count ?? 0) > 0
        let hasCaption = !captionEmpty(item)

        if hasCaption {
            menu.addItem(action(title: "Image with caption", item: item, kind: .imageWithCaption))
            if hasMultiple {
                menu.addItem(action(title: "Collage with caption", item: item, kind: .collageWithCaption))
            }
        } else if hasMultiple {
            menu.addItem(action(title: "Collage", item: item, kind: .collageWithCaption))
        }
        menu.addItem(action(title: "Image only", item: item, kind: .imageOnly))
        if hasCaption {
            menu.addItem(action(title: "Notes only", item: item, kind: .captionOnly))
        }
    }

    private static func addURLActions(to menu: NSMenu, item: StashItem) {
        guard let raw = item.url, !raw.isEmpty else { return }
        let hasTitle = !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasTitle {
            menu.addItem(action(title: "Link with title", item: item, kind: .linkWithTitle))
        }
        menu.addItem(action(title: "Link", item: item, kind: .linkOnly))
        if !(item.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            menu.addItem(action(title: "Notes only", item: item, kind: .captionOnly))
        }
    }

    private static func addSnippetActions(to menu: NSMenu, item: StashItem) {
        let hasTitle = !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasBody = !(item.extractedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasTitle && hasBody {
            menu.addItem(action(title: "Text with title", item: item, kind: .textWithTitle))
        }
        if hasBody {
            menu.addItem(action(title: "Text", item: item, kind: .textBody))
        } else if hasTitle {
            menu.addItem(action(title: "Title", item: item, kind: .captionOnly))
        }
    }

    private static func addFileActions(to menu: NSMenu, item: StashItem) {
        // Files use the native share sheet's URL flow — the
        // pasteboard image-write helpers don't apply. We still
        // offer "Notes only" when the item has any. The native
        // share sheet at the bottom handles the actual file
        // payload.
        if !captionEmpty(item) {
            menu.addItem(action(title: "Notes", item: item, kind: .captionOnly))
        }
    }

    private static func addEmailActions(to menu: NSMenu, item: StashItem) {
        let hasTitle = !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasBody = !(item.extractedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasBody {
            if hasTitle {
                menu.addItem(action(title: "Subject and body", item: item, kind: .textWithTitle))
            }
            menu.addItem(action(title: "Email body", item: item, kind: .textBody))
        } else if hasTitle {
            menu.addItem(action(title: "Subject", item: item, kind: .captionOnly))
        }
    }

    private static func captionEmpty(_ item: StashItem) -> Bool {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = (item.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty && notes.isEmpty
    }

    private static func action(title: String, item: StashItem, kind: ActionKind) -> NSMenuItem {
        let mi = NSMenuItem(title: title,
                            action: #selector(MenuTarget.runAction(_:)),
                            keyEquivalent: "")
        mi.representedObject = ActionPayload(item: item, kind: kind)
        mi.target = MenuTarget.shared
        return mi
    }

    // MARK: - Internal types

    enum ActionKind {
        case imageWithCaption
        case collageWithCaption
        case imageOnly
        case captionOnly
        case linkOnly
        case linkWithTitle
        case textBody
        case textWithTitle
    }

    /// Captured-into-representedObject payload for the menu item.
    /// Wrapping in a class so NSMenuItem.representedObject (which
    /// expects an `Any?` but in practice prefers NSObject) holds
    /// it correctly.
    final class ActionPayload: NSObject {
        let item: StashItem
        let kind: ActionKind
        init(item: StashItem, kind: ActionKind) {
            self.item = item
            self.kind = kind
        }
    }

    final class NativePickerPayload: NSObject {
        let items: [Any]
        init(items: [Any]) { self.items = items }
    }
}

/// AppKit action target — a singleton so menu items don't hold a
/// retain cycle through their target reference. Each click reads
/// the typed payload off `representedObject` and dispatches.
@MainActor
final class MenuTarget: NSObject {
    static let shared = MenuTarget()

    @objc func runAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ShareMenu.ActionPayload else { return }

        // Text-only actions are cheap — run them inline.
        // Image actions composite a multi-megapixel source down
        // to a 1200px canvas which can take a second or two; we
        // run those off-main with a "Working…" toast so the UI
        // stays responsive and the user sees progress.
        let label = humanLabel(for: payload.kind)
        switch payload.kind {
        case .imageWithCaption, .collageWithCaption, .imageOnly:
            // AppKit drawing must happen on the main thread, so
            // we can't truly offload compositing to a background
            // queue. What we CAN do is yield once so the toast
            // gets a render frame before the heavy work blocks
            // the UI — gives the user immediate feedback that
            // their click registered rather than a silent pause.
            ToastCenter.shared.show("Composing \(label)…", kind: .working)
            Task { @MainActor [self] in
                await Task.yield()
                let ok = self.runComposerAction(payload)
                if ok {
                    ToastCenter.shared.show("Copied: \(label)", kind: .success)
                } else {
                    ToastCenter.shared.show("Copy failed: \(label)", kind: .error)
                }
            }
        case .captionOnly, .linkOnly, .linkWithTitle, .textBody, .textWithTitle:
            let ok = runComposerAction(payload)
            if ok {
                ToastCenter.shared.show("Copied: \(label)", kind: .success)
            } else {
                ToastCenter.shared.show("Copy failed: \(label)", kind: .error)
            }
        }
    }

    /// Run the actual copy. Kept here so the runAction path —
    /// which has the toast lifecycle — is the single dispatcher.
    /// Returns true on success, false on no-op (empty input,
    /// missing blob, etc.).
    private func runComposerAction(_ payload: ShareMenu.ActionPayload) -> Bool {
        switch payload.kind {
        case .imageWithCaption:   return ClipboardComposer.copyImageWithCaption(item: payload.item)
        case .collageWithCaption: return ClipboardComposer.copyCollageWithCaption(item: payload.item)
        case .imageOnly:          return ClipboardComposer.copyImageOnly(item: payload.item)
        case .captionOnly:        return ClipboardComposer.copyCaptionOnly(item: payload.item)
        case .linkOnly:           return ClipboardComposer.copyLinkOnly(item: payload.item)
        case .linkWithTitle:      return ClipboardComposer.copyLinkWithTitle(item: payload.item)
        case .textBody:           return ClipboardComposer.copyTextBody(item: payload.item)
        case .textWithTitle:      return ClipboardComposer.copyTextWithTitle(item: payload.item)
        }
    }

    /// Map the action kind to the same verb the menu uses, so the
    /// toast reads "Copied: Image with caption" — direct mirror of
    /// what the user just clicked.
    private func humanLabel(for kind: ShareMenu.ActionKind) -> String {
        switch kind {
        case .imageWithCaption:   return "Image with caption"
        case .collageWithCaption: return "Collage with caption"
        case .imageOnly:          return "Image"
        case .captionOnly:        return "Notes"
        case .linkOnly:           return "Link"
        case .linkWithTitle:      return "Link with title"
        case .textBody:           return "Text"
        case .textWithTitle:      return "Text with title"
        }
    }

    @objc func openNativePicker(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ShareMenu.NativePickerPayload else { return }
        let picker = NSSharingServicePicker(items: payload.items)
        if let window = NSApp.keyWindow, let view = window.contentView {
            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
    }
}
