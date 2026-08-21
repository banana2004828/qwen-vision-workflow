---
name: hermes-vision-setup
description: Use when diagnosing or configuring Hermes Agent image input with an Alibaba DashScope Qwen auxiliary vision model.
---

# Hermes 千问视觉配置

## 适用范围

该 Skill 只处理 Hermes Agent 的图片路由配置和验收。当前主文本模型保持不变；当主模型不能直接接收图片时，Hermes 使用辅助视觉模型生成文字视觉上下文，再交给主模型继续回答。

## 当前 schema

受支持的 Hermes 配置只有下面三个目标键：

```yaml
agent:
  image_input_mode: auto
auxiliary:
  vision:
    provider: alibaba
    model: qwen3.7-plus
```

`DASHSCOPE_API_KEY` 和 `DASHSCOPE_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1` 放在活动 Hermes 根目录的 `.env`，由安装器备份、原子写入并限制访问权限。主 `model`、platform、工具集和聊天历史不得被改写。不要创建或推荐旧的 `tools.vision` 配置。

The controlled keys are `agent.image_input_mode=auto`, `auxiliary.vision.provider=alibaba`, and `auxiliary.vision.model=qwen3.7-plus`.

## 安全边界

禁止在 Hermes 对话内修改安全敏感配置（security-sensitive config）。Hermes 对话只能解释状态、给出命令和请求用户确认；配置、密钥、备份与回滚必须由外部安装器或受控 CLI 完成。不要把 API key 放到聊天提示、命令行参数、日志、收据、截图或 Git。

Never edit security-sensitive config inside a Hermes conversation.

凭据只由外部受控适配器解析：优先使用 process/machine/user 环境中的
`DASHSCOPE_API_KEY`，其次使用 Harness 适配器明确传入的
`HarnessCredentialPath`，最后才检查当前用户的
`%USERPROFILE%\.dsh\.credentials.yaml`（兼容读取 `credentials.yaml`）。旧的
`HarnessRoot` 参数仅在它本身已经是凭据文件时兼容使用；不能把 Harness 仓库目录
猜成凭据目录。结果只允许存在/来源/短指纹和隐藏的 `SecureValue`，不得输出明文。

## 标准流程

1. 只读诊断和写前闸门：

   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File qvw.ps1 -Action doctor -HermesRoot <活动根目录> -Json`

   安装器在开始事务前必须再次确认活动 config/env 路径、source/venv 版本没有冲突、
   Alibaba provider marker 存在、schema 可读且 `hermes config check` 成功。当前
   `agent.image_input_mode` 或 `auxiliary.vision` 还是空值/旧值，只表示“尚未配置”，
   不表示 schema 不支持。

2. 用户明确同意产生真实 API 调用后验收图片：

   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File qvw.ps1 -Action verify -HermesRoot <活动根目录> -ConfirmPaidCalls -Json`

3. 需要恢复最近一次安装时：

   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File qvw.ps1 -Action rollback -HermesRoot <活动根目录> -Receipt <收据路径> -Json`

   只有收据回读确认 `rolled-back` 才能报告回滚成功；若自动恢复失败，结果必须是
   `QVW-H-ROLLBACK-FAILED`，保留脱敏收据路径并要求人工恢复，不能声称已恢复。

验收必须同时看到辅助请求包含图片、provider 为 `alibaba`、model 为 `qwen3.7-plus`，以及主模型边界已将图片替换成视觉文字上下文。只看到最终一句“看到了”不算通过。

## Qwen-MM 边界

官方 Qwen-MM-Plugins 只作为可选增强层，用于 OCR、grounding 或显式 vision chat；它不是 Hermes 原生自动图片路由的替代品。必须使用不可变版本并单独测试 MCP 连接和真实 PNG 调用。可选层失败时回滚可选层，保留 Hermes 原生流程。

## 常见问题

- `agent.image_input_mode` 不是 `auto`：重新运行 doctor，确认活动 CLI 与配置路径，不要直接编辑未知配置。
- provider 或 model 不匹配：检查 `.env` 中 key 是否存在（只看存在/缺失），不要打印 key。
- 需要恢复：使用上面的 rollback 命令和对应收据；恢复后重新运行 doctor，再决定是否 verify。
