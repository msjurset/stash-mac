import AppKit
import ApplicationServices

@Observable
@MainActor
final class SelectionGrabber {
    var status: String?

    private let cli = StashCLI.shared
    private let logFile = "/tmp/stash-selection.log"

    private func log(_ msg: String) {
        let line = "\(Date()): \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile) {
                if let handle = FileHandle(forWritingAtPath: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logFile, contents: data)
            }
        }
    }

    func stashSelection() {
        status = nil
        log("--- stashSelection called ---")

        let trusted = AXIsProcessTrusted()
        log("AXIsProcessTrusted: \(trusted)")

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            status = "No active app"
            log("ERROR: No frontmost application")
            return
        }

        let appName = frontApp.localizedName ?? "Unknown"
        let pid = frontApp.processIdentifier
        let bundleID = frontApp.bundleIdentifier ?? "?"
        log("Frontmost: \(appName) (\(bundleID)) pid=\(pid)")

        let axApp = AXUIElementCreateApplication(pid)

        var focusedRef: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(
            axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        log("AX focusedElement: \(focusResult.rawValue) (0=success)")

        if focusResult == .success, let element = focusedRef {
            var selRef: CFTypeRef?
            let selResult = AXUIElementCopyAttributeValue(
                element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selRef
            )
            log("AX selectedText: \(selResult.rawValue) (0=success)")

            if selResult == .success, let text = selRef as? String {
                log("Got text (\(text.count) chars): \(text.prefix(100))")
                if !text.isEmpty {
                    stashText(text, from: appName)
                    return
                }
            } else {
                log("selectedText nil or wrong type")
            }
        }

        // Fallback: Cmd+C + pasteboard
        log("AX path failed, trying Cmd+C")
        let pasteboard = NSPasteboard.general
        let prevCount = pasteboard.changeCount

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        log("Posted Cmd+C, pasteboard count before=\(prevCount)")

        let capturedAppName = appName
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let newCount = pasteboard.changeCount
            self.log("Pasteboard count after=\(newCount)")
            if newCount != prevCount,
               let text = pasteboard.string(forType: .string),
               !text.isEmpty {
                self.log("Cmd+C got text (\(text.count) chars)")
                self.stashText(text, from: capturedAppName)
            } else {
                self.log("Cmd+C failed — pasteboard unchanged")
                self.status = "No text selected"
            }
        }
    }

    func stashClipboard() {
        status = nil
        let pasteboard = NSPasteboard.general

        // Try text first
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            stashText(text, from: "Clipboard")
            return
        }

        // Try image — convert to PNG and stash as file
        if let image = imageFromPasteboard(pasteboard) {
            stashImage(image)
            return
        }

        status = "Clipboard is empty"
    }

    private func imageFromPasteboard(_ pasteboard: NSPasteboard) -> NSImage? {
        // Check for common image types on the pasteboard
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        for type in imageTypes {
            if let data = pasteboard.data(forType: type), let image = NSImage(data: data) {
                return image
            }
        }
        // Some apps put images as file URLs
        if let data = pasteboard.data(forType: .fileURL),
           let url = URL(dataRepresentation: data, relativeTo: nil),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return nil
    }

    private func stashImage(_ image: NSImage) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            status = "Failed to convert image to PNG"
            return
        }

        let tempPath = NSTemporaryDirectory() + "stash-clipboard-\(UUID().uuidString).png"
        let tempURL = URL(fileURLWithPath: tempPath)

        do {
            try pngData.write(to: tempURL)
        } catch {
            status = "Failed to write temp file"
            return
        }

        status = "Stashing image..."
        let capturedCLI = cli

        Task.detached {
            do {
                _ = try await capturedCLI.addFile(path: tempPath, title: "Clipboard image")
                try? FileManager.default.removeItem(at: tempURL)
                await MainActor.run {
                    self.status = "Stashed!"
                }
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                await MainActor.run { [weak self] in
                    self?.status = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func stashText(_ text: String, from appName: String) {
        let title = "\(appName) (selection)"
        let capturedCLI = cli
        status = "Stashing..."
        log("Calling CLI addSnippet, title=\(title)")

        Task.detached {
            do {
                _ = try await capturedCLI.addSnippet(text: text, title: title)
                await MainActor.run {
                    self.status = "Stashed!"
                    self.log("CLI success")
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.status = "Failed: \(error.localizedDescription)"
                    self?.log("CLI error: \(error.localizedDescription)")
                }
            }
        }
    }
}
