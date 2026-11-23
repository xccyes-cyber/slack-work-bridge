# Slack Work Bridge

让人和 AI Agent 通过 Slack 给指定的本机 Codex 桌面对话派工。接收器在 Mac 或 Windows 上运行，按频道或标签把任务排入已有会话，保留项目上下文。Work 有 Slack 权限时，可以把结果回复到原线程。

**已实测的发送端**包括普通 ChatGPT Chat 和人工 Slack 发信。其他 Agent 可以使用同一路径，前提是它能以允许名单内的 Slack 用户身份发出真实的应用提及。独立机器人身份目前不接收。

## 快速上手

1. 用 [Slack App 模板](examples/slack-app.yaml) 创建应用，打开 Socket Mode，将应用加入专用私人频道，创建权限为 `connections:write` 的 app-level token。
2. 把 [示例配置](examples/bridge.example.json) 复制成 `bridge.json`。填入自己的 Slack 工作区、App、机器人用户和允许发送的用户 ID。把要接单的频道 ID 和本机 Codex 会话 ID 配进去。不要把令牌写入配置。
3. 安装 Node.js 22 或更新版本，以及能执行 `codex queue` 的 Codex CLI。Mac 通过 `install-mac.sh` 装到当前用户的 LaunchAgent，令牌存钥匙串。Windows 通过 `install-windows.ps1` 装到当前用户的任务计划，令牌输入后由系统加密保存。
4. 打开指定的本机桌面会话，在对应频道真实提及 `@Slack Work Bridge`，后面写任务。以目标窗口出现消息为准。需要回 Slack 时，请在任务里明确要求回复原线程。

[完整安装步骤](README.md)包含 Mac 和 Windows 命令、如何绑定窗口、如何更新与停用。桥接器负责转发任务。回 Slack 由目标会话的 Slack 工具发出。本机要保持开机并登录，当前版本不会补拉离线期间的频道历史。
