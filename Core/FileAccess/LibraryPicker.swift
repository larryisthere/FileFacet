import AppKit
import UniformTypeIdentifiers

@MainActor
struct LibraryPicker {
    func chooseImportItems() -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = String(localized: .importPickerTitle)
        panel.message = String(localized: .importPickerMessage)
        panel.prompt = String(localized: .importPickerPrompt)
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.allowedContentTypes = VideoFileDiscovery.supportedExtensions
            .sorted()
            .compactMap { UTType(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.urls : nil
    }
}
