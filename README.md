# FileFacet

FileFacet 是一款 AppKit-first 的原生 macOS 本地文件标签管理器。当前版本专注于视频，未来可以扩展到更多文件类型。

用户可以从不同文件夹反复导入视频，或将多个视频、多个文件夹及混合内容直接拖入应用，在统一资料库中建立独立于 Finder 的层级标签索引。FileFacet 只读取原始视频，不会移动、重命名、修改或删除它们。

## 功能

- 层级标签、批量三态编辑、双向拖拽、合并、颜色和单步撤销
- 跨文件夹统一资料库、稳定文件身份判重和移动位置维护
- Finder 标签首次入库时单向导入
- 文件名搜索、父标签递归筛选、多标签 AND、未打标签与最近添加
- AVFoundation 媒体信息、缩略图、Quick Look、默认播放器和 Finder 定位
- 可选应用锁、隐私遮罩、闲置锁定和系统身份验证
- Security-Scoped Bookmark 只读访问与后台 FSEvents 维护

## 隐私

- 默认不发起网络请求
- 标签、文件索引、访问授权和缩略图保存在本机
- 不记录或上传完整文件路径、文件名、标签内容和 Bookmark 数据
- 原始视频始终保持只读

## 系统要求

- macOS 14 Sonoma 或更高版本
- Xcode 16 或兼容的更新版本
- Ruby 与 Bundler，仅在使用 Fastlane 发布流程时需要

## 构建

```bash
xcodebuild \
  -project VideoTagManager.xcodeproj \
  -scheme VideoTagManager \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

本地开发运行脚本为 `./script/build_and_run.sh`。脚本会构建、签名并启动应用，请先在 Xcode 中配置自己的开发签名。

## 项目结构

- `App/`：应用生命周期与窗口协调
- `Core/`：数据库、文件授权、扫描、媒体与安全服务
- `Features/`：资料库、设置与应用锁界面
- `Tests/`：核心模型和服务自动化测试
- `docs/product/`：当前需求与验收记录
- `docs/architecture/`：已接受的架构决策
- `docs/release.md`：本地、GitHub 与 App Store 发布流程

自动化检查只验证其中写明的断言。产品逻辑、交互和 UI 以用户验收结果为准。

## Release

版本历史见 [CHANGELOG.md](CHANGELOG.md)，正式发布见 [GitHub Releases](https://github.com/larryisthere/FileFacet/releases)。Release 页面提供经过 Developer ID 签名和 Apple 公证的 Universal App，以及 GitHub 自动生成的源码归档。

## License

FileFacet 使用 [MIT License](LICENSE)。

贡献说明与安全报告方式分别见 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [SECURITY.md](SECURITY.md)。
