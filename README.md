# Slack Work Bridge

[中文说明](README.zh-CN.md)

Send tasks from **people and AI agents** in Slack to specific local Codex desktop conversations. Each Slack channel can point to a different project window. The existing conversation keeps its context and can reply in the original Slack thread when its Slack tools and permissions allow.

```text
Person or AI agent → Slack app mention → local bridge → codex queue → existing desktop conversation
```

The bridge uses Slack Socket Mode and the official [`codex queue` command](https://learn.chatgpt.com/docs/developer-commands#codex-queue). Your computer makes the outbound connection. There is no public webhook to host. The bridge queues work locally; the Codex model can still run remotely.

## Requirements

- Node.js 22 or newer, and a Codex CLI that shows help for `codex queue --help`.
- A Mac or Windows user session running the desktop app and a supported local Codex conversation. This bridge targets existing local Codex sessions; a ChatGPT cloud conversation is outside its scope.
- A Slack workspace where you can install a custom app, and a private channel for each project.
- The Slack sender must post a real app mention as a Slack user in the allowlist. Ordinary ChatGPT Chat and manual Slack posting were exercised. Other agents can use the same input if they can post as an allowed Slack user; specific integrations have not been certified. Independent bot messages are ignored.

## 1. Set up Slack

1. Create a Slack app from [the included manifest](examples/slack-app.yaml). Install it, and add it to each intended private channel.
2. Confirm Socket Mode and Event Subscriptions are on, with the bot event `app_mention`.
3. In the app settings, create an app-level token with `connections:write`. It begins with `xapp-`. Supply it through the OS credential store in step 3.
4. Identify the workspace ID (`T…`), app ID (`A…`), bot user ID (`U…`), each channel ID (`C…` or `G…`), and the Slack user IDs permitted to send tasks. The [Slack ID guide](https://slack.com/help/articles/221769328-Locate-your-Slack-URL-or-ID) explains how to locate the workspace ID; a channel's details shows its ID and a user's Slack profile menu can copy their member ID. Use the App's bot user ID for `bot`, not the App ID.

Slack may distribute events between connections using the same app. If Mac and Windows should both receive independently, give each machine its own Slack app and @-mention the one you want.

## 2. Bind channels to existing local conversations

Copy [`examples/bridge.example.json`](examples/bridge.example.json) to `bridge.json` and replace the placeholders. Keep this file private.

- `routes` maps a label such as `studio` to an existing local Codex session UUID.
- `channelRoutes` maps a Slack channel ID to that label. For dedicated channels, send `@Slack Work Bridge Review the draft`; the channel alone selects the conversation.
- For one shared channel, use the optional `channel` field and omit that channel from `channelRoutes`. Send `@Slack Work Bridge [studio] Review the draft`.
- `senders` lists the Slack user IDs allowed to submit tasks. Anyone or any agent authorized to post as one of those identities can submit a task. A label conflicting with a dedicated channel is rejected.

If you have a window title but need its UUID, the included helpers bind an exact title from the current user's local Codex index. In the example, remove the placeholder `routes` entry if using a label other than `studio`. The helper requires exactly one matching local session; other titles fail closed.

**Mac**

```sh
node bind-mac-route.mjs bridge.json studio 'Exact local conversation title'
```

**Windows**, from the release folder in PowerShell

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\bind-windows-route.ps1 -ConfigPath .\bridge.json -Label studio -Title "Exact local conversation title"
```

## 3. Install for the signed-in user

### Mac

Set the `credential.account` in `bridge.json` to your Mac username. In Keychain Access, create a password item in your login keychain. Use the configured service as its name, your Mac username as its account, and the `xapp-` token as its password. Set `codex` to the full path to the CLI executable. Use `command -v codex` to find it if available in Terminal.

```sh
bash ./install-mac.sh "$PWD/bridge.json"
```

The installer uses a LaunchAgent to start in your login session. Read the last known status at `~/Library/Application Support/SlackWorkBridge/status.json`. To stop the job, run `launchctl bootout "gui/$(id -u)/local.slack-work-bridge"`. To disable it for future logins, run `launchctl disable "gui/$(id -u)/local.slack-work-bridge"` and stop it if running.

### Windows

Install the [Codex CLI](https://learn.chatgpt.com/docs/enterprise/windows-deployment#deploy-codex-cli-on-windows) if necessary. For bundled desktop installations, pass the actual CLI executable, which can be under the app's `resources` directory. Check that `codex.exe queue --help` prints terminal help before using it. Use the real path in the command below, or omit `-CodexPath` if `codex.exe` is on your PowerShell PATH.

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\install-windows.ps1 -ConfigPath .\bridge.json -CodexPath "C:\path\to\codex.exe"
```

Paste the app token into the hidden terminal prompt. The installer saves it using Windows DPAPI for the current user and starts a scheduled task named `SlackWorkBridge`. The task starts when that user logs in. Inspect its status with:

```powershell
Get-ScheduledTask -TaskName SlackWorkBridge | Select-Object State
```

Read the latest bridge event at `%LOCALAPPDATA%\SlackWorkBridge\status.json`. An initial `connected` event means the Slack socket is ready. Use `Stop-ScheduledTask -TaskName SlackWorkBridge` to stop it, or also `Disable-ScheduledTask -TaskName SlackWorkBridge` to prevent future starts. The included Windows update script updates the running installation without replacing the saved config or credential.

## 4. Check real delivery

Open the intended local conversation. Send an actual Slack mention with a harmless task. Confirm that the task appears in that conversation; a `queued` event only means Codex accepted the queue operation. For a reply in Slack, explicitly request it in the task and confirm it appears beneath the original message. The bridge forwards source channel and thread IDs; the destination conversation posts any authorized reply using its own Slack tools. The bridge itself does not post replies.

Routes can be changed in the installed config without restarting. For Windows, `set-windows-channel-route.ps1` adds a channel mapping, and `bind-windows-route.ps1` adds a conversation label. Change app identity, permitted senders, or credentials by restarting the service.

## Boundaries

- The computer and signed-in user session need to be available. Reconnects are automatic. The bridge does not backfill Slack channel history while a machine is off.
- A local journal suppresses duplicate events. An uncertain queue operation is marked for review instead of automatically replayed.
- Only configure private channels, users and target conversations you trust. User permissions and approval rules in the destination conversation still determine what it can do.
- The local journal can contain task bodies. Keep OS credential files, configs, journal files and private Slack content out of Git.

MIT licensed. An independent community project using Slack and Codex.
