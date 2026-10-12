# 服务配置与隐私

## 百炼北京地域

在 App 设置中输入，不在配置文件存放 Key：

| 项目 | 默认值 |
| --- | --- |
| 实时 ASR Endpoint | `wss://dashscope.aliyuncs.com/api-ws/v1/inference` |
| 实时 ASR Model | `fun-asr-realtime` |
| 文件识别 Base URL | `https://dashscope.aliyuncs.com/api/v1` |
| 文件识别 Model | `fun-asr` |
| LLM Base URL | `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| LLM Model | `qwen-plus` |

ASR 和 LLM 使用独立钥匙串项，允许填写相同 Key。Key 必须与服务地域、模型权限匹配。Fun-ASR WebSocket 不是 OpenAI `/audio/transcriptions`，不能仅替换模型名称接入 Qwen-ASR。

会后识别使用单声道音频并开启说话人分离。编号可手动改名，但重新识别的编号不保证对应原来的人。

## 临时文件上传

使用百炼提供的临时 OSS 上传凭据，不要求自行创建公开 bucket。按接入协议，临时文件与账号和模型绑定，48 小时自动清理；当前实现没有提前删除远端文件入口。请在正式使用前复核服务商条款、额度和保留策略。大文件上传可能占用数百 MB 内存，本版按个人串行处理设计。

参考协议：

- [临时文件 URL](https://help.aliyun.com/zh/model-studio/get-temporary-file-url)
- [Fun-ASR 文件识别](https://help.aliyun.com/zh/model-studio/fun-asr-recorded-speech-recognition-http-api)
- [OpenAI 兼容 Chat Completions](https://help.aliyun.com/zh/model-studio/qwen-api-via-openai-chat-completions)

这些链接用于查阅；服务规格和价格应以调用时的官方说明为准。

## 本地数据

`~/Library/Application Support/MeetingAssistant/` 保存数据库、录音、任务状态和备份。备份这个目录即可保留会议资料；钥匙串需独立迁移。原始录音和会后派生混音分开保存。删除会议属于实际数据删除，请先导出需要保留的内容。

不记录 API Key、临时上传凭据或签名 URL。报告问题时不要上传个人数据库、录音、导出纪要或完整运行目录。

## Plaud（可选）

本仓库包含下载桥接脚本，不包含第三方 Plaud 采集器或其登录态。没有该工具也能正常使用录音、转写、纪要和会议库。

下载模式要求设置中指定既有采集工具目录，该目录包含 `.venv/bin/python`，且提供 `plaud_notes.config.get_settings`、`plaud_notes.collector.build_collector`、`plaud_notes.cli.cmd_login` 接口；另外需安装 `ffmpeg`。当前桥接面向原个人工具，未承诺适配所有第三方 Plaud 项目。登录由该工具管理，后续识别和总结由会议助手执行。

也可直接导入本地目录，每场会议一个子目录，至少包含 `meta.json` 和可用录音或 `summary.md`：

```json
{"plaud_file":{"id":"example-recording-id","name":"示例会议","created_at":"2026-10-12 09:00:00"}}
```

日期按北京时间解释；支持录音文件名 `audio.mono.mp3`、`audio.mp3`、`audio.wav`、`audio.m4a`、`audio.caf`。可选 `asr.json` 使用 `transcripts[].sentences[]`，句子字段为 `text`、`begin_time`、`end_time`（毫秒）、可选 `speaker_id`。资料缺少原文时不能仅依据旧纪要做问答。

按 `plaud_file.id` 去重，重复导入保留本地编辑。原目录保留；同步并不是双向云同步。
