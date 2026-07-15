# Mac 原生轻量视频标签管理器：建项准备与技术调研

更新日期：2026-07-14
状态：建项决策已确认；内部代号与仓库名为 `video_tag_manager`，最低支持 macOS 14

## 1. 结论

这份 MVP 具备直接进入原生 macOS 开发的条件。建议采用 AppKit-first：主窗口、三栏结构、视频网格、标签树、多选、拖拽、菜单和键盘命令全部由 AppKit 管理；SwiftUI 只承载首次引导、设置和身份验证等轻量辅助界面。

建议首版只使用系统框架与系统 SQLite，不引入第三方运行时依赖。这样有利于控制安装包体积、启动速度、隐私边界和长期维护成本。

内部代号与仓库目录使用 `video_tag_manager`。当前开发显示名为 “Video Tag Manager”，正式产品名可以在后续发布前集中修改。最低支持 macOS 14 Sonoma。

## 2. 已确认的本机开发条件

- Xcode 26.5（Build 17F42）
- Swift 6.3.2
- macOS 26.5 SDK
- AppKit、AVFoundation、LocalAuthentication、CoreServices/FSEvents、SQLite3 均可由 Swift 工程直接引用
- 目标项目目录：`/Users/larryisthere/Public/Local Projects/<repo-name>`

项目形态建议使用标准 Xcode macOS App 工程。应用需要 App Sandbox、文件访问授权、签名、Entitlements、Info.plist、Unit Test 与 UI Test target，Xcode 工程适合作为主入口。

## 3. 修正后的技术选型

### 开发语言

- Swift
- Swift Concurrency 用于扫描、媒体解析和数据库任务
- UI 更新固定在 MainActor

### UI

- AppKit 构建主窗口和核心视频管理界面
- `NSSplitViewController` 管理 Sidebar、视频网格和 Inspector
- `NSOutlineView` 管理系统筛选项与层级标签
- `NSCollectionView` 管理大量视频、多选、键盘操作和拖拽
- `NSViewController` 作为核心页面和生命周期边界
- SwiftUI 仅用于设置、首次引导、身份验证等轻量辅助界面，通过 `NSHostingController` 接入

状态归属建议：

- AppKit 控制器持有窗口级展示状态、焦点、选择、拖拽和菜单验证
- 独立 Store/Service 持有统一资料库、来源授权、筛选条件、导入进度和数据库状态
- SwiftUI 辅助页通过小型 ViewModel 或明确回调访问服务层
- 同一份选择或业务数据只保留一个权威来源

### 数据与系统能力

- SQLite3：持久化索引、标签树、视频与标签关系、迁移记录
- AVFoundation：异步读取时长、分辨率并生成缩略图
- Security-Scoped Bookmark：保存多个已导入来源文件夹的长期访问权
- FSEvents：监听目录变化，触发已有视频的静默全来源协调
- LocalAuthentication：Touch ID 与系统密码验证
- NSWorkspace：默认播放器打开、Finder 定位
- URL Resource Values：基础文件属性、文件资源标识符与 Finder 标签读取

## 4. 推荐工程结构

```text
<ProductName>/
├── <ProductName>.xcodeproj
├── App/
│   ├── AppDelegate.swift
│   ├── AppEnvironment.swift
│   └── ApplicationCoordinator.swift
├── Core/
│   ├── Database/
│   ├── FileAccess/
│   ├── Media/
│   ├── Scanning/
│   ├── Security/
│   └── Logging/
├── Features/
│   ├── Library/
│   ├── Tags/
│   ├── Search/
│   ├── Inspector/
│   ├── Onboarding/
│   └── Settings/
├── UI/
│   ├── AppKit/
│   └── SwiftUI/
├── Resources/
├── Tests/
│   ├── Unit/
│   ├── Database/
│   └── Fixtures/
└── docs/
    ├── product/
    ├── architecture/
    └── decisions/
```

MVP 初期建议保持一个 App target、一个 Unit Test target、一个 UI Test target。等核心模块边界稳定后，再评估是否拆为本地 Swift Package。

## 5. 主窗口与交互架构

```text
MainWindowController
└── NSSplitViewController
    ├── SidebarViewController
    │   └── NSOutlineView
    ├── VideoGridViewController
    │   └── NSCollectionView
    └── InspectorViewController
```

窗口级协调器负责：

- 当前筛选与搜索条件
- 视频选择集合
- Inspector 显隐
- 工具栏、菜单与快捷键验证
- 拖拽路由
- 锁定时的隐私遮罩

视频网格建议使用 diffable data source。数据库查询返回轻量视频摘要；缩略图经内存缓存和磁盘缓存按需加载。单元格复用时必须取消旧的缩略图请求，避免快速滚动出现错图。

标签树拖拽需要集中校验：禁止拖到自身或子孙节点，保证同级 `sortOrder` 稳定更新，移动与排序在单个数据库事务中完成。

## 6. 数据模型调整建议

原始模型可以覆盖主要功能，建议在建表时补齐以下字段和表，减少后续迁移成本。

### libraries

- `id`
- `name`
- `root_bookmark_data`
- `created_at`
- `last_scan_at`
- `last_fsevent_id`

### videos

- 原需求中的全部字段
- `volume_identifier`
- `file_resource_identifier`
- `metadata_status`
- `thumbnail_status`
- `availability_status`
- `last_seen_scan_id`

建议状态分开存储。文件可访问性、媒体信息解析和缩略图生成属于三类独立结果，合并为一个 `status` 会限制错误恢复和 UI 表达。

### tags

- 原需求中的全部字段
- `library_id`
- `normalized_name`

即使 MVP 只有一个资料库，也建议保留 `library_id`，防止未来多资料库支持时出现大规模数据迁移。

### finder_tag_import_mappings

- `library_id`
- `external_key`
- `tag_id`
- `first_imported_at`
- `last_seen_at`

单独保存 Finder 标签映射，保证用户移动、重命名或合并导入标签以后，后续新增视频首次导入时仍不会按旧名称重复创建标签。仅在 `tags.source` 中记录 `finder` 无法覆盖这一场景。

### source_authorizations

- `id`
- `library_id`
- `display_name`
- `root_bookmark_data`
- `created_at`
- `last_event_id`
- `health_status`

每次用户选择的文件夹保存为独立授权来源。来源离线、权限异常或 Bookmark 失效时保留视频记录。
当前 MVP 运行时读取来源 ID、名称、Bookmark 和创建时间；`last_event_id` 与 `health_status` 为后续事件续接和来源健康模型预留，当前不参与状态判断。

### video_locations 与 import_runs

- `video_locations` 保存视频、授权来源、相对路径、标准化绝对 URL 的 SHA-256 回退键和最近确认时间。
- `import_runs` 保存每次手动导入的开始、完成、取消以及新增、已存在、失败数量。
- 视频优先通过卷标识符和文件资源标识符全局判重；稳定身份缺失时使用标准化绝对 URL 的 SHA-256 回退键。

### 关键约束与索引

- `video_tags(video_id, tag_id)` 唯一约束
- `tags(parent_id, sort_order)` 索引
- `video_locations(source_id, relative_path)` 唯一约束
- `video_locations(fallback_path_key)` 查询索引
- 全局文件身份字段索引
- `videos(availability_status)` 索引
- `videos(creation_date)` 索引
- 外键开启并在启动时执行 schema migration
- SQLite 使用 WAL、事务化批量 Upsert 和单写入协调器

## 7. 手动导入与文件变化策略

手动导入拆为三个阶段：

1. 快速发现：递归枚举文件，只读取路径、扩展名、大小、时间与文件身份，批量写入数据库，尽快展示网格。
2. 后台补全：使用受限并发读取 AVFoundation 元数据，不为 10,000 个文件同时创建任务。
3. 缩略图生成：按可见项优先，其余内容低优先级补全；单个文件失败不会停止队列。

FSEvents 提供“目录发生了变化”的信号，低优先级维护任务只协调已有视频。未知新文件不会创建记录。来源可访问时，移动通过文件身份更新位置，确认删除后移除视频记录；来源离线或权限异常时不执行删除。

重命名或移动的关联顺序建议：

1. 在统一资料库中全局匹配卷标识符与文件资源标识符。
2. 匹配成功后更新相对路径并保留应用标签。
3. 静默维护匹配失败时忽略未知文件；新视频只能通过用户手动导入创建。

文件资源标识符需要作为不透明数据处理。它能提升同一卷内重命名与移动的识别率，但无法提供跨文件系统的永久身份保证。

## 8. 视频格式的产品定义

建议把“支持 MP4、MOV、M4V、MKV、AVI、WebM”明确为：

- 应用能发现、索引、显示基础文件信息并交给系统默认应用打开这些扩展名。
- AVFoundation 能解析时显示时长、分辨率和缩略图。
- AVFoundation 无法解析容器或编码时仍保留记录，显示通用视频图标和“媒体信息不可用”。

MP4、MOV、M4V 的系统解析覆盖通常较好；MKV、AVI、WebM 的结果取决于具体容器、编码和系统能力。MVP 不打包 FFmpeg，因此不能承诺每个文件都能生成缩略图或被系统默认播放器成功播放。

## 9. Finder 标签迁移

优先通过系统 URL Resource Values 读取 Finder 标签，底层对应 Finder 标签元数据。迁移过程应满足：

- 首次导入带 Finder 标签的视频时直接创建顶级标签；顶级已有同名标签时复用并合并视频关系。
- 每个视频只在首次加入资料库索引时读取并导入一次 Finder 标签。
- 使用标准化外部键去重，同时保留用户可见原名。
- 导入映射独立保存，支持标签被重命名、移动或合并后继续为新视频复用同一内部标签。
- 只读取 Finder 标签；应用内编辑只操作 SQLite。
- 已入库视频后续重扫不根据 Finder 当前状态刷新应用内标签关系。
- Finder 标签读取失败只影响该文件的迁移，不影响视频入库。

需要在开发阶段准备包含颜色编号、重复名称、特殊字符和空标签的真实 Finder 样本，验证系统返回值的解析规则。

## 10. 应用锁与隐私状态

建议由独立 `LockCoordinator` 管理状态机。应用锁由设置开关控制，默认关闭：

```text
launching → locked → authenticating → unlocked
                         ↓
                       failed
```

锁定动作必须先覆盖主窗口敏感内容，再触发或等待身份验证。窗口失去活动状态时立即安装隐私遮罩；启用应用锁后，会话锁定和屏幕睡眠还会把应用状态切换为锁定。遮罩由 AppKit 放在窗口内容最上层，内容为空白或中性占位，不包含文件名、标签或缩略图。

应用锁关闭时不执行身份验证和自动锁定。应用锁开启后，“永不”只影响闲置自动锁定，Mac 睡眠和系统锁屏后仍强制锁定。

空闲时间还需明确语义。建议按“用户在整个 Mac 上无输入的时间”计算，符合用户对闲置锁定的直觉；若按“没有操作本应用”计算，用户观看其他窗口时会更频繁地被锁定。

日志仅记录匿名事件类型、耗时、数量和错误分类。禁止记录完整路径、文件名、标签名、Bookmark 数据和缩略图标识的可逆映射。

## 11. 搜索与筛选语义

- 点击父标签：结果包含该标签直接关联的视频及所有后代标签关联的视频。
- 多标签 AND：每个选中标签先扩展为各自子树，再对各组结果取交集。
- 同一个视频匹配同一子树中的多个标签时只显示一次。
- “未打标签”以 `NOT EXISTS video_tags` 判断。
- “最近添加”建议定义为首次进入应用索引的时间，避免文件原始创建时间被复制或导出工具改写后造成理解偏差。
- 文件名搜索对 10,000 条记录可以先采用 SQLite 大小写不敏感包含查询；性能数据不足以达到目标时再引入 FTS。

标签数量建议显示“包含后代的去重视频数”，与点击标签后的筛选结果保持一致。

## 12. MVP 实施阶段

### 阶段 0：工程基线

- 建立 Xcode 工程、Sandbox 与签名配置
- 建立 AppKit 主窗口和三栏空壳
- 建立数据库迁移框架、日志隐私规则和测试 target
- 固化最低系统版本与 Swift 并发规则

### 阶段 1：统一资料库与手动导入

- 身份验证和隐私遮罩
- 多来源 Security-Scoped Bookmark
- SQLite Schema 7、来源、位置、URL 哈希回退身份、分批导入事务和 Finder 导入标签顶级平铺迁移
- 快速文件发现、已有索引即时展示、重复手动导入

### 阶段 2：媒体网格

- NSCollectionView 网格、多选、缩放
- AVFoundation 元数据和缩略图队列
- Inspector、默认播放器打开、Finder 定位、复制路径

### 阶段 3：标签系统

- NSOutlineView 层级标签
- 创建、重命名、删除、移动、排序、合并、颜色
- 单个与批量标签编辑、三态选择、Inspector 草稿应用与取消
- Inspector 搜索结果快捷新建标签、父标签选择、待新建状态，以及标签创建与视频关联的原子写入
- 视频与标签双向拖拽

### 阶段 4：迁移、筛选与文件变化

- Finder 标签幂等迁移
- 文件名搜索、父标签递归筛选、多标签 AND
- 未打标签与最近添加
- FSEvents 静默协调、移动关联、确认删除清理

### 阶段 5：验收与性能

- 10,000 条合成索引性能测试
- 大目录首次导入与重复导入测试
- 损坏、无权限、不可解析和导入中断测试
- 锁屏、睡眠、切换应用与身份验证失败测试
- 安装包体积、冷启动和筛选耗时测量

## 13. 建议的首批自动化验证

- SQLite schema migration 与回滚保护
- 标签树防环、移动、排序、合并事务
- 父标签递归筛选和多标签 AND
- 批量标签三态计算
- Finder 标签重复导入与重命名后再次导入
- 导入中断不会删除既有视频
- 文件重命名后保留标签
- 无法解析媒体时仍保留基础记录
- 缩略图请求取消和单元格复用不会错图
- Bookmark 失效和权限恢复流程
- LockCoordinator 状态转换与隐私遮罩时机

## 14. 已确认项与后续细化

### 已确认

1. 内部代号和仓库目录使用 `video_tag_manager`。
2. 当前开发显示名为 “Video Tag Manager”，正式产品名支持后续集中修改。
3. 最低支持 macOS 14 Sonoma。
4. 删除父标签时删除整棵子树，只删除标签关系，并提供确认与撤销。
5. 标签合并时把视频关系、子标签和 Finder 来源映射迁移到目标标签。
6. “最近添加”按首次进入索引的时间计算，默认 30 天。
7. 身份验证设置默认关闭；应用切换时隐私遮罩立即生效，启用应用锁后睡眠和系统锁屏强制重新验证。

### 实现阶段继续细化

1. Inspector 在无选择、多选和失效文件三种状态下的字段与操作。
2. 单步撤销的状态提示，以及最近一次成功标签操作被新操作覆盖时的菜单状态。
3. 缩略图缓存达到 2GB 上限后的清理提示。

## 15. 建项后的第一份可运行里程碑

第一份可运行版本建议只验证基础架构：

- 身份验证开关关闭时直接显示资料库界面；开启后启动显示身份验证页。
- 验证成功后显示 AppKit 三栏窗口。
- 首次选择一个目录并保存 Security-Scoped Bookmark。
- 重启应用后恢复访问权限。
- 左侧显示系统筛选占位项，中间显示空网格，右侧 Inspector 可隐藏。
- 锁定或切换应用时敏感区域被隐私遮罩覆盖。

这个里程碑能尽早验证窗口架构、权限与隐私三条高风险链路，然后再接入批量扫描和视频网格。
