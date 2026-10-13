# Beta 安装与首次使用

适用于 Apple Silicon（M1 或更新芯片），要求 macOS 14 或更新版本。本版在 macOS 26.2 开发验证，尚未在每个支持的系统版本上验收。

## 下载和打开

1. 由有仓库访问权限的 GitHub 账号登录，在 Release 的 Assets 中下载 `MeetingAssistant-v0.4.1-beta.1-arm64.zip`。不要选择 Source code，它是源码。
2. 解压，将「会议助手.app」拖入「应用程序」，以后固定从该位置启动。包内不包含任何人的 API Key 或会议数据。
3. 本测试版采用自签名，未通过 Apple 公证。首次打开可能提示无法验证开发者。如确认下载来源，尝试打开后，在「系统设置 → 隐私与安全性」找到对应提示，选择「仍要打开」，并按 macOS 提示确认。系统版本或设备管理策略可能不允许放行；遇到这种情况请联系维护者，不要关闭 Gatekeeper、SIP 或安装根证书。
4. 如需核对下载完整性，在终端运行 `shasum -a 256` 加 ZIP 文件路径，与 Release 的 `SHA256SUMS.txt` 对比。

首次放行说明参考 [Apple 官方指南](https://support.apple.com/zh-cn/102445)。

## 填写自己的 Key

打开 App 设置（⌘,），分别填写北京地域 ASR Key 和 LLM Key，点击「保存密钥到钥匙串」。两个服务允许使用同一把百炼 Key，但需分别填写。

默认配置：

- 实时 ASR：`fun-asr-realtime`，`wss://dashscope.aliyuncs.com/api-ws/v1/inference`
- 会后文件识别：`fun-asr`，`https://dashscope.aliyuncs.com/api/v1`
- 总结和问答：`qwen-plus`，`https://dashscope.aliyuncs.com/compatible-mode/v1`

Key 需要自行在百炼开通对应模型权限，调用费用由自己的账号承担。不要把 Key 发给维护者。钥匙串提示中的 `MeetingAssistantKeychain` 是包内读取组件；只有确认来自所下载 App 时才授权。系统要求的密码只在本机系统弹窗输入。

点击「测试已保存的 ASR 配置」可检查连接，测试静音不等于真实语音识别成功。

## 第一次会议

佩戴耳机，开始会议并允许麦克风、屏幕与系统音频录制。某些系统需要退出重开才能生效。说几句中文并播放一点系统声音，检查两路采集状态、转写和本地录音；静音时没有文本并不等于连接失败。

结束后默认上传单声道录音到百炼临时 OSS，进行说话人分离并生成纪要；可在设置关闭自动会后处理。实时音频、会后录音、原文和笔记会按功能发送到配置的服务，详见 CONFIGURATION.md。编号需人工核对，不支持跨会议自动认人。

Plaud 下载属于可选能力，依赖原本地第三方采集工具和 ffmpeg；首次安装无需配置它即可使用核心录音、转写、纪要、搜索和问答。

## 更新与卸载

先结束录音并等待后台任务完成，再退出 App，用同一发布渠道的新版本替换「应用程序」中的旧版本。不要同时运行多个副本。没有自动更新器，固定签名也不能保证所有 macOS 环境永不再次要求授权。

移除 App 不会自动删除 `~/Library/Application Support/MeetingAssistant/` 里的会议或钥匙串 Key。如需彻底清理，先备份资料，再自行删除对应会议目录及钥匙串中的 `local.MeetingAssistant` 项目。

## 测试版边界

本次已验证核心逻辑、优化构建与签名、打包解包完整性。开发机此前有真实音频和 API 分项验收；尚未在另一台无既有权限的 Mac 上完成首次放行、钥匙串保存和真实录音全流程。请先用非敏感的短会议试用，不将 Beta 作为唯一录音备份。
