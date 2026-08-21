# 故障排查

先保存机器可读结果中的 `status`、`code`、`component`、`stage` 和 `receiptPath`。不要把 `.env`、完整日志、Cookie、原始聊天或业务图片发给别人；诊断包已经只包含脱敏摘要。

## 通用处理

| 状态/错误码 | 含义 | 下一步 |
|---|---|---|
| `blocked` | 安全、版本、凭据、路径或付费闸门未满足，通常未写入 | 先按错误码修正前置条件，再重跑 `doctor`；不要覆盖目标目录 |
| `unverified` | 有响应但缺少关键边界证据 | 查看 `missingBoundaries`，补足只读探测或目标版本，不把它当通过 |
| `failed` | 命令或事务失败 | 查看收据和阶段；若已产生收据，先验证回滚，再决定是否重试 |
| `degraded` | 主路径可用，可选层不可用 | 继续使用 Hermes 原生路径；单独处理 Qwen-MM，不重复改主配置 |
| `QVW-ROUTER-INVALID-REQUEST` | action 或参数不能安全路由 | 仅使用 README 中列出的 action 和显式参数 |
| `QVW-ACTION-UNAVAILABLE` | 发行包缺少请求的入口 | 重新解压完整 ZIP，并核对 SHA-256 |

## Hermes

| 错误码 | 处理 |
|---|---|
| `QVW-H-CRED-REQUIRED`、`QVW-H-PREFLIGHT-BLOCKED` | 检查活动 Hermes 根、环境变量中的凭据存在性和能力探测；不要输出密钥 |
| `QVW-H-DOCTOR-BLOCKED`、`QVW-H-DOCTOR-ERROR` | 先运行 `qvw.ps1 -Action doctor -Json`，确认 `agent.image_input_mode`、`auxiliary.vision` 和 Alibaba provider；不要创建旧的 `tools.vision` |
| `QVW-H-INSTALL-ROLLED-BACK`、`QVW-H-ROLLBACK-FAILED` | 保留 receipt，运行 status 和指定 receipt 的 rollback；人工确认之前不要再次安装 |
| `QVW-H-MAIN-MODEL-UNKNOWN` | 主模型读回失败，安装/验收不成立；检查 Hermes CLI 可执行路径和配置权限 |
| `QVW-H-PAID-CONFIRMATION-REQUIRED` | 这是保护额度的正常阻断；只有明确愿意消耗配额时才加入 `-ConfirmPaidCalls` |
| `QVW-H-IMAGE-REQUIRED` | 提供可读取的本地 PNG；不要使用含业务隐私的图片作为排障附件 |
| `QVW-H-VERIFY-TIMEOUT`、`QVW-H-VERIFY-FAILED` | 检查网络、模型服务和超时；不要从窗口是否打开推断验收成功 |
| `QVW-H-ROUTE-EVIDENCE-MISSING` | 视觉响应可能返回，但 ACP route 或模型边界证据不完整；结果是 `unverified` |

## DeepSeek Harness

| 错误码 | 处理 |
|---|---|
| `QVW-D-COMPATIBILITY-BLOCKED`、`QVW-D-MANIFEST-INVALID` | 目标版本不是锁定版本或 manifest 无效；停止自动补丁，保留目录不变 |
| `QVW-D-REQUIRED-MOUNT-MISSING` | 检查 manifest 规定的外部 Cordis 挂载；适配器不会替你写外部挂载 |
| `QVW-D-PAYLOAD-MISSING`、`QVW-D-PAYLOAD-LINE-ENDINGS` | 重新取得发行包中的补丁并检查 LF；不要用编辑器自动改行尾 |
| `QVW-D-INSTALL-FAILED`、`QVW-D-ROLLBACK-FAILED` | 保存 receipt、Git status 和脱敏诊断；先确认受控文件是否恢复 |
| `QVW-D-EVIDENCE-INCOMPLETE`、`QVW-VERIFY-HARNESS-NOT-ACCEPTED` | 只表示没有真实完整父子边界证据；不等于 Harness 已经可以使用 |

## Qwen-MM

| 错误码 | 处理 |
|---|---|
| `QVW-QMM-CRED-REQUIRED` | 让安装器从活动安全来源读取凭据；不要用 `--env KEY=value` 传递 |
| `QVW-QMM-SOURCE-LOCK-INVALID`、`QVW-QMM-HASH-MISMATCH` | 固定来源被改动或下载内容不匹配；停止安装，检查网络和 source-lock |
| `QVW-QMM-UVX-MISSING`、`QVW-QMM-NETWORK-UNAVAILABLE`、`QVW-QMM-SOURCE-DOWNLOAD-FAILED` | 安装 `uvx` 或恢复到固定 commit 的网络；这不会影响 Hermes 原生路径 |
| `QVW-QMM-MCP-ADD-UNSUPPORTED`、`QVW-QMM-CONNECTION-FAILED` | 检查 Hermes MCP 能力、server name 和工具数量；失败时检查可选层收据 |
| `QVW-QMM-PAID-CONFIRMATION-REQUIRED` | 未加入明确确认时不会启动真实 API 调用 |
| `QVW-QMM-LIVE-ROLLBACK-DEGRADED`、`QVW-QMM-LIVE-ROLLBACK-FAILED` | 可选层回滚证据不完整；保留 receipt，手动确认 Skill/MCP 状态后再处理 |

## 包和诊断

| 错误码 | 处理 |
|---|---|
| `QVW-PACKAGE-SENSITIVE-DATA`、`QVW-PACKAGE-ZIP-SENSITIVE-DATA` | 发布包在压缩前或解压后二次扫描发现敏感内容；不发布 ZIP，检查 allowlist 或误加入的本机文件 |
| `QVW-PACKAGE-FAILED` | 查看 package 阶段和输出目录权限；不要删除已有正式 ZIP |
| `QVW-DIAG-SENSITIVE-DATA`、`QVW-DIAG-ZIP-SENSITIVE-DATA` | 诊断源或解压包不安全，输出不会发布；移除测试注入并重新导出 |
| `QVW-DIAG-OUTPUT-REQUIRED`、`QVW-DIAG-EXPORT-FAILED` | 提供可写的输出目录或修正权限；诊断不会读取原始客户端会话 |

## 仍无法解决时

运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\qvw.ps1 -Action diagnostics -OutputPath .\qwen-vision-diagnostics.zip -Json
```

只分享错误码、版本、状态和脱敏诊断 ZIP。若怀疑泄露，先撤销或轮换相关凭据，再把“发生时间、命令、错误码、是否已轮换”发给维护者；绝不要附上密钥本身。
