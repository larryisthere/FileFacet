# 扫描新视频实施任务

- 状态：正式实现已通过用户验收（2026-08-30）
- 需求：[`scan-new-videos-requirements.md`](scan-new-videos-requirements.md)
- 设计：[`scan-new-videos-design.md`](scan-new-videos-design.md)
- 验收：[`scan-new-videos-acceptance.md`](scan-new-videos-acceptance.md)

## 需求与方案

- [x] 记录工具栏与“文件”菜单的双入口、无快捷键和统一启用状态。_Requirement: 3.1_
- [x] 明确文件夹扫描范围、单文件父目录恢复和部分失败语义。_Requirement: 3.2_
- [x] 明确会话级候选、全局判重、临时导航和关闭生命周期。_Requirement: 3.3, 3.4_
- [x] 明确部分/全部选择、搜索、导入与文件夹标签偏好。_Requirement: 3.5_
- [x] 生成并通过可操作 HTML 原型评审。_Requirement: 5.3–5.11_

## 正式实现

- [x] 增加 schema 13 扫描目录标记及来源清理保留规则。_Requirement: 3.2_
- [x] 增加数据库只读候选判重能力。_Requirement: 3.3_
- [x] 增加 Coordinator 扫描、追加目录、候选生命周期和所选导入流程。_Requirement: 3.2–3.6_
- [x] 增加临时侧栏分组、数量、选择和关闭动作。_Requirement: 3.4_
- [x] 增加候选网格、选择栏、搜索、访问提示与无候选状态。_Requirement: 3.4, 3.5_
- [x] 增加会话级 Quick Look 候选预览、复用取消、清理和失败回退。_Requirement: 3.3_
- [x] 增加 Inspector 只读候选上下文。_Requirement: 3.3, 3.5_
- [x] 接入工具栏与“文件”菜单双入口及统一状态。_Requirement: 3.1_
- [x] 增加全部候选成功后的自动关闭、会话级结果累计、最近添加/所有视频跳转及选中滚动。_Requirement: 3.4, 3.5_
- [x] 将追加扫描文件夹纳入 scan task/revision 取消边界，并在全部失败时保留原候选。_Requirement: 3.2, 3.6_
- [x] 阻止未检查或失败目录被误判为完整扫描，并在候选归零时继续显示范围未完成反馈。_Requirement: 3.2, 3.5_
- [x] 补齐英文、简体中文、Tooltip 和辅助功能文案。_Requirement: 3.1–3.5_
- [x] 同步当前 MVP 产品文档、双语 README 和原型。_Requirement: 3.1–3.6_
- [x] 正式实现验收后同步 Changelog。_Requirement: 3.1–3.6_

## 验证与交付

- [x] 执行 String Catalog JSON、原型 JavaScript、文档链接、资源引用和 `git diff --check` 文本级检查。
- [x] 用户通过 Xcode Run 完成编译、App 运行和核心扫描流程验收；代理未执行构建命令。_Requirement: 5.1–5.13_
- [ ] 执行自动化测试。当前轮未获得测试命令或测试源码变更授权。_Requirement: 5.1–5.13_
- [x] 用户在真实目录完成候选发现、Quick Look 预览、部分/全部导入、分类切换和完成导航验收。_Requirement: 5.1–5.13_
- [x] 用户明确确认扫描新视频正式实现验收完成，并授权提交已验收范围。
