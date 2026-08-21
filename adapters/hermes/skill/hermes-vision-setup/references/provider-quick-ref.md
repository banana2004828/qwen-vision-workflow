# Hermes provider quick reference

| 项目 | 当前值 |
| --- | --- |
| image input mode | `agent.image_input_mode=auto` |
| auxiliary provider | `alibaba` |
| auxiliary vision model | `qwen3.7-plus` |
| DashScope base URL | `DASHSCOPE_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1` |
| credential variable | `DASHSCOPE_API_KEY` |
| primary model | 保持用户当前值，安装器回读比对 |

使用 `hermes config path` 和 `hermes config env-path` 确认活动文件；不要凭默认路径猜测。使用 `hermes config check` 验证 schema，使用项目 doctor/verify/rollback 命令完成外部闭环。

凭据发现顺序为已有环境变量、Harness 适配器明确传入的
`HarnessCredentialPath`、当前用户 `%USERPROFILE%\\.dsh\\.credentials.yaml`；`HarnessRoot`
只有在本身是已解析凭据文件时才兼容，不能从仓库根目录猜测 `.dsh` 子目录。空或无法验证的
`SecureString` 会在事务开始前被拒绝。写前必须通过 provider marker、schema、版本冲突和
`config check` 闸门；失败时不创建备份或改写文件。

`tools.vision` 是旧路由，不属于当前 schema。Qwen-MM-Plugins 是可选 API/MCP 增强层，必须固定版本、单独备份和单独回滚；它的连接成功不能替代 Hermes 原生辅助视觉边界验收。
