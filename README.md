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

## 修改正式显示名

显示名集中在 Xcode build setting `APP_DISPLAY_NAME`。内部 Swift module、target、scheme、仓库目录和 Bundle Identifier 可以继续保持稳定。
