const RELOAD_MESSAGE_TYPE = "sms-code-bridge.reload-extension";

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== RELOAD_MESSAGE_TYPE) return false;

  if (sender.id !== chrome.runtime.id) {
    sendResponse({ ok: false, error: "拒绝非本扩展的重载请求" });
    return false;
  }

  sendResponse({ ok: true });
  // 先让响应返回内容脚本，再重载整个扩展，避免消息通道提前断开。
  setTimeout(() => chrome.runtime.reload(), 150);
  return false;
});
