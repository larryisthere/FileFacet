import AppKit

@MainActor
struct LibraryPicker {
    func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择包含视频的文件夹"
        panel.message = "将递归导入所选文件夹及子文件夹中的视频。"
        panel.prompt = "导入"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
