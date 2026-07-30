# 文件夹结构生成层级标签 Technical Design

状态：已实现并通过用户验收（2026-07-30）

关联需求：`docs/product/folder-structure-tag-import-requirements.md`

基础导入设计：`docs/product/manual-video-import-design.md`

## 1. 设计边界

现有菜单选择与 Finder 拖入继续在 `VideoImportPlan` 和 `LibraryAccessCoordinator` 汇合。新功能只在计划包含文件夹时解析一次导入方式，随后继续使用现有授权、发现、分批入库、刷新、取消和完成反馈。

SwiftUI `PreferencesStore` 持有唯一偏好状态。`FolderImportMethodPresenter` 只负责在主窗口展示 AppKit Sheet并返回一次性决定。`LibraryAccessCoordinator` 不持有窗口或设置界面。

## 2. 偏好与方式解析

`FolderImportPreference` 使用稳定字符串保存：

- `ask`
- `direct`
- `folderTags`

根目录是否进入标签树使用独立布尔偏好。缺失和未知方式回退 `ask`，根目录选项默认关闭。

固定方式直接返回执行方式。“每次询问”展示 Sheet；勾选不再询问后同时保存方式及相关根目录选项，取消不产生写入。

## 3. 导入请求

`LibraryImportRequest` 携带本批次最终方式。目录标签选项只传给实际目录来源；混合输入中的文件来源继续使用直接导入。

启用根标签时，每个目录来源将自身 `lastPathComponent` 作为标签链前缀。关闭时从 `DiscoveredVideo.relativePath` 的父目录组件开始。文件名始终从标签链中排除。

## 4. 数据库写入

`DatabaseStore.importVideos` 继续以 100 个视频为一个事务：

1. 按现有全局文件身份创建或复用视频。
2. 新视频执行一次 Finder 标签导入。
3. 迭代查询或创建目录标签链。
4. 使用 `(library_id, parent_id, normalized_name)` 复用同父级标签。
5. 只把最深层标签通过 `INSERT OR IGNORE` 关联到视频。
6. 标签创建、视频位置和关系写入在同一批事务中提交。

取消后已提交批次保持有效，当前未提交批次回滚。现有 Schema 已具备标签唯一约束和幂等关系表，因此不升级数据库版本。

完成结果继续显示新增、已存在和失败数量，并在确实创建新目录标签时追加创建数量。

## 5. 文件系统边界

`NSOpenPanel.resolvesAliases` 关闭。`VideoFileDiscovery.importRoot` 和目录枚举同时检查 Finder Alias、符号链接和 Package，保证菜单与拖入遵循同一过滤规则。

深层目录使用迭代标签创建，不引入递归调用。目录名称只进入本地数据库，不写入日志或网络。

## 6. 验证边界

实现阶段和验收后收尾均遵循项目的构建验证边界，不由代理启动或操作 App。用户验收通过后已补充偏好持久化、深层目录、既有标签共存、根标签、同名复用和幂等关系的关键自动化测试源码；真实 Finder Alias 继续保留为设备验证项。自动化测试命令尚未执行。
