# 中英双语与本地化 Design

状态：已实施并通过用户验收（2026-07-30）

关联需求：[中英双语与本地化 Requirements](localization-requirements.md)

视觉稿：[中英双语视觉与状态原型](../prototypes/localization/index.html)

## 1. 设计原则

1. 英文是代码中的开发语言和运行时回退语言。
2. 用户可见文案统一进入 `Resources/Localizable.xcstrings`。
3. 用户数据保持原值，只作为本地化模板参数。
4. 展示文案不承担业务身份、分支判断或持久化值。
5. 用户错误在界面边界完成本地化；底层错误保留稳定 case，避免携带未被消费的展示文案或 operation 参数。
6. 主窗口继续遵循原生 AppKit 信息层级，不因本地化引入新的交互入口。

## 2. 资源结构

新增：

```text
Resources/
└── Localizable.xcstrings
```

String Catalog 配置：

- Source Language：English
- Localizations：English、Simplified Chinese
- Extraction State：对已确认 key 使用 manual 或 migrated，避免资源生成时丢失
- Plural Variations：包含数量的英文文案至少提供 `one` 和 `other`

同步修改：

- `VideoTagManager.xcodeproj/project.pbxproj`
- `tool/generate_xcode_project.rb`

工程生成脚本需要登记 `Localizable.xcstrings` 并加入 App target Resources。`knownRegions` 登记 `en`、`zh-Hans` 和 `Base`。

## 3. Key 规则

使用语义化、稳定的英文 key：

```text
menu.file
menu.file.import
library.allVideos
library.recent
library.untagged
import.progress.scanningFolder
import.result.summary
tag.action.create
tag.draft.pendingSummary
inspector.detail.fileSize
settings.privacy.title
lock.authentication.reason
error.database.open
```

约束：

- key 描述含义，不复制英文展示文案。
- 用户数据不得进入 key。
- 同义文案仅在语境、语法和辅助功能要求一致时复用。
- 菜单标题、按钮、Tooltip 和 VoiceOver Label 可以分别拥有 key。
- 复数、完整句子和参数顺序由 String Catalog 管理。

## 4. 代码访问方式

AppKit 和共享逻辑优先使用：

```swift
String(localized: "library.allVideos")
```

带参数的完整句子使用类型安全插值并由 String Catalog 提供复数变化：

```swift
String(localized: "selection.videoCount \(count)")
```

SwiftUI 中需要动态值或显式语境时使用 `String(localized:)`；固定展示文本可以使用本地化 key 对应的 `Text` 初始化方式。所有路径最终读取同一 String Catalog。

不新增第三方本地化框架。若少量重复调用影响可读性，可以在工程内增加窄封装；封装不得隐藏 Bundle、Locale 或 fallback 行为。

## 5. 展示身份解耦

当前 `SidebarViewController` 多处通过 `group.title == "标签"` 判断标签分组。实施时为侧栏节点增加稳定身份：

```swift
enum SidebarGroupKind {
    case library
    case tags
}

final class SidebarGroupNode {
    let kind: SidebarGroupKind
    let title: String
    var children: [Any]
}
```

展开状态、排序按钮、右键菜单、选择恢复和拖放判断全部读取 `kind`。本地化后的 `title` 只负责展示。

其他稳定值继续保持：

- `TagSortMode.rawValue`
- `SettingsSection.rawValue`
- `LibraryFilter`
- UserDefaults key

## 6. 动态文案

### 6.1 数量

以下类型进入复数资源：

- 视频数量
- 标签数量
- 文件夹和输入项目数量
- 导入新增、已存在和失败数量
- 多选和移除数量

英文：

```text
1 video
2 videos
```

简体中文：

```text
1 个视频
2 个视频
```

### 6.2 导入结果

当前导入结果由多个中文片段拼接。实施时保留结构化数据：

```swift
struct ImportResultPresentation {
    let addedCount: Int
    let existingCount: Int
    let failedVideoCount: Int
    let failedInputCount: Int
}
```

界面层根据存在的字段选择完整模板，或通过 `ListFormatter` 连接已经完整本地化的项目。标题、明细和恢复动作分别拥有明确 key。

### 6.3 草稿摘要

标签草稿中的新建、添加和移除数量沿用同一结构化策略。不得先生成中文片段再用固定中文标点连接。

## 7. 错误边界

数据库错误实施时区分：

- 稳定的内部错误 case
- 日志中的错误类别
- 用户看到的本地化标题、原因和建议

`DatabaseError` 暴露稳定 case，由 `ApplicationCoordinator`、`LibraryAccessCoordinator` 或对应 ViewController 映射为用户文案。未进入日志、分支或恢复策略的数据不在底层错误中保留。

授权、导入、筛选和标签错误遵循相同边界。用户错误至少包含：

- 发生了什么
- 当前数据是否保留
- 用户可以执行的下一步

## 8. 文件级迁移

### 8.1 App 与菜单

- `App/ApplicationCoordinator.swift`
- `App/AppConfiguration.swift`
- `Core/Security/AuthenticationService.swift`
- `Features/Lock/LockView.swift`

覆盖菜单、关于、设置、退出、版本、验证原因与锁定状态。

### 8.2 主窗口

- `Features/Library/LibrarySplitViewController.swift`
- `Features/Library/SidebarModel.swift`
- `Features/Library/SidebarViewController.swift`
- `Features/Library/VideoGridViewController.swift`
- `Features/Library/InspectorViewController.swift`

先完成侧栏身份解耦，再迁移标题、Toolbar、空状态、菜单、弹窗、详情和标签草稿。

### 8.3 导入与数据库错误

- `Core/FileAccess/LibraryPicker.swift`
- `Core/FileAccess/LibraryAccessCoordinator.swift`
- `Core/Database/DatabaseError.swift`
- `Core/Database/DatabaseStore.swift`

先把展示模型与内部诊断分开，再迁移动态导入结果和错误。

### 8.4 设置

- `Core/Preferences/PreferencesStore.swift`
- `Features/Settings/SettingsView.swift`

设置 section 身份继续使用 enum case；标题、闲置间隔和说明进入 String Catalog。

## 9. 布局适配

重点检查：

- File 菜单中的长命令
- 空资料库说明
- Toolbar 搜索框和分类标题
- 224pt 左侧栏中的英文系统分类
- 268pt Inspector 中的分段控制、按钮和草稿摘要
- 设置中的表单 Label 和说明
- 导入状态标题、明细和操作按钮
- 删除确认和错误弹窗

处理顺序：

1. 依赖 intrinsic content size。
2. 将固定宽度改成合理最小值与弹性约束。
3. 为说明和状态文案允许换行。
4. 对路径、文件名和次要长文本使用系统截断。
5. 窄窗口下让 Toolbar 使用系统溢出能力。

## 10. 公开资料

应用实现和验收完成后：

- 移除 README 中“英文本地化计划中”的提示。
- `CHANGELOG.md` 使用英文记录用户可见变化。
- GitHub Release Notes 优先英文。
- `README.zh-CN.md` 保持简体中文入口。
- Issue 模板与贡献入口优先英文。

## 11. 验证边界

工程验证要求 Debug 构建成功；执行权限遵循 `AGENTS.md`。参考命令：

```bash
xcodebuild -project VideoTagManager.xcodeproj -scheme VideoTagManager -configuration Debug -derivedDataPath .build/DerivedData build
```

本轮不自动启动 App、不切换系统语言、不执行截图检查、不运行自动化测试。构建完成后由用户验收：

- 英文完整路径
- 简体中文完整路径
- 其他语言回退英文
- 英文长文案布局
- VoiceOver

用户明确验收通过后，再同步需求状态、CHANGELOG、README 并进入提交与发布。
