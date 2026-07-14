# video_tag_manager

`video_tag_manager` 是项目内部代号和仓库目录名。当前开发显示名为 “Video Tag Manager”，正式产品名可以在后续发布前集中修改。

这是一个 AppKit-first 的原生 macOS 视频标签管理器。应用扫描用户授权的本地目录，为视频建立独立于 Finder 的层级标签索引，并使用系统默认播放器打开视频。

## 当前基线

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

阶段 1 已具备可运行链路：可选应用锁、资料库只读授权、Bookmark 恢复、已有索引即时展示、后台快速扫描和手动重扫。扫描支持 MP4、MOV、M4V、MKV、AVI、WebM，默认跳过隐藏目录、符号链接和 macOS Package；一次扫描只有在完整成功后才更新失效状态。

下一阶段接入 AVFoundation 元数据、缩略图队列以及网格与 Inspector 的媒体交互。

## 修改正式显示名

显示名集中在 Xcode build setting `APP_DISPLAY_NAME`。内部 Swift module、target、scheme、仓库目录和 Bundle Identifier 可以继续保持稳定。
