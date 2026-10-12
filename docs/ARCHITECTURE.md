# 工程结构与数据流

## 目录

| 路径 | 职责 |
| --- | --- |
| `Sources/MeetingAssistant/App.swift` | 主窗口、设置、转写和会后处理界面 |
| `Model.swift` | 会议生命周期、后台处理协调、批量任务 |
| `Audio.swift`、`PCM.swift` | 音频采集、落盘、重采样与发送队列 |
| `ASR.swift` | DashScope WebSocket 任务与结果状态 |
| `MeetingMix.swift`、`PostMeeting.swift` | 时间对齐混音、临时上传、文件识别、纪要 |
| `Storage.swift`、`BatchJob.swift` | SQLite、全文索引、批量任务检查点 |
| `MeetingQA.swift` | 单场问答、证据校验与引用 |
| `Playback.swift`、`PlaybackTimeline.swift` | 播放、当前句与时间定位 |
| `TranscriptScrollObserver.swift` | 用户滚动检测与暂停跟随 |
| `MeetingLibraryView.swift`、`SearchHighlight.swift` | 会议库、选择与搜索高亮 |
| `SummaryDocument.swift` | 文档式纪要阅读 |
| `Plaud.swift`、`Resources/plaud_download.py` | 本地资料导入与外部下载桥接 |
| `Sources/CSQLite/` | 系统 SQLite 模块 |
| `KeychainHelper/` | 验证调用方身份后访问指定钥匙串项目 |
| `Verification/`、`Tests/` | 核心验证与测试源码 |

表中未加前缀的 Swift 文件均位于 `Sources/MeetingAssistant/`。

## 录音与会后处理

1. 系统音频和麦克风各自写本地 CAF，同时转换为 16 kHz 单声道 PCM16，分别发送至实时 ASR。
2. WebSocket 按启动任务、等待启动成功、发送音频、结束任务、等待尾部结果推进。临时句原位更新，最终句去重；不可恢复缺失明确记录。
3. 停止后依据分段偏移生成单声道混音，经百炼临时上传提交文件识别。实时稿与最终说话人稿独立保存。
4. LLM 读取最终稿和笔记，分段处理长文本、校验引用并保存纪要与标题。失败保留已有内容。

双路独立转写便于区分采集状态并避免实时混音掩盖故障，但会产生两条 ASR 任务的费用。音源标签不是说话人身份。

## 持久化与任务恢复

会议和搜索索引在同一 SQLite 事务更新。短中文查询使用兼容匹配，较长文本使用 FTS5 trigram。查询作为字面文本，不执行用户输入的 FTS 表达式。

`batch-job.json` 原子保存模板、待处理、完成和失败项目。每次提交会议结果同时保存任务 ID，恢复时避免重复提交已完成会议。检查点粒度为整场会议，当前会议中断后可能重新调用其分段 API。原纪要在本地 `SummaryBackups/` 备份，不上传仓库。

问答只读取本场原文和笔记，不将生成纪要作为事实来源。引用验证包括 ID 与逐字原文匹配，但模型是否正确理解问题仍需人工核对。
