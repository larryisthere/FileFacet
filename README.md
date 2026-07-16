# video_tag_manager

`video_tag_manager` 是项目内部代号和仓库目录名。当前开发显示名为 “Video Tag Manager”，正式产品名可以在后续发布前集中修改。

这是一个 AppKit-first 的原生 macOS 视频标签管理器。用户可以反复导入不同文件夹中的视频，也可以把多个视频、多个文件夹或两者组合直接拖入中部区域，在统一资料库中建立独立于 Finder 的层级标签索引，并使用系统默认播放器打开视频。

## 当前基线

- 当前版本：1.0.0
- 最低系统版本：macOS 14 Sonoma
- UI：AppKit 主窗口，SwiftUI 辅助界面
- 数据库：系统 SQLite3
- 文件访问：Security-Scoped Bookmark，只读
- 媒体信息：AVFoundation
- 文件监听：FSEvents
- 身份验证：LocalAuthentication
- 网络：默认无网络请求

## 工程入口

- Xcode 工程：`VideoTagManager.xcodeproj`
- Scheme：`VideoTagManager`
- 本地运行：`./script/build_and_run.sh`
- 产品需求：`docs/product/mvp-requirements.md`
- 架构决策：`docs/architecture/0001-appkit-first.md`

## 当前实现进度

MVP 阶段 0–5 的核心工程已经建立，当前能力包括：

- 可选应用锁默认关闭；启用后支持系统身份验证、切换应用隐私遮罩、睡眠/锁屏强制锁定和闲置锁定时间。
- “文件 > 导入视频…”与 `⇧⌘I` 可递归导入文件夹；中部区域支持直接拖入多个视频、多个文件夹或混合内容，并为文件夹或文件保存对应的 Security-Scoped Bookmark。
- 导入阶段、批次进度、取消操作和结果显示在中部标题下方；批次内自动合并父子重叠来源，单个输入失败时继续处理其余项目。
- SQLite Schema 7、稳定文件身份与标准化 URL 哈希回退判重、跨来源移动位置更新、确认删除清理，以及 Finder 导入标签顶级平铺迁移。
- AVFoundation 媒体信息、UUID 缩略图、2GB 磁盘缓存清理、AppKit 视频网格和 Inspector。
- 层级标签、批量三态编辑、双向拖拽、合并、颜色和单步 Command-Z 撤销。
- 可通过视频右键菜单末项或 `Command-Delete` 将单个或多个视频移出资料库；确认提示保留原视频，操作支持单步撤回。
- Finder 标签在视频首次入库时单向导入、文件名搜索、父标签递归筛选、多标签 AND、未打标签和最近添加。
- FSEvents 仅静默维护已有视频；同一目录的文件来源共享监听，来源中新出现的视频始终需要用户再次手动导入。

自动化与人工验收边界记录在 `docs/product/mvp-acceptance.md`。

## 修改正式显示名

显示名集中在 Xcode build setting `APP_DISPLAY_NAME`。内部 Swift module、target、scheme、仓库目录和 Bundle Identifier 可以继续保持稳定。
