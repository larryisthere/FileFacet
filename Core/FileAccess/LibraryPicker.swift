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
        panel.resolvesAliases = false
        panel.allowedContentTypes = VideoFileDiscovery.supportedExtensions
            .sorted()
            .compactMap { UTType(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.urls : nil
    }

    func chooseVideoForRelinking(filename: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(
            localized: "unavailable.relink.title",
            defaultValue: "Relink \(filename)"
        )
        panel.message = String(
            localized: "unavailable.relink.message",
            defaultValue: "Choose the current location of this video."
        )
        panel.prompt = String(
            localized: "unavailable.relink.confirm",
            defaultValue: "Relink"
        )
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        panel.allowedContentTypes = VideoFileDiscovery.supportedExtensions
            .sorted()
            .compactMap { UTType(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
