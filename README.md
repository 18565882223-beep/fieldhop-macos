# SmsCodeMenuBar

一个开源的 macOS 菜单栏工具：从本机 Messages 数据库或用户配置的邮箱中识别一次性验证码（OTP），在安全条件满足时填入当前验证码输入框，否则复制到剪贴板作为兜底。

项目采用 Swift 5.9、AppKit、SQLite、Accessibility API，并提供一个可选的 Manifest V3 Chrome 扩展，用于网页手机号、协议和验证码输入框的 DOM 协作。

## 主要能力

- 从本机 `~/Library/Messages/chat.db` 读取最近的短信或 iMessage 验证码。
- 解析常见纯数字、字母数字混合及多种邮件 MIME/字符集验证码格式。
- 仅在验证码字段、有效时间窗和目标会话匹配时自动填入。
- 不满足自动填入条件时降级为临时剪贴板复制。
- 通过系统 Keychain 保存手机号和邮箱授权码；账号元数据与凭据分离。
- 可选 Chrome 扩展支持手机号填写、必要协议勾选、发送验证码和分格 OTP。
- 遇到图形验证码、滑块或其他人机验证时停止自动操作，由用户手动完成。

## 系统要求

- macOS 13 或更高版本
- Swift 5.9 或兼容版本
- 已在 Mac 的“信息”App 中启用短信转发或 iMessage 同步（短信来源）
- Google Chrome（仅在使用可选 DOM 桥时需要）

## 从源码构建

```bash
git clone <repository-url>
cd sms-code-autofill-macos
swift test
./scripts/package_app.sh
open ./短信验证码调试.app
```

首次运行需要根据功能授予以下权限：

- **完全磁盘访问**：只读访问本机 Messages 数据库。
- **辅助功能**：识别当前输入框并模拟键盘输入。

本地签名发生变化时，macOS 可能要求重新授予权限。正式分发建议使用 Apple Developer ID 签名与公证；当前脚本在找不到指定签名身份时使用临时签名。

## Chrome 扩展（可选）

1. 打开 `chrome://extensions`。
2. 开启“开发者模式”。
3. 选择“加载已解压的扩展程序”，加载 `ChromeExtension` 目录。

扩展只与本机 `127.0.0.1:47873` 桥接服务通信，不保存手机号或验证码。由于需要识别不同网站上的登录表单，扩展声明了广泛的页面访问权限；不需要网页自动化时，请不要安装扩展。

## 隐私与安全

- 项目不包含遥测、分析 SDK 或远程账号服务。
- Messages 数据库读取、验证码识别和自动填入在本机完成。
- 邮箱授权码保存在 macOS Keychain，不写入日志、UserDefaults 或源码。
- 邮件访问使用 TLS、只读邮箱命令和 `BODY.PEEK`，避免修改邮件已读状态。
- 日志应只包含脱敏邮箱、状态和掩码验证码。
- 本项目不会尝试破解或绕过 CAPTCHA、人机验证或站点风控。

这是安全敏感工具。使用前请阅读 [SECURITY.md](SECURITY.md)，并只在自己拥有或获准使用的账号与设备上运行。

## 测试

```bash
swift test
node --check ChromeExtension/content.js
node --check ChromeExtension/service-worker.js
```

本地前半链路 mock 需要 Playwright 和 Google Chrome：

```bash
node scripts/run_frontlink_mock.cjs
```

## 当前限制

- 真实短信端到端测试依赖用户本机权限、iPhone 短信转发和真实验证码场景。
- 不同邮箱服务商对 IMAP、授权码和安全策略的支持存在差异。
- Chrome 扩展使用开发者模式加载，尚未发布到 Chrome Web Store。
- 当前构建脚本主要面向源码用户，未提供经过公证的安装包。

## 参与贡献

欢迎提交可复现的问题、测试样例和小范围修复。提交前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

[MIT License](LICENSE)
