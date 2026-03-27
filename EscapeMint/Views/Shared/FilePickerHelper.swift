#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import SwiftUI

@MainActor
func showOpenPanel(
    title: String,
    message: String,
    canChooseFiles: Bool,
    canChooseDirectories: Bool,
    allowedContentTypes: [UTType],
    canCreateDirectories: Bool = false,
    treatsFilePackagesAsDirectories: Bool = false,
    completion: @escaping (URL) -> Void
) {
    let panel = NSOpenPanel()
    panel.title = title
    panel.message = message
    panel.canChooseFiles = canChooseFiles
    panel.canChooseDirectories = canChooseDirectories
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = allowedContentTypes
    panel.canCreateDirectories = canCreateDirectories
    panel.treatsFilePackagesAsDirectories = treatsFilePackagesAsDirectories

    if let window = NSApp.keyWindow {
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                completion(url)
            }
        }
    } else if panel.runModal() == .OK, let url = panel.url {
        completion(url)
    }
}
#endif
