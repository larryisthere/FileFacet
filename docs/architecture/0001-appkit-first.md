# ADR-0001：AppKit-first 主界面架构

- 状态：已接受
- 日期：2026-07-15

## 背景

产品需要支持至少 10,000 个视频、层级标签、多选、批量标签、双向拖拽、键盘操作、菜单验证和原生窗口隐私行为。

## 决策

- 主窗口使用 `NSWindowController`。
- 三栏结构使用 `NSSplitViewController`。
- 标签树使用 `NSOutlineView`。
- 视频网格使用 `NSCollectionView`。
- Inspector 使用 AppKit 视图控制器。
- 设置、首次引导和身份验证等轻量辅助界面使用 SwiftUI，通过 `NSHostingController` 接入。
- AppKit 控制器持有焦点、选择、拖拽、菜单和窗口级展示状态。
- 资料库、筛选、扫描、媒体解析和数据库状态进入独立服务层。
- 同一份业务状态只保留一个权威来源。

## 结果

核心交互可以直接使用 AppKit 的复用、Responder Chain、拖拽和多选能力。SwiftUI 辅助页保持轻量，正式产品名调整不会影响核心模块结构。
