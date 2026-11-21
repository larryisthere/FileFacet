import AppKit
import UniformTypeIdentifiers

@MainActor
struct LibraryPicker {
    func authorizeRecoveryDirectory(for recordedFile: URL) -> URL? {
        let expected = recordedFile.deletingLastPathComponent()
        let panel = NSOpenPanel()
        let validation = RecoveryDirectoryValidation(recordedFile: recordedFile)
        panel.delegate = validation
        panel.title = String(localized: "recovery.permission.title", defaultValue: "Restore Folder Access")
        panel.message = String(localized: "recovery.permission.message", defaultValue: "Choose this folder or a folder containing it to check the original videos.")
        panel.prompt = String(localized: "recovery.permission.allow", defaultValue: "Allow Access")
        panel.directoryURL = expected
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        guard panel.runModal() == .OK, let url = panel.url,
              RecoveryScope.recordedRelativePath(file: recordedFile, inside: url, checkResolvedPaths: false) != nil else { return nil }
        return url.standardizedFileURL
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

// This maps one recorded absolute path, never searches a selected folder.
enum RecoveryScope {
    static func recordedRelativePath(file: URL, inside root: URL, checkResolvedPaths: Bool = true,
                                     allowExactFileScope: Bool = false) -> String? {
        guard file.isFileURL, root.isFileURL else { return nil }
        let f = file.standardizedFileURL
        let r = root.standardizedFileURL
        let base = r.pathComponents
        let path = f.pathComponents
        guard base.count > 1, path.starts(with: base),
              path.count > base.count || (allowExactFileScope && f.path == r.path)
        else { return nil }
        if checkResolvedPaths {
            guard r.resolvingSymlinksInPath().standardizedFileURL.path == r.path,
                  f.resolvingSymlinksInPath().standardizedFileURL.path == f.path else { return nil }
        }
        return path.dropFirst(base.count).joined(separator: "/")
    }
}

@MainActor
private final class RecoveryDirectoryValidation: NSObject, NSOpenSavePanelDelegate {
    let recordedFile: URL
    init(recordedFile: URL) { self.recordedFile = recordedFile }
    func panel(_ sender: Any, validate url: URL) throws {
        guard RecoveryScope.recordedRelativePath(file: recordedFile, inside: url, checkResolvedPaths: false) != nil else {
            throw NSError(domain: "Tagivy.Recovery", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "recovery.permission.exact", defaultValue: "Choose the original folder or a folder containing it.")
            ])
        }
    }
}
