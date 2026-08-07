# 离线资料库设计

- 状态：已完成，已授权发布
- 后续扩展：[`unavailable-videos-design.md`](unavailable-videos-design.md)
- 需求：[`offline-library-requirements.md`](offline-library-requirements.md)
- 交互原型：[`../prototypes/offline-library/index.html`](../prototypes/offline-library/index.html)

## 设计概览

本期复用现有资料库三栏界面，只增加运行时访问状态：

```text
来源 Bookmark + 当前挂载卷 + 视频位置
                  │
                  ▼
        LibraryAccessCoordinator
          ├─ 可访问 URL
          ├─ 离线视频 ID / 来源名称
          └─ 当前筛选与数量
                  │
        ┌─────────┼─────────┐
        ▼         ▼         ▼
      Sidebar   Video Grid  Inspector
```

数据库继续保存已索引视频和持久事实。外置卷是否在线由当前运行时计算，避免把临时状态写成永久记录。

## 访问状态计算

1. 从 `video_locations` 读取视频、来源、相对路径和视频卷标识符。
2. 从已保存 Bookmark 恢复已知来源 URL，并保持成功建立的 Security-Scoped Resource。
3. 在后台读取当前已挂载卷标识符，并检查已授权候选文件是否存在。
4. 任一已授权位置存在原文件时，将视频视为可访问并保留该 URL。
5. 没有可访问位置且记录所属卷未挂载时，将视频视为离线，并保留来源展示名称。
6. 来源卷仍挂载但单个文件不存在时，不标记为离线，由现有静默维护确认移动或删除。

卷标识符缺失时，只对 `/Volumes/<卷名>/…` 且对应卷根目录不存在的来源使用路径级后备判断。完整路径不进入日志或新增持久字段。

## 状态传播

- `VideoRecord.Availability.offline` 只用于协调层交付给界面的临时副本。
- `resolvedVideoURLs` 只包含当前确实存在且拥有安全范围访问权的文件。
- `offlineSourceNameByVideoID` 为检查器提供来源展示名称。
- 数据库查询继续返回持久记录；协调层在交付界面前装饰离线状态。
- “离线”筛选先查询当前可见记录，再使用运行时离线 ID 过滤。
- 侧栏离线数量来自运行时离线 ID，不增加数据库列或迁移。

## 自动恢复

`ApplicationCoordinator` 监听 `NSWorkspace.didMountNotification` 和 `NSWorkspace.didUnmountNotification`：

1. 重新解析已有 Bookmark，并在需要时重新建立安全范围访问。
2. 后台刷新可访问 URL 和离线视频集合。
3. 刷新当前网格、侧栏数量和检查器。
4. 卷重新可用时，对当前可访问来源启动现有静默维护和待处理媒体任务；其他仍离线来源不参与本轮扫描。
5. 当前筛选为“离线”且离线集合清空时，协调层切换到“全部视频”，界面同步选中状态和标题。

整个过程不进入导入状态区域，也不产生全局恢复消息。

## UI 映射

### Sidebar

- 在“最近添加”后按需插入“离线”系统分类。
- 使用系统外置磁盘不可用图标。
- 数量为零时节点不存在。

### Video Grid

- `VideoThumbnailView` 在图片和占位图上方增加 50% 黑色蒙层。
- “离线”标记位于蒙层上方。
- 卡片容器、文件名、时长、选择和悬停逻辑保持现有实现。
- 原文件相关菜单项沿用 `availability == .available` 的启用规则。

### Inspector

- “详细信息”在修改时间与路径之间增加“访问状态”。
- 离线值包含来源展示名称；无法取得名称时使用通用离线文案。
- 标签分段、标签搜索和草稿应用逻辑保持可用。

## 并发与性能

- 挂载卷枚举、文件存在性检查和 URL 组合在 `.utility` detached task 中执行。
- 静默维护只扫描当前已建立安全范围访问且来源根位置存在的来源；多个卷部分恢复时，各已恢复来源可独立核对移动、重命名、内容变化和真实删除。
- 数据库访问继续通过 `DatabaseStore` actor。
- 状态更新和 UI 回调回到 MainActor。
- 每次挂载状态变化合并为一个可取消任务，避免快速连续通知产生重复刷新。
- 不读取视频内容，不修改、移动、重命名或删除原视频。

## 明确排除

- Bookmark 或权限失败后的人工重新授权。
- 手动重新定位视频或来源。
- 来源管理、缓存设置、失败详情列表。
- 全局离线与恢复提示。
- 网络资料库可用性模型。
