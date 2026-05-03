# Privacy Policy / 隐私政策

**Last updated: 2026-04-11**

## English

Open Island ("the App") is a companion app for AI coding agents. We are committed to protecting your privacy.

### Data Collection

The App does **not** collect, store, or transmit any personal data to external servers.

### How It Works

- The App communicates exclusively over your **local network** (LAN) between your Mac, iPhone, and Apple Watch.
- All data (agent session events, permission requests, notifications) stays on your devices and never leaves your local network.
- No analytics, telemetry, or crash reporting services are used.
- No third-party SDKs or tracking frameworks are included.

### Optional: Realtime Claude Web Usage (off by default)

You can opt into a feature in Settings → Setup → "Realtime Web Usage" that periodically requests your account-level Claude usage from `https://claude.ai/api/organizations/<org-id>/usage`. When enabled:

- Open Island sends an HTTPS GET request to claude.ai every 5 minutes carrying a session cookie that **you provide manually** by pasting it from your own browser.
- The cookie is stored in your macOS Keychain (item: "Open Island — Claude Web Session", `kSecClassInternetPassword`, `AfterFirstUnlockThisDeviceOnly`) and never transmitted anywhere except to claude.ai.
- The response is written verbatim to a local file the rest of the app already reads (`/tmp/open-island-rl.json`); nothing leaves your machine.
- Disable the toggle or click "Clear" to stop sending requests and remove the cookie from Keychain.

### Local Storage

The App stores minimal preferences (e.g., notification settings, pairing token) in on-device UserDefaults. This data is never transmitted externally.

### Contact

If you have any questions about this privacy policy, please open an issue at:
https://github.com/Octane0411/open-vibe-island/issues

---

## 中文

Open Island（"本应用"）是一款 AI 编程助手的配套应用。我们致力于保护您的隐私。

### 数据收集

本应用**不会**收集、存储或向外部服务器传输任何个人数据。

### 工作原理

- 本应用仅通过**本地局域网**（LAN）在您的 Mac、iPhone 和 Apple Watch 之间通信。
- 所有数据（代理会话事件、权限请求、通知）均保留在您的设备上，不会离开本地网络。
- 不使用任何分析、遥测或崩溃报告服务。
- 不包含任何第三方 SDK 或追踪框架。

### 可选功能：实时 Claude Web 用量（默认关闭）

可在 设置 → Setup → "Realtime Web Usage" 中启用。启用后：

- Open Island 每 5 分钟向 `https://claude.ai/api/organizations/<org-id>/usage` 发送一次 HTTPS GET 请求，携带**您自己手动从浏览器复制粘贴**的 session cookie。
- Cookie 存储在 macOS Keychain（项目名 "Open Island — Claude Web Session"，`kSecClassInternetPassword`，`AfterFirstUnlockThisDeviceOnly`），仅在向 claude.ai 发请求时使用，不会传输到其他任何地方。
- 响应原样写入本地文件 `/tmp/open-island-rl.json`，应用其它部分本来就在读这个文件；数据不会离开您的设备。
- 关闭开关或点击 "Clear" 即可停止请求并从 Keychain 移除 cookie。

### 本地存储

本应用在设备的 UserDefaults 中存储少量偏好设置（如通知设置、配对令牌）。这些数据不会被传输到外部。

### 联系方式

如果您对本隐私政策有任何疑问，请在以下地址提交 issue：
https://github.com/Octane0411/open-vibe-island/issues
