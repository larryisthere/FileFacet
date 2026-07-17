# 发布流程

本项目使用 Fastlane 统一读取 Xcode Release Build Settings 中的版本、构建号、Bundle ID 和 Team 配置，并按用途生成三类 Release。所有产物写入 `.build/releases/<版本>-<构建号>/`，该目录不会进入 Git。

## 环境准备

```bash
bundle install
```

Xcode 当前配置：

- Team：`Q554G4S79A`
- Bundle ID：`com.larryisthere.video-tag-manager`
- 版本：由 Xcode 的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION` 统一提供
- App Sandbox、用户所选文件只读权限、App-scoped Bookmark 和 Hardened Runtime 保持启用

## 准备正式版本

每个正式发布周期先在干净工作区执行一次：

```bash
bundle exec fastlane mac prepare_release version:1.0.2
```

该 lane 会将 `MARKETING_VERSION` 更新为指定版本，并将 `CURRENT_PROJECT_VERSION` 递增一次，同时同步 Xcode 工程和工程生成脚本。随后更新 `CHANGELOG.md`、完成验收并提交版本改动。GitHub 与 App Store 发布同一版本时共用这个 Build 号；`local_release` 不消耗 Build 号。

账号、API Key、GitHub Token 和公证凭证只保存在本机钥匙串或环境变量中，禁止写入仓库。

## 本地 Release

```bash
bundle exec fastlane mac local_release
```

该 lane 使用 Xcode Automatic Signing 和已配置的 Team，构建 `arm64 + x86_64` Universal App，随后校验版本、构建号、架构、Team、Sandbox、Hardened Runtime 与代码签名，并生成 ZIP 和 SHA-256 文件。

本地 lane 允许 Apple Development 签名，适合当前已配置开发证书的 Mac 使用。Gatekeeper 公开分发、公证和其他用户安装需要下方的 GitHub Release 流程。

## GitHub Release

### 一次性准备

1. 在 Apple Developer 后台创建并安装 `Developer ID Application` 证书。
2. 将 App ID 和所需能力配置完整，让 Xcode 可以取得 Developer ID provisioning profile。
3. 创建 App Store Connect API Key，并保存到本机。
4. 将公证凭证存入钥匙串：

```bash
xcrun notarytool store-credentials "FileFacet-Notary" \
  --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --key "$APP_STORE_CONNECT_KEY_PATH"
```

5. 使用 `gh auth login` 登录 GitHub，并为仓库配置 remote 或明确提供仓库名。

### 发布

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
export NOTARYTOOL_KEYCHAIN_PROFILE="FileFacet-Notary"
export GITHUB_REPOSITORY="owner/repository"
bundle exec fastlane mac github_release
```

该 lane 只允许从无未提交改动且当前提交已存在于目标 GitHub 仓库的工作区发布。流程使用 Manual signing 指定 Developer ID Application 身份，关闭开发调试 entitlement 注入并加入可信时间戳，然后执行签名检查、Release 构建、公证、stapling、ZIP 与 SHA-256 生成，从 `CHANGELOG.md` 提取目标版本区块，并创建明确指向当前提交的 `v<版本>` GitHub Release。需要覆盖 tag 时可设置 `RELEASE_TAG`。

如果当前机器尚未配置 `Developer ID Application` 与公证凭证，可以先在 GitHub 创建仅包含发布说明和源码归档的 Release。开发签名的本地 App 不应作为公开安装包上传。

## Mac App Store

### 一次性准备

1. 在 App Store Connect 创建与 Bundle ID 对应的 macOS App。
2. 确认 Apple Distribution 证书和 Mac App Store provisioning profile 可用。
3. 创建具备上传权限的 App Store Connect API Key。

### 上传构建

```bash
export APP_STORE_CONNECT_KEY_ID="..."
export APP_STORE_CONNECT_ISSUER_ID="..."
export APP_STORE_CONNECT_KEY_PATH="/absolute/path/AuthKey_XXXX.p8"
bundle exec fastlane mac app_store_release
```

该 lane 只允许从无未提交改动的工作区发布，生成 App Store Connect `.pkg` 并上传构建，不会自动提交审核，也不会修改商店文案或截图。

## 发布前检查

- `CHANGELOG.md` 已包含目标版本的用户可感知变化。
- Xcode 中的版本与构建号已递增，App Store 构建号未被使用过。
- 本地 Release 已生成并保存 SHA-256。
- GitHub 包通过 `codesign`、`notarytool` 和 `stapler` 校验。
- App Store Connect 构建处理完成后，再在后台选择版本并提交审核。
- 正式发布前按 `docs/product/mvp-acceptance.md` 完成目标 Mac 上的设备与交互验收。
