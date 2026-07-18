import AppKit
import UniformTypeIdentifiers

@MainActor
struct LibraryPicker {
    func chooseImportItems() -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = "选择要导入的视频和文件夹"
        panel.message = "可选择多个视频、多个文件夹或两者组合；文件夹会递归导入。"
        panel.prompt = "导入"
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
