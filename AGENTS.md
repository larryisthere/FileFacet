# AGENTS.md

## 沟通规则

1. 直接说明结论，省略反向对比句式。
2. 永远保持中立、客观和理性。
3. 永远使用用户视角沟通产品问题。

## 项目事实顺序

发生冲突时按以下顺序判断：

1. 当前代码与自动化测试
2. `docs/architecture/` 中已接受的架构决策
3. `docs/product/` 中的当前需求
4. README 与历史讨论

## 工程规则

- 主窗口、视频网格、标签树、多选、拖拽、菜单和窗口行为使用 AppKit。
- SwiftUI 只用于设置、引导、身份验证等轻量辅助界面，并通过窄接口接入 AppKit。
- 数据库使用系统 SQLite3；引入第三方运行时依赖前必须记录架构决策。
- 默认不发起网络请求，不记录完整文件路径、文件名、标签内容或 Bookmark 数据。
- 所有扫描、媒体解析和缩略图任务都在后台执行，UI 更新回到 MainActor。
- 用户视频只读访问；不得移动、重命名、修改或删除原始视频。

## 验证命令

```bash
xcodebuild -project VideoTagManager.xcodeproj -scheme VideoTagManager -configuration Debug -derivedDataPath .build/DerivedData build
xcodebuild -project VideoTagManager.xcodeproj -scheme VideoTagManager -configuration Debug -derivedDataPath .build/DerivedData test
```

本地构建并运行：

```bash
./script/build_and_run.sh
```
