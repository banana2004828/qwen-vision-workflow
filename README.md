# 千问视觉工作流

这是一个面向 Windows 10/11 的可恢复、可验收的 Qwen 视觉路由安装包。它把 Hermes Agent 的图片理解交给 Qwen，同时保留 Hermes 原来的主文本模型；兼容的 DeepSeek Harness 可以使用经过版本门控的图片桥接。项目不需要 computer use，也不会把密钥写进命令行、日志、收据、Git 或 ZIP。

## 先做什么

解压发行 ZIP 后，可以直接双击：

- `安装千问视觉.cmd`：执行只读预检，然后安装或修复 Hermes 的视觉配置。
- `千问视觉管理.cmd`：进入状态、诊断、验证、回滚、可选 Qwen-MM 和打包操作。

这两个入口是 Windows-only 入口；它们使用系统 Windows PowerShell 5.1，并在需要时调用 PowerShell 7。也可以在 PowerShell 中显式运行 `qvw.ps1`，这样更适合自动化和读取 JSON。

## 支持边界

主路径是 Hermes 原生辅助视觉：`agent.image_input_mode=auto`、Alibaba provider、`qwen3.7-plus`。图片由视觉模型理解，最终文本仍由 Hermes 当前主模型回答；安装器不会改写主 `model`、聊天历史、账号和业务数据。

DeepSeek Harness 只接受 `adapters/deepseek-harness/manifest.json` 中记录的精确上游版本、干净的受控文件和已审计挂载。未知版本或受控文件有脏改动时会安全拒绝，不会覆盖本地文件。

Qwen-MM-Plugins 是可选增强层，固定在 `qwen-mm-plugins-api-v1.0.1`。它适合显式 OCR、grounding 和 vision chat，不是 Hermes 自动图片路由的替代品。Qwen-MM 可能需要联网下载 `uvx` 依赖，真实视觉调用可能消耗 DashScope 配额；只有显式加入 `-ConfirmPaidCalls` 才会启动真实付费验证。

## 常用命令

在解压后的项目目录运行：

```powershell
# 只读诊断
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\qvw.ps1 -Action doctor -Json

# 安装/修复（凭据从活动 Hermes 的安全来源读取）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\qvw.ps1 -Action install -Json

# 生成无付费的静态与配置验证；真实图片验证需要明确确认
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\qvw.ps1 -Action verify -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\qvw.ps1 -Action verify -ConfirmPaidCalls -Json

# 查看收据、导出脱敏诊断、回滚指定收据
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\qvw.ps1 -Action status -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\qvw.ps1 -Action diagnostics -OutputPath .\diagnostics.zip -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\qvw.ps1 -Action rollback -Receipt <receipt-path> -Json
```

`<receipt-path>` 是状态命令返回的当前收据路径，不要把密钥、Cookie 或原始聊天内容放进参数。安装、验证和回滚都有机器可读 JSON；退出码也有固定含义。

## 状态词

这些状态不是同义词：

- `discovered`：找到客户端或配置入口，但没有写入。
- `backed-up`：已创建受控备份，后续写入仍未完成。
- `installed`：配置写入并读回成功；不等于真实图片调用已验收。
- `tests-passed`：本地或模拟测试通过。
- `target-accepted`：目标客户端的真实边界证据通过，例如路由、模型边界和图片事实都可读回。
- `final-accepted`：总控对所有必需组件、发布扫描和验收证据都接受。
- `degraded`：主路径可用，但可选层失败或未安装。
- `unverified`：有结果但关键证据缺失，不能当作通过。
- `failed`：执行失败；先看错误码和收据，不要重复覆盖安装。
- `blocked`：安全闸门、版本、凭据、付费确认或目标状态不满足，通常没有执行写入。

“窗口打开”“提示词发送”“安装成功”都不代表 `target-accepted`。

## 凭据、费用和隐私

安装器优先使用活动进程/用户/机器环境和已支持的客户端安全凭据来源；不会猜测任意项目目录，也不会向屏幕输出密钥。配置写入前有收据和备份，`.env` 与可选 Qwen-MM 凭据配置会按当前用户权限收紧。诊断只导出脱敏状态、版本、错误码、哈希和收据摘要。

默认验证不调用付费 API。Hermes、DeepSeek Harness 或 Qwen-MM 的真实图片验证都必须显式确认，且仍受目标能力、网络、额度和模型服务可用性影响。项目不购买额度、不订阅服务、不上传业务图片到 GitHub。

## 测试和打包

开发者可以在仓库根目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1
pwsh.exe -NoProfile -File .\tests\run.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\package.ps1 -Version 1.0.0 -OutputDirectory .\dist
```

打包器只使用显式 allowlist，拒绝 reparse point，固定 ZIP entry 时间，并在压缩前和解压后各运行一次脱敏扫描。输出为 `qwen-vision-workflow-1.0.0-windows.zip` 及同名 `.sha256` 文件。ZIP 不包含 `.env`、`.git`、备份、sessions、日志、历史计划、任务报告或本机路径。

## 进一步阅读

- [安装与迁移](docs/installation.md)
- [故障排查](docs/troubleshooting.md)
- [安全边界](docs/security.md)
- [发布与复现](docs/release.md)
- [第三方声明](THIRD_PARTY_NOTICES.md)

本项目是 Windows 控制平面，不是 Hermes、DeepSeek Harness、DashScope 或 Qwen-MM 的官方发行版；具体客户端许可和服务条款仍以各自上游为准。
