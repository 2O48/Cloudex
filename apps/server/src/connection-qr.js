import os from "node:os";
import qrcode from "qrcode-terminal";

function usableIPv4Addresses() {
  const preferredInterfaces = ["en0", "en1", "eth0", "wlan0"];
  return Object.entries(os.networkInterfaces())
    .flatMap(([name, addresses]) => (addresses || []).map((address) => ({ name, ...address })))
    .filter((address) => address.family === "IPv4" && !address.internal && !address.address.startsWith("169.254."))
    .sort((left, right) => {
      const leftRank = preferredInterfaces.indexOf(left.name);
      const rightRank = preferredInterfaces.indexOf(right.name);
      return (leftRank < 0 ? preferredInterfaces.length : leftRank)
        - (rightRank < 0 ? preferredInterfaces.length : rightRank);
    })
    .map((address) => address.address);
}

export function connectionURL({ host, port, authToken }) {
  const explicitURL = (process.env.CLOUDEX_PUBLIC_URL || "").trim().replace(/\/$/, "");
  if (explicitURL) return explicitURL;

  const displayHost = host === "0.0.0.0" || host === "::"
    ? usableIPv4Addresses()[0]
    : host;
  if (!displayHost) return null;
  const bracketedHost = displayHost.includes(":") ? `[${displayHost}]` : displayHost;
  return `http://${bracketedHost}:${port}`;
}

export function printConnectionQRCode(options) {
  const serverURL = connectionURL(options);
  if (!serverURL) {
    console.warn("未找到可供手机访问的网络地址，已跳过连接二维码。可通过 CLOUDEX_PUBLIC_URL 手动指定。");
    return;
  }

  const payload = new URL("cloudex://connect");
  payload.searchParams.set("url", serverURL);
  if (options.authToken) payload.searchParams.set("token", options.authToken);

  console.log("\n使用 Cloudex App 扫描二维码即可自动连接：\n");
  qrcode.generate(payload.toString(), { small: true }, (code) => console.log(code));
  console.log(`服务器地址：${serverURL}`);
  console.log("二维码中已包含验证 Token，请勿将二维码分享给不受信任的人。\n");
}
