# 固定本机签名与钥匙串

日常更新必须复用固定签名身份、Bundle ID `local.MeetingAssistant` 和安装路径。临时 ad-hoc 签名会随代码改变，可能导致重复录音授权。

## 新电脑首次配置

1. 打开 macOS「钥匙串访问」，使用「证书助理 → 创建证书」。
2. 创建自签名根证书，证书类型选择「代码签名」，例如命名为 `MeetingAssistant Local Signing`；私钥保留在本机登录钥匙串，不导出至仓库。
3. 查看证书详细信息，复制 SHA-1 指纹（40 位十六进制，去掉空格）到项目 `signing/identity.txt`，或通过 `MEETING_SIGN_IDENTITY` 指定。该文件已被 Git 忽略。
4. 运行 `./scripts/build.sh`。新建的 helper 会绑定这个指纹。首次使用按系统提示授权；若确认组件来自自己的构建，可在本机钥匙串弹窗选择“始终允许”。

自签名只用于个人本机开发；不要求关闭 Gatekeeper、SIP 或清空 TCC，也不要为其添加 SSL 信任。对外发行应使用 Developer ID 并公证。不同系统的证书助理界面可能不同。

## 保持组件稳定

`signing/keychain-helper/MeetingAssistantKeychain` 及其 stamp 是本机缓存，不含 Key，也不上传 Git。主程序更新复用同一组件，只有组件源码或身份变化才重新编译。不要日常清理这个目录，否则钥匙串可能重新要求授权。

组件检查父进程标识与固定签名证书，只访问 `local.MeetingAssistant` 服务的 `asr`、`llm` 两项。Key 经过匿名管道，不放入命令行参数或文件。设置中的授权检查不显示密钥。

`KeychainHelper/main.swift` 的默认公开证书指纹用于已有开发机兼容；新身份构建时脚本生成本地替换版本。公开指纹不包含私钥，也不允许其他人伪造签名。

换电脑、换证书、修改组件、移动安装路径或锁定钥匙串后，可能仍需系统授权。不要上传 p12、私钥、密码或完整钥匙串。
