# 扫描新视频 Technical Design

- 状态：正式实现已通过用户验收（2026-08-30）
- 需求：[`scan-new-videos-requirements.md`](scan-new-videos-requirements.md)
- 原型：[`../prototypes/scan-new-videos/index.html`](../prototypes/scan-new-videos/index.html)

## 1. 设计概览

扫描使用现有来源授权和视频发现能力，新增一层只存在于会话中的候选状态：

```text
工具栏 / 文件菜单
        │
        ▼
LibraryAccessCoordinator
        │
        ├─ 可访问目录授权 ──> VideoFileDiscovery
        │                         │
        │                         ▼
        └──────────────> DatabaseStore 只读判重
                                  │
                                  ▼
                         ScannedVideoCandidate[]
                                  │
                  临时侧栏 + 候选网格 + Inspector
                                  │
                         用户选择部分或全部
                                  │
                                  ▼
                      现有 DatabaseStore.importVideos
```

扫描阶段不创建视频记录。导入阶段按候选所属来源分组，复用现有写入、标签和媒体处理管线。

## 2. 状态模型

### ScannedVideoCandidate

候选包含：

- 稳定候选 ID：文件身份优先，标准化位置回退。
- `sourceID` 与来源显示名。
- `DiscoveredVideo` 基础事实。
- 用于 Inspector 和 Finder 定位展示的只读 URL；不进入日志和持久化候选表。

候选 ID 不包含扫描批次 ID，从而可在同一轮追加授权目录后稳定合并选择。重叠来源发现同一文件时保留第一条可访问来源。

### LibraryScanState

- `idle`：没有扫描任务或候选生命周期。
- `scanning`：正在枚举目录和执行只读判重。
- `results`：持有候选、已检查目录数、尚未覆盖目录数和失败目录数。
- `importing`：正在导入当前选择，候选结果仍由 Coordinator 持有。
- `completed`：本次扫描已经没有剩余或失败候选，携带扫描会话累计的新增及已存在视频 ID，供界面关闭临时结果并导航。
- `failed`：整轮扫描无法完成，回到资料库并显示可观察错误。

候选、选择和临时导航均不持久化。关闭结果、再次扫描或开始常规导入会增加 revision 并结束旧任务与旧状态。

## 3. 来源授权与 schema 13

`source_authorizations` 增加 `scans_descendants INTEGER NOT NULL DEFAULT 0`：

- 文件来源为 `0`，只允许访问已选文件。
- 文件夹导入来源和用户通过扫描恢复流程选择的文件夹为 `1`。
- 恢复历史 Bookmark 时根据解析后的 URL 补写目录来源标记。
- `removeUnreferencedSourceAuthorizations` 继续删除无视频引用的文件来源，同时保留 `scans_descendants = 1` 的扫描目录。

该字段表达用户是否明确选择过一个可递归检查的目录。界面文案只说明可检查的文件夹，不展示 Bookmark、Security Scope 或字段名。

## 4. 扫描算法

1. 刷新当前 Bookmark 解析结果和可访问来源状态。
2. 选择 `scans_descendants = 1` 且当前可访问的目录来源。
3. 从文件来源位置推导未被任何目录来源覆盖的唯一父目录数量，仅用于用户恢复提示。
4. 逐个目录在 `.utility` detached task 中调用 `VideoFileDiscovery.discoverVideoResult`。
5. 调用 `DatabaseStore.unimportedVideos`，复用 `existingVideoID` 的稳定身份和路径回退规则执行只读判重。
6. 在 Coordinator 中按候选身份再次去重，合并重叠扫描范围。
7. 回到 MainActor 发布单次结果；旧 revision 的迟到结果直接丢弃。

单目录失败只增加失败计数。没有任何目录成功且存在目录来源时进入失败状态；至少一个目录成功时发布部分结果。

## 5. 追加扫描文件夹

`LibraryPicker.chooseScanFolders()` 使用原生 `NSOpenPanel`：只允许普通目录、多选、不解析 Alias。用户选择后：

1. 生成只读目录 Bookmark 并连接来源。
2. 保存 `scans_descendants = 1` 的来源授权。
3. 折叠父子重叠目录，避免同轮重复枚举。
4. 重新执行整轮扫描并替换候选结果。

该流程不会立即导入目录内视频，也不会创建标签。
文件夹准备复用扫描 task/revision 生命周期；手动导入、关闭结果或新扫描会取消旧任务。全部文件夹准备失败时恢复此前候选并显示失败说明。

## 6. 候选导入

- `importScannedVideos(ids:)` 只接受当前 revision 中仍存在的候选。
- 写入前按当前文件夹导入偏好解析一次 `FolderImportMethod`。
- 候选按 `sourceID` 分组，并为每个来源建立对应 `FolderTagImportOptions`。
- 每组调用 `DatabaseStore.importVideos`；成功项从候选移除，失败项保留。
- 完成后刷新标签、可访问 URL、当前资料库查询、侧栏数量和 Inspector，随后进入现有媒体处理队列。
- 再次判重可能把候选识别为“已存在”；该候选同样从临时结果移除，并在完成反馈中计入已存在。
- Coordinator 在同一扫描会话内累计每次部分导入返回的视频 ID。最后一个候选成功处理后发布 `completed`，清空候选会话，并把常规导入通知恢复为 `idle`，避免跳转后再次显示“查看”通知。

扫描导入与常规导入共用 `importTask` 串行边界。导入开始时取消正在进行的扫描；扫描开始时要求没有导入任务。

## 7. AppKit 映射

### 工具栏与菜单

- `ApplicationCoordinator` 的“文件”菜单和 `LibrarySplitViewController` 工具栏都调用 `LibraryAccessCoordinator.scanForNewVideos()`。
- 工具栏使用 `arrow.clockwise` 系统图标，位于搜索项之前。
- `LibrarySplitViewController` 根据资料库总数、设置状态、导入状态和扫描状态统一验证两个入口。

### 左侧临时导航

- `SidebarViewController` 在现有资料库分组之前插入会话级 `scanResults` 分组。
- 分组标题提供关闭按钮；子项显示“待导入视频”和候选数量。
- 切换其他导航只改变中部内容，不清除候选。关闭按钮通过 Split Controller 请求 Coordinator 清空扫描会话。

### 中部候选网格

- `LibraryContentViewController` 在规则栏 + 视频网格与 `ScanResultsViewController` 之间切换。
- 候选页自带状态区、未检查目录提示、选择栏、`NSCollectionView` 网格和无候选状态；全部候选成功处理后直接离开该页面。
- 搜索字段在候选模式转交给候选页；退出候选页后恢复常规查询搜索状态。
- 可见候选通过 `QLThumbnailGenerator` 请求会话级 Quick Look 预览；结果只保存在内存缓存，卡片复用时取消旧请求，关闭结果或再次扫描时清空缓存。生成失败继续显示通用影片图标。

### Inspector

- `InspectorViewController` 增加只读扫描上下文。
- 单选候选时显示文件名、相对位置、扩展名、大小和日期；多选显示数量与总大小。
- 扫描上下文隐藏标签编辑、重新定位和移除操作。

### 完成导航

- `LibrarySplitViewController` 收到 `completed` 后移除临时侧栏分组、清理候选预览并离开扫描内容页。
- 扫描会话只有新增视频时，通过现有 `VideoRevealRequest` 进入“最近添加”，选中累计新增视频并滚动到第一项。
- 扫描会话包含已存在记录时进入“所有视频”，选中累计新增及已存在视频。
- 仍有候选、未检查文件夹、目录检查失败或任何来源导入失败时继续保留扫描结果页，不触发完成导航。

## 8. 并发、失败与隐私

- Coordinator 的扫描和导入状态留在 MainActor，目录发现通过 detached utility task 执行，数据库判重在 actor 内执行。
- 每次扫描、追加目录、关闭结果或手动导入都推进 revision，阻止旧任务覆盖新状态。
- 日志只包含数量和错误类型；路径、文件名、标签与 Bookmark 保持 private 且不写入日志。
- 扫描不调用 `reconcileSources`，因此不会改变已有视频可用状态；FSEvents 维护继续使用原有独立路径。

## 9. 验证策略

- 当前轮只允许文本级静态检查：Swift 源文件结构、字符串目录 JSON、原型脚本、文档链接和 `git diff --check`。
- Debug 构建、自动化测试、真实目录扫描、系统文件夹选择器和 App 交互在用户提供对应当前轮授权后执行。
- 自动化测试源码在正式行为通过用户验收并获得测试代码变更授权后补充，优先覆盖 schema 迁移、只读判重、候选去重和扫描目录清理保留规则。
