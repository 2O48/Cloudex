<div align="center">

<img src="resources/icons/cloudex.png" alt="Cloudex logo" width="120" />

# Cloudex

[English](README.md) | 中文

</div>

从手机远程操控 Codex 的本地控制台：一台电脑上运行的轻量 HTTP/SSE 服务 + 原生 iOS 客户端 + 可通过 `npx` 分发的 CLI。你可以在手机上查看电脑里的 Codex 会话、新建和继续任务、实时看流式输出、审批命令执行，甚至浏览和审阅电脑上的代码。

## 它是什么

Cloudex 由两部分组成：

- **本地控制服务器**（`apps/server`）：包一层 Codex CLI，把任务控制、会话历史、文件浏览、审批等能力封装成手机端可消费的 HTTP/SSE API。全程使用 standalone Codex CLI，不依赖 Codex Desktop；Windows 上在 app-server 控制通道不可用时还会自动降级为直接驱动 Codex CLI 子进程。
- **原生 iOS 客户端**（`apps/ios-native`）：纯 SwiftUI 实现，不依赖 Expo / React Native / 第三方 Swift 包。通过局域网或 Tailscale 连接服务器，扫码即可完成配对。

手机的访问链路是 `Codex CLI ⇄ 本地服务器 ⇄ iOS App`。服务器只在本地运行，手机通过局域网或 Tailscale 访问它，所有对话历史仍留在电脑的 `~/.codex/sessions` 中。

## 核心功能

**任务控制**

- 新建、继续（steer）、停止、归档 Codex 任务
- 选择模型与推理强度（effort），支持任务 fork
- SSE 实时流式回复、任务状态与错误同步展示
- 命令执行审批：App 内/锁屏通知里直接允许、拒绝或“本次会话始终允许”

**手机端开发辅助**

- 浏览电脑文件树并附加图片/文件到对话
- 代码文件预览（覆盖常见语言与配置文件）
- Git 项目审阅：基于 diff 展示变更文件、增删行数、未跟踪文件
- 全量会话消息搜索，快速找回历史结论

**配对与安全**

- 启动时打印二维码（`cloudex://connect`，内含地址与 Token），App 扫码即连
- 非本机访问强制要求 `AUTH_TOKEN`；`FILE_ROOTS` 限定手机端可浏览的路径范围
- 连接历史保存在 App 本地，可切换自动 / 局域网 / Tailscale 三种模式

## 目录结构

```text
apps/
  server/           本地控制服务器 + cloudex CLI（可 npm pack 分发）
    src/             HTTP 服务器、Codex 客户端、CLI 会话解析、Windows CLI 回退
    bin/cloudex.js   CLI 入口（serve / pair / about / version / help）
  ios-native/        SwiftUI 原生 iOS 客户端（Xcode 工程）
packages/
  shared/           共享的 API 端点辅助（ENDPOINTS / URL 构造）
resources/
  config/           环境变量模板（server.env.example）
  icons/            图标源文件
  screenshots/      截图与产品参考图
  docs/             协议、部署与产品文档（规划中）
```

## 快速开始

要求：Node.js ≥ 22，standalone Codex CLI。

### 1. 启动服务器

```bash
# macOS / Linux
./start-cloudex.sh

# Windows PowerShell
.\start-cloudex.ps1
```

或者直接用 npm / CLI：

```bash
npm run server          # 或 npm start
npx cloudex serve       # 使用打包后的 cloudex 命令
```

服务器默认监听 `0.0.0.0:8890`。启动时会在终端打印手机端连接二维码和访问地址。

### 2. 使用 CLI

```bash
cloudex pair            # 打印配对二维码与服务器地址
cloudex about           # 查看本机环境、Codex CLI 与服务器状态
cloudex serve --port 8890   # 后台启动服务器
cloudex stop                 # 停止后台服务器
cloudex serve --foreground   # 前台启动，按 Ctrl+C 停止
cloudex --help
```

未设置 `AUTH_TOKEN` 时，`pair` / `serve` 会复用或生成 `.cloudex-state/auth-token`，与启动脚本行为一致。打包发布详见 `apps/server/README.md`。

### 3. 连接 iOS App

1. 运行 Xcode 打开 `apps/ios-native/CloudexNative.xcodeproj`，编译安装到模拟器或真机
2. 在 App 中扫描启动脚本打印的二维码，或手动填写服务器地址与 Token
3. 真机不能使用 `127.0.0.1`；局域网填 `http://电脑局域网IP:8890`，Tailscale 填 `http://电脑TailscaleIP:8890`

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PORT` | `8890` | 监听端口 |
| `HOST` | `0.0.0.0` | 监听地址 |
| `AUTH_TOKEN` | 自动生成 | API 访问 Bearer Token；非本机访问必填 |
| `CODEX_BIN` | 自动探测 | Codex CLI 可执行文件路径 |
| `FILE_ROOTS` | 当前目录 | 手机端可浏览的文件根路径（`;` 分隔） |
| `CLOUDEX_PUBLIC_URL` | 自动推断 | 二维码中固定展示的服务器地址 |
| `CLOUDEX_STATE_DIR` | `.cloudex-state` | Token、审批历史等状态目录 |

## API 概览

```text
GET  /api/health                     健康检查
GET  /api/models                     可用模型
GET  /api/projects                   按会话聚合的项目列表
GET  /api/threads?archived=false     会话列表
POST /api/threads                    新建会话并发送首条指令
GET  /api/threads/:id/stream         会话 SSE 实时流
POST /api/threads/:id/message        发送消息
POST /api/threads/:id/steer          继续/引导当前任务
POST /api/threads/:id/stop           停止当前任务
POST /api/threads/:id/fork           基于某轮对话分支新任务
POST /api/threads/:id/archive        归档会话
GET  /api/files?path=...             文件列表
GET  /api/file?path=...              文件内容（预览）
GET  /api/review?path=...            Git 变更审阅
GET  /api/search/messages?q=...      会话消息搜索
GET  /api/events                     SSE 全局事件
GET  /api/approvals                  待审批列表
POST /api/approvals/:id/respond      审批（允许/拒绝/会话允许）
```

启用了 `AUTH_TOKEN` 时，所有 `/api` 请求（包括 `/api/health`）都要求 `Authorization: Bearer <token>`（或查询参数 `?token=`）；未配置 Token 时仅本机回环地址可访问，默认 `HOST=0.0.0.0` 下服务器会拒绝启动。

## 安全模型

- 服务器监听非回环地址且未设置 `AUTH_TOKEN` 时会拒绝启动
- 配对二维码内嵌 Token，请勿外传
- `FILE_ROOTS` 限制手机端能浏览和选择的本地路径
- 手机访问推荐走 Tailscale，避免把服务直接暴露到公网
- 本地通知（审批、任务结果）由 iOS App 在设备上生成，不经过第三方推送通道

## 开发

```bash
npm install
npm test                # 运行服务器单元测试（node --test）
npm run server:dev      # 带 --watch 的服务器热重载
npm run cli -- --help   # 直接运行 CLI
npx cloudex serve        # 后台启动，可关闭当前终端
npx cloudex stop         # 停止后台服务器
npm run pack:server     # 生成 cloudex-<version>.tgz 供 npx 分发
```

iOS 端命令行编译检查（macOS）：

```bash
xcodebuild -project apps/ios-native/CloudexNative.xcodeproj \
  -scheme CloudexNative -sdk iphonesimulator -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

## 说明

- 会话历史默认读取 `~/.codex/sessions`（`cli-local` 模式），服务器离线也能提供历史数据
- ChatGPT 账号的 `remote-control` 云端配对是 Codex 的可选功能，**不是** Cloudex 的运行前提；Cloudex 的手机访问由局域网 / Tailscale + `AUTH_TOKEN` 保障
