# 开发与打包

使用 Swift Package Manager，系统框架和系统 SQLite，无第三方 Swift 包。`Package.swift` 声明 macOS 14、Swift 6 工具链，业务源码按 Swift 5 语言模式编译。

```sh
./scripts/verify.sh
./scripts/build.sh
open dist/会议助手.app
```

`build.sh` 先校验并复用固定钥匙串组件，编译主程序，在临时目录组装并验证签名，最后复制到 `dist/会议助手.app`。默认使用 debug 构建；`MEETING_BUILD_CONFIGURATION=release` 使用优化构建，尚未提供公证发行流程。完整 Xcode 可运行 `swift test`；仅有 Command Line Tools 时优先使用验证脚本。

环境变量：

- `MEETING_SIGN_IDENTITY`：固定证书的 40 位 SHA-1 指纹，优先于本地 `signing/identity.txt`。
- `MEETING_APP_OUTPUT`：构建输出路径；日用更新不要随意变更路径。
- `ALLOW_ADHOC_SIGNING=1`：仅用于隔离编译检查。临时签名不满足钥匙串组件的固定证书要求，不能作为完整功能验收版本，也不要覆盖日用 App。

不同电脑首次编译会将新证书指纹写入忽略的生成源码并构建对应 helper；不会提交本地证书。已有同源同身份的 helper 缓存保持不变。签名校验失败时先检查证书、钥匙串锁定及构建环境访问权限，不要通过清空系统隐私授权解决。

## 提交范围

只提交源码、资源、测试代码、脚本和通用文档。`.gitignore` 排除构建产物、证书配置、helper 缓存、个人验收数据和本地历史记录。不要使用 `git add -f` 绕过这些规则。

打包源码：

```sh
git archive --format=zip --prefix=meeting-assistant-macos/ -o dist/meeting-assistant-macos-source.zip HEAD
```

源码 ZIP 不包含签名身份、Key、会议库或可运行二进制。公开发行安装包需要独立配置 Developer ID 签名和 Apple 公证；目前没有设置自动发布或自动更新。

## Beta 发布包

运行 `./scripts/package-beta.sh` 生成独立优化构建的 ZIP 和 SHA-256 校验文件，不替换日用 App。版本发布使用 Git 标签及 GitHub Pre-release；包内只有签名 App 和通用安装文档。发布前核验源码提交、架构、签名、解包和排除敏感数据。
