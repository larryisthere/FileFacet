# 视频分组展示设计

- 状态：HTML 原型与正式实现已验收
- 需求：[`video-grouping-requirements.md`](video-grouping-requirements.md)
- 交互原型：[`../prototypes/video-grouping/index.html`](../prototypes/video-grouping/index.html)

## 设计概览

分组是视频结果的展示状态，位于现有查询和排序之后：

```text
基础范围 + 搜索 + 筛选 + 排序
               │
               ▼
          有序视频结果
               │
        当前分组偏好与方向
               │
               ▼
     分组标题 + 现有视频卡片网格
```

查询层继续返回唯一、有序的视频列表。界面层根据当前分组依据计算稳定的分组键，把视频分配到唯一分组，并保留查询结果在每个组内的相对顺序。

## 状态模型

使用独立的浏览状态：

- `VideoGroupingKey`：`none`、`addedDate`、`createdDate`、`modifiedDate`、`duration`、`fileSize`、`resolution`。
- `VideoGroupingDirection`：`ascending` 或 `descending`。
- `collapsedGroupIDs`：当前浏览范围中被折叠的稳定分组 ID 集合，只在会话内维护。
- `groupingBeforeRecent`：进入“最近导入”前的分组快照，离开该分类时用于恢复。

常规范围中的分组依据与方向写入 `UserDefaults`。“最近导入”内的临时分组和折叠集合不持久化。分组不进入 `LibraryQueryRule`、`LibraryQueryRequest` 或智能分类 JSON。

## AppKit 映射

### 视频区域操作栏

- `LibrarySplitViewController` 持有当前分组偏好，并通过 `LibraryRuleBarContext` 传给 `LibraryRuleBarViewController`。
- `LibraryRuleBarViewController` 在现有排序入口之后增加分组入口；窗口 Toolbar 继续只承载当前标题、缩略图大小、搜索和两侧栏控制。
- 菜单项使用稳定枚举作为 `representedObject`，展示文案只负责本地化。
- 当前依据为 `none` 时显示“添加分组”；其他依据显示当前分组摘要、系统强调色和清除按钮。清除按钮把依据设为 `none`。

### 视频内容

- `VideoGridViewController` 接收分组描述和有序视频结果，生成 collection view sections。
- 每个 section 使用稳定分组 ID；Supplementary View 显示展开箭头、标题和数量。
- 折叠通过 section 的 item 数量隐藏或恢复卡片，保留查询结果与视频模型。
- 现有卡片、右键菜单、拖拽、键盘焦点、Quick Look 和多选行为继续复用 item ID。

### 状态生命周期

- 切换分组依据或主动切换浏览范围时清空 `collapsedGroupIDs`，滚动到顶部。
- 同一范围中的查询刷新保留仍存在的折叠分组 ID，并让新分组默认展开。
- 选择状态继续以视频 ID 保存。折叠、展开和视频跨组移动后，根据当前可见 items 同步 collection view selection；Inspector 继续接收完整选择。
- 关闭分组时尝试滚动到第一项已选视频；无选择时保留当前可见位置。
- 进入“最近导入”前保存当前分组，进入后临时使用 `addedDate + descending`；离开时恢复快照。“最近导入”内的切换与清除不写入 `UserDefaults`。

## 分组计算

- 日期分组使用 `Calendar.current` 与当前时区计算自然日边界。
- 数值区间采用需求文档中的固定阈值，区间采用明确的闭开边界，避免边界视频进入两个分组。
- 缺失值映射到稳定的 `unknown` 分组；未知分组排序权重固定为最后。
- 分组数量来自 section 中唯一视频 ID 的数量，不额外执行数据库计数查询。

## 性能与线程

- 当前查询、扫描、媒体解析和缩略图继续在后台执行。
- 当前结果在 `VideoGridViewController` 的 MainActor 上完成一次分桶；collection view sections 与选中状态在同一 UI 更新中同步。
- 分组遍历当前结果一次，目标复杂度为 O(n)。折叠和展开不重新执行资料库查询。

## 本地化与隐私

- 菜单、方向、分组标题、未知状态、Tooltip 和辅助功能标签进入 `Resources/Localizable.xcstrings`。
- 日期分组边界按当前 Locale 与 Calendar 计算，标题使用本地化固定文案。
- 日志不记录文件名、路径、标签、分组内容或用户选择。

## 实施边界

HTML 原型与 AppKit 实现已经用户验收。当前 MVP 文档与 Changelog 已同步；本次交互行为以用户验收为准，后续出现稳定回归路径时再补充对应自动化测试。
