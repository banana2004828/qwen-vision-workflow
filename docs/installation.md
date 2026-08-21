# 安装、迁移与修复

## 前置条件

支持 Windows 10/11。发行包包含 Windows PowerShell 5.1 可用的控制脚本；安装 PowerShell 7 后可以用 `pwsh.exe` 获得更一致的自动化体验。Hermes 原生路径建议使用项目已验证的 v0.20.4 能力契约；版本不同并不自动等于兼容，安装器会读取能力并在不匹配时阻止写入。

可选 Qwen-MM API 层还需要 `uvx` 和能够访问其固定 Git 引用的网络。DeepSeek Harness 适配需要 Git、pnpm 以及 manifest 要求的外部挂载；没有这些依赖时仍可以使用 Hermes 主路径。

## 从 ZIP 开始

1. 把 `qwen-vision-workflow-1.0.0-windows.zip` 解压到一个普通本地目录。
2. 在解压目录运行 `安装千问视觉.cmd`，或在 PowerShell 中先执行只读诊断。
3. 确认诊断返回目标 Hermes 根、版本、配置能力和凭据“存在/缺失”状态后，再运行安装。
4. 从 `status` 读取收据路径；`installed` 只表示配置读回成功。
5. 需要真实图片证据时，准备一个无敏感信息的 PNG，使用 `verify -ConfirmPaidCalls -ImagePath ...`，并检查返回的 `target-accepted` 及 route evidence。

推荐的显式命令：

```powershell
$root = (Get-Location).Path
powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'qvw.ps1') -Action doctor -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'qvw.ps1') -Action install -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'qvw.ps1') -Action status -Json
```

## 凭据来源

不要在命令行或聊天窗口粘贴密钥。安装器按以下顺序查找 DashScope 凭据：活动进程、用户或机器环境；适配器明确支持的客户端凭据文件；只有交互模式明确允许时才使用隐藏输入。凭据属性只保留来源类别和短指纹，日志、JSON、收据和诊断中没有明文。

Hermes 配置使用现有安全 `.env`，并写入兼容的 DashScope base URL。安装器会备份配置、环境文件和 Hermes Skill，再分别写入三个视觉键，最后运行配置检查并读回主模型。主模型必须与写入前一致，否则整个事务自动回滚。

## DeepSeek Harness

在目标 Harness 根目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\qvw.ps1 -Action doctor -HarnessRoot <harness-root> -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\qvw.ps1 -Action install -HarnessRoot <harness-root> -Json
```

适配器只接受 manifest 中的精确 commit、受控文件 preimage 和外部挂载；发现未知 commit、受控文件脏改动、补丁行尾错误或缺少挂载时，会返回 `blocked`，保留目标目录不变。不要手动把补丁复制到未知版本。

## 可选 Qwen-MM

Qwen-MM 不是必须项。只有需要显式 OCR、grounding 或 vision chat 时才安装：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\qvw.ps1 -Action qwen-mm -NonInteractive -Json
```

安装器会锁定 `optional/qwen-mm/source-lock.json` 中的仓库 commit 和三个 Skill 文件哈希，备份目标 Skill/MCP 配置，并通过连接结果和工具数量判定安装状态。需要真实图片调用时再加 `-ConfirmPaidCalls -ImagePath <png>`；失败只回滚 Qwen-MM 可选层，不回滚已接受的 Hermes 原生路径。

## 修复与回滚

重复安装前先运行 `doctor` 和 `status`。每次写入都有收据：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\qvw.ps1 -Action rollback -Receipt <receipt-path> -Json
```

回滚必须返回 `verified` 或等价的已验证状态；`degraded`、`failed`、`unverified` 都需要保留收据并查看 [故障排查](troubleshooting.md)。不要删除备份目录来“清理”错误。
