# 发布与复现清单

## 本地发布门槛

发布前在干净工作树执行以下命令。两个 PowerShell 版本都必须完成；看到窗口、收到模型回复或生成 ZIP 都不能替代测试和安全扫描。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1
pwsh.exe -NoProfile -File .\tests\run.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\package.ps1 -Version 1.0.0 -OutputDirectory .\dist
Get-FileHash .\dist\qwen-vision-workflow-1.0.0-windows.zip -Algorithm SHA256
Get-Content .\dist\qwen-vision-workflow-1.0.0-windows.zip.sha256
```

预期结果：两套测试没有失败，package 返回 `tests-passed`、`scanPasses=2`、`findingCount=0`，ZIP 和 `.sha256` 都存在。用独立解压目录检查：

- 两个中文 CMD、`qvw.ps1`、脚本、模块、适配器和文档都在 allowlist 中；
- 没有 `.env`、`.git`、backups、sessions、日志、历史计划、任务报告或本机路径；
- 每个 entry 的 ZIP/DOS 时间字段相同且固定（ZIP 不保存时区，不能把该字段解释为 UTC 证明）；
- `.sha256` 的文件名与 ZIP 文件名一致，重新计算的摘要相同。

## GitHub 发布

1. 从新克隆或干净 checkout 开始，不把 `dist`、备份、测试输出和真实客户端配置加入提交。
2. 运行 Windows CI；它会在 `windows-2022` 上覆盖 Windows PowerShell 5.1 和 PowerShell 7，并执行 package inventory。
3. 在发布说明中同时提供 ZIP、SHA-256、安装入口和安全边界；不要上传诊断 ZIP、真实图片、会话日志或凭据。
4. 发布后从 GitHub 下载 ZIP 到全新的临时目录，重新运行 doctor 和 ZIP 安全扫描，再把结果记入发布记录。

## 版本和来源

当前包版本是 `1.0.0`。Qwen-MM 依赖固定在 `optional/qwen-mm/source-lock.json` 的不可变 commit；DeepSeek Harness 的来源 commit、受控文件和 payload 哈希在 `adapters/deepseek-harness/manifest.json`。更新任一来源都必须重新审计、更新第三方声明、运行全量测试和重新生成 SHA-256，不要把 mutable `main` 当成已验证来源。

## 真实验收边界

真实 Hermes/DeepSeek Harness/Qwen-MM 图片验收属于目标环境检查，可能消耗服务额度，必须单独明确确认并使用无敏感信息的确定性 PNG。发布包只证明代码、测试、打包和静态边界；未在当前机器运行的目标环境不得写成 `target-accepted` 或 `final-accepted`。

## 回滚发布

若发布后发现包扫描、安装、依赖或目标验收问题：暂停传播，保留版本和 SHA-256，撤回下载链接或标记为 blocked，并发布修正版。不要用同一版本覆盖 ZIP；安装到客户端的修改通过具体 receipt 回滚，源代码修复通过新的 Git 提交和新的包版本处理。
