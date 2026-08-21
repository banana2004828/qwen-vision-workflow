# 第三方声明

本项目自身以 MIT License 发布，见 [LICENSE](LICENSE)。以下内容只说明本仓库中适配器、锁文件、Skill 或补丁引用的第三方来源；第三方模型服务、账号和配额仍受其各自条款约束。

## Qwen-MM-Plugins

- 项目：[`QwenLM/Qwen-MM-Plugins`](https://github.com/QwenLM/Qwen-MM-Plugins)
- 用途：可选的 Qwen-MM API Skill/MCP 层，用于显式 vision chat、OCR 和 grounding。
- 固定标签：`qwen-mm-plugins-api-v1.0.1`
- 不可变 commit：`ef18102f374cf9465188081622222b284a823174`
- 许可证：Apache License 2.0；上游许可证和版权声明以该 commit 中的 `LICENSE`/项目元数据为准。
- 本地来源锁：`optional/qwen-mm/source-lock.json`，其中记录了 Skill 文件 raw URL 和 SHA-256。
- 官方来源：[仓库](https://github.com/QwenLM/Qwen-MM-Plugins)、[Apache-2.0 许可证](https://github.com/QwenLM/Qwen-MM-Plugins/blob/ef18102f374cf9465188081622222b284a823174/LICENSE)。

本项目没有把 Qwen-MM 当作自动图片路由的替代实现；它是可选层，安装失败应只影响可选层。打包时不下载网络依赖，也不包含任何运行时凭据。

## DeepSeek Harness / prompt-image bridge

- 上游项目：[`deepseek-ai/deepseek-harness`](https://github.com/deepseek-ai/deepseek-harness)
- 固定上游 commit：`47f943859bef60e4160492346772ded9b24f765a`
- 用途：兼容版本的受控 prompt-image bridge；本仓库只带审计后的 patch、manifest 和 PowerShell 适配器。
- 许可证：上游仓库及该来源 commit 的 MIT License；请以对应 commit 的许可证文件和版权声明为准。
- 随包许可证副本：[`licenses/DeepSeek-Harness-MIT.txt`](licenses/DeepSeek-Harness-MIT.txt)，保留 `Copyright (c) 2026 DeepSeek` 及完整 MIT 条款。
- 本地来源锁：`adapters/deepseek-harness/manifest.json`，记录受控文件、preimage/postimage SHA-256、排除路径和外部挂载策略。
- 补丁：`adapters/deepseek-harness/payload/prompt-image-bridge.patch`。它不包含生成的 `node_modules`、build、日志、会话或其他本机状态。
- 官方来源：[仓库](https://github.com/deepseek-ai/deepseek-harness)、[MIT 许可证](https://github.com/deepseek-ai/deepseek-harness/blob/47f943859bef60e4160492346772ded9b24f765a/LICENSE)。

兼容性不以仓库名称或当前分支活动推断：适配器会检查精确 commit、受控文件指纹、挂载和测试边界；未知或脏状态会安全阻断。

## Hermes、DashScope 与其他服务

Hermes Agent、DashScope/Qwen 模型服务、DeepSeek Harness 运行时、PowerShell、Git、pnpm 和 uv/uvx 均是外部软件或服务。本项目只调用其公开 CLI/API 能力，不重新分发其闭源运行时，也不代表其官方立场。请分别遵守上游许可证、服务条款、隐私政策和额度规则。
