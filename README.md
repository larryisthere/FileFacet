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

MVP 阶段 0–5 已完成实现：

- 可选应用锁默认关闭，支持系统身份验证、切换应用隐私遮罩、睡眠/锁屏强制锁定和闲置锁定时间。
- 单资料库只读授权、Security-Scoped Bookmark 恢复、FSEvents 防抖协调扫描和手动重扫。
- SQLite 事务索引、文件身份重命名关联、失效记录保留，以及 10,000 条容量验证。
- AVFoundation 媒体信息、UUID 缩略图、2GB 磁盘缓存清理、AppKit 视频网格和 Inspector。
- 层级标签、批量三态编辑、双向拖拽、合并、颜色和 Command-Z 撤销。
- Finder 标签只读幂等迁移、文件名搜索、父标签递归筛选、多标签 AND、未打标签、最近新增和无法访问筛选。

自动化与人工验收边界记录在 `docs/product/mvp-acceptance.md`。

## 修改正式显示名

显示名集中在 Xcode build setting `APP_DISPLAY_NAME`。内部 Swift module、target、scheme、仓库目录和 Bundle Identifier 可以继续保持稳定。
