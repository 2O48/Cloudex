# Mobile App

这是 Cloudex 的 Expo 手机端，目标平台为 iOS 和 Android。

```bash
npm install
npm run mobile
```

在真机上运行时，把首页的服务器地址改成电脑的 Tailscale 地址，例如 `http://100.x.y.z:8787`；如果服务器配置了 `AUTH_TOKEN`，同时在首页填写访问 Token。目前页面包含连接检查、任务列表、新建任务和归档；`src/filePicker.js` 已预留 iOS/Android 文件选择入口。
