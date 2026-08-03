# Local Server

本地服务器通过 standalone Codex CLI 的 `app-server daemon` 和 `app-server proxy` 控制任务，并把任务通知转换成手机端可消费的 HTTP/SSE API。历史记录直接读取 `~/.codex/sessions`，整个运行过程不依赖 Codex Desktop。

启动前请确认 standalone Codex 已安装，并以 API Key 启动本地受管 daemon：

```bash
printenv OPENAI_API_KEY | ~/.codex/packages/standalone/current/codex login --with-api-key
~/.codex/packages/standalone/current/codex app-server daemon bootstrap
```

默认 control socket 是 `~/.codex/app-server-control/app-server-control.sock`；如有需要，可通过 `CODEX_CONTROL_SOCKET` 覆盖。

`remote-control` 是 ChatGPT 账号专用的云端配对功能，不是 Cloudex 的运行前提。Cloudex 的手机访问由 Tailscale 与 `AUTH_TOKEN` 保护。

## API

```text
GET  /api/health
GET  /api/models
GET  /api/threads?archived=false
GET  /api/files?path=/absolute/path
POST /api/threads
POST /api/threads/:id/message
POST /api/threads/:id/stop
POST /api/threads/:id/archive
GET  /api/threads/:id/stream
```

创建任务并发送初始指令：

```bash
curl -X POST http://127.0.0.1:8787/api/threads \
  -H 'content-type: application/json' \
  -d '{"cwd":"/Users/me/project","model":"gpt-5.6-luna","prompt":"只回复一句：连接成功"}'
```

继续任务：

```bash
curl -N 'http://127.0.0.1:8787/api/threads/THREAD_ID/stream'
curl -X POST http://127.0.0.1:8787/api/threads/THREAD_ID/message \
  -H 'content-type: application/json' \
  -d '{"message":"继续完成刚才的任务","effort":"low"}'
```

`files` 支持传入本地图片路径；普通文件路径会附加到消息，Codex 是否能读取取决于工作目录和沙箱权限。`FILE_ROOTS` 用于限制手机端能够浏览和选择的本地路径。
