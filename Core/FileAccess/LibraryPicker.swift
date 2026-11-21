import AppKit
import UniformTypeIdentifiers

@MainActor
struct LibraryPicker {
    func authorizeRecoveryDirectory(_ expected: URL) -> URL? {
        let panel = NSOpenPanel()
        let validation = RecoveryDirectoryValidation(expected: expected)
        panel.delegate = validation
        panel.title = String(localized: "recovery.permission.title", defaultValue: "Restore Folder Access")
        panel.message = String(localized: "recovery.permission.message", defaultValue: "Confirm this folder to check the original videos.")
        panel.prompt = String(localized: "recovery.permission.allow", defaultValue: "Allow Access")
        panel.directoryURL = expected
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        guard panel.runModal() == .OK, let url = panel.url,
              url.standardizedFileURL == expected.standardizedFileURL else { return nil }
        return url
    }

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

    func chooseScanFolders() -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = String(
            localized: "scan.folderPicker.title",
            defaultValue: "Choose Folders to Scan"
        )
        panel.message = String(
            localized: "scan.folderPicker.message",
            defaultValue: "Tagivy will look for new videos in these folders and their subfolders."
        )
        panel.prompt = String(
            localized: "scan.folderPicker.prompt",
            defaultValue: "Choose"
        )
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        return panel.runModal() == .OK ? panel.urls : nil
    }
}

@MainActor
private final class RecoveryDirectoryValidation: NSObject, NSOpenSavePanelDelegate {
    let expected: URL
    init(expected: URL) { self.expected = expected }
    func panel(_ sender: Any, validate url: URL) throws {
        guard url.standardizedFileURL == expected.standardizedFileURL,
              url.resolvingSymlinksInPath().standardizedFileURL == expected.standardizedFileURL else {
            throw NSError(domain: "Tagivy.Recovery", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "recovery.permission.exact", defaultValue: "Confirm the original folder shown here.")
            ])
        }
    }
}
