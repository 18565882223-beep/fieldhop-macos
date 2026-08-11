# 贡献指南

感谢你参与 SmsCodeMenuBar。

## 提交问题

请提供 macOS 版本、项目版本、最小复现步骤、预期结果和实际结果。所有日志、截图和测试数据必须先脱敏；不要提交真实手机号、邮箱、密码、授权码、验证码、Cookie 或数据库。

## 提交代码

1. 从 `main` 创建功能分支。
2. 只修改解决当前问题所需的文件。
3. 为行为变化补充或更新测试。
4. 在提交 PR 前运行：

```bash
swift test
node --check ChromeExtension/content.js
node --check ChromeExtension/service-worker.js
```

涉及网页自动化时，还应运行：

```bash
node scripts/run_frontlink_mock.cjs
```

## 设计原则

- 默认本地处理和最小权限。
- 验证码、手机号和邮箱凭据不得出现在日志中。
- 自动操作必须有安全门禁和失败降级路径。
- 不实现 CAPTCHA、人机验证或访问控制绕过。
- 保持改动小而可验证，避免无关重构。

