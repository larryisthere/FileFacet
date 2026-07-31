# 离线资料库实施任务

- 状态：已完成，已授权发布
- 需求：[`offline-library-requirements.md`](offline-library-requirements.md)
- 设计：[`offline-library-design.md`](offline-library-design.md)

## 任务

- [x] 创建并确认与真实主界面一致的 HTML 交互原型。
- [x] 为运行时视频可用性增加离线状态，不改变数据库 schema。
- [x] 联合 Bookmark、已授权来源、视频位置和当前挂载卷计算离线状态。
- [x] 保证任一已授权位置可访问时视频保持可用。
- [x] 让离线筛选和数量使用运行时状态。
- [x] 增加条件显示的“离线”系统分类。
- [x] 增加缩略图 50% 黑色蒙层和“离线”标记。
- [x] 在检查器增加访问状态，并让离线路径显示不可用。
- [x] 监听本地卷挂载和卸载，重新解析 Bookmark 并自动恢复。
- [x] 离线筛选清空时自动返回“全部视频”。
- [x] 增加英文与简体中文文案。
- [x] 保持全局导入状态区域不参与离线与恢复反馈。
- [x] 执行 `git diff --check` 和 String Catalog 静态检查。
- [x] 执行 Debug 构建；本机签名证书缺失，关闭代码签名后的同目标构建成功。
- [x] 用户确认收尾，并授权提交、推送和正式发布当前实现。
- [x] 评估自动化测试范围；系统卷挂载和 Security-Scoped Bookmark 状态保留真实 macOS 验收，未新增固化运行时环境的模拟测试。
- [x] 同步正式 Changelog 和双语 README。
