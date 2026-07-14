import AppKit

@MainActor
struct LibraryPicker {
    func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择视频资料库"
        panel.message = "应用将以只读方式扫描这个目录及其子目录。"
        panel.prompt = "选择资料库"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
