# HuiNote · 会记

**认真听，把会议留成可追溯的记录。**

![HuiNote 功能示意](https://github.com/user-attachments/assets/ad4760ae-78c5-4c94-8d63-d9496f3baab1)

[下载 v0.1](https://github.com/roy501-luo/huinote/releases/tag/v0.1) · [安装指南](docs/INSTALL.md) · [反馈问题](https://github.com/roy501-luo/huinote/issues)

原生 macOS AI 会议助手，让录音、转写、笔记和总结留在同一个工作空间。

Apple Silicon · macOS 14+ · 自备百炼 Key

## 从听清楚，到记明白

- **边开会，边记录**：同时录制系统声音和麦克风，实时显示中文转写，随手补充笔记。
- **一边听，一边核对**：播放录音时高亮当前句子；手动滚动暂停跟随，一键回到当前进度。
- **选个模板，生成纪要**：整理总结、决策和行动项，自动更新会议标题；支持自定义模板和批量生成。
- **有疑问，直接问**：右侧展开本场问答，点击引用回到原文与时间点。
- **把会议找回来**：本地会议库、全文搜索、关键词高亮、Markdown 导出。
- **接续 Plaud 记录**：导入已有资料，或通过可选采集工具下载录音，再交给会记处理。

## 三步开始

1. [下载安装包](https://github.com/roy501-luo/huinote/releases/tag/v0.1)，将「会议助手.app」放入「应用程序」。
2. 打开设置，填写自己的百炼北京地域 ASR 和 LLM Key。
3. 戴上耳机，授权录音，开始第一场会议。

首次打开方式见 [安装指南](docs/INSTALL.md)。会议资料保存在本机，Key 保存在钥匙串；转写和总结调用你配置的云端服务，按服务商计费。

## 开发

SwiftUI · ScreenCaptureKit · AVAudioEngine · SQLite · Keychain

安装 Swift 6 工具链，按 [签名说明](signing/README.md) 配置固定签名身份后：

```sh
./scripts/build.sh
open dist/会议助手.app
./scripts/verify.sh
```

[工程结构](docs/ARCHITECTURE.md) · [开发与打包](docs/DEVELOPMENT.md) · [服务配置](docs/CONFIGURATION.md) · [验证与已知问题](docs/TESTING.md)
