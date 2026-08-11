# 短信验证码 DOM 桥 Chrome 扩展

这个扩展是混合方案的一部分：原生菜单栏 App 仍负责手机号、短信、验证码提取、热键、安全策略；扩展只在当前页面 DOM 内执行前半链路：

1. 填手机号
2. 勾选明确的必选协议（不会勾选营销、记住登录或第三方授权）
3. 优先点“获取/发送验证码”；找不到时才有限次点击“下一步/继续”并重新识别
4. 尝试聚焦验证码输入框；收到短信后的填码命令支持单框和多格 OTP

遇到图形码、滑块、点选文字等人机验证时，扩展只上报“需要人工介入”，不会尝试破解或绕过；登录表单位于 iframe 时同样降级为人工继续。

本地桥接地址固定为 `http://127.0.0.1:47873`。扩展不保存手机号，手机号只随单次命令从本机 App 传入。

## 本地 mock 套件

不需要安装或重新加载扩展，也不需要启动菜单栏 App。在项目根目录直接运行：

```bash
node scripts/run_frontlink_mock.cjs
```

跑手会启动临时本地服务和无头 Chrome，直接调用 `content.js` 暴露的本地测试 API。也可以手动
启动静态服务后观察测试页面：

```bash
python3 -m http.server 48731 --directory .
open http://127.0.0.1:48731/ChromeExtension/test-pages/frontlink-mock-suite.html
```

页面会自动运行 15 类前半链路 mock，并显示“全部通过”或具体失败原因。新增用例按真站结构
覆盖 Kimi 国家区号、秘塔 MUI 协议框、豆包异步“下一步”和百度“重新发送”协议态。
该套件只在 `localhost/127.0.0.1` 生效，不会发送真实短信或访问真实站点。

## 调试模式自重载

内容脚本版本 `frontlink-20260711-r4` 及以上支持从本机桥接服务接收
`reloadExtension` 命令。App 仅在 `SMS_CODE_CHROME_BRIDGE_DEBUG=1` 时开放：

```bash
curl -s -X POST http://127.0.0.1:47873/debug/reload-extension
```

命令会先向 App 上报成功结果，再通过内部消息让 Manifest V3 Service Worker 调用
`chrome.runtime.reload()`。首次加载扩展，或当前浏览器里仍是 `r3` 及更早版本时，仍需在 `chrome://extensions/`
手动重载一次，以便先装入自重载能力。

首次装入 r4 后，应刷新所有仍在运行旧内容脚本的普通网页；否则无目标的重载命令可能先被旧脚本
领取。旧页统一刷新后，现场已验证扩展可由调试命令从 r4 自动更新到 r5。
