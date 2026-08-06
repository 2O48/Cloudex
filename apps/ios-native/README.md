# Cloudex Native iOS

这是与 `apps/mobile` 完全独立的 SwiftUI 原生 iOS 客户端，不依赖 Expo、React Native 或第三方 Swift 包。

## 已实现

- 服务器地址与 Bearer Token 设置、持久化
- 读取电脑上的项目和 Codex CLI 对话
- 新建、继续、停止、归档对话
- 模型读取与选择
- SSE 实时任务状态和流式回复
- 错误信息同步显示
- 浏览并附加电脑端文件
- 打开对话后自动定位到最新记录

## 运行

1. 先在项目根目录运行 `./start-cloudex.sh`，确保本地服务器的 `8890` 端口可访问。
2. 用本机可用的 `Xcode-beta.app` 打开 `CloudexNative.xcodeproj`。
3. 选择模拟器或已签名的真机，运行 `CloudexNative` Scheme。
4. 在 App 右上角设置中填写：
   - 局域网：`http://电脑局域网IP:8890`
   - Tailscale：`http://电脑TailscaleIP:8890`
   - 启动脚本终端中显示的访问 Token

真机不能使用 `127.0.0.1` 访问电脑。项目已在 `Info.plist` 中声明本地网络用途并允许开发阶段的 HTTP 连接。

## 命令行编译检查

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild \
  -project CloudexNative.xcodeproj \
  -scheme CloudexNative \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```
