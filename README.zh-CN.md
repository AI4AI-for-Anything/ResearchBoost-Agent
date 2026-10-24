<p align="center">
  <img src="docs/assets/researchboost-agent-logo.png" alt="ResearchBoost-Agent logo" width="480">
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a>
</p>

<b><p align="center">用 AI 加速 AI 研究。</p></b>

ResearchBoost-Agent 从研究者日常使用的训练代码入手，用 AI 加快实验迭代。它自主分析性能瓶颈、实现优化，并按照预先固定的评测规则验证加速效果，让研究者在相同算力预算下开展更多实验。

<div align="center">
<table>
<tr><td align="center">
<p><strong>🚀 项目 Blog 与 Wishlist</strong></p>
<p>我们的项目 Blog 已上线，了解 ResearchBoost 的方法与训练加速成果。<br>
欢迎通过 Wishlist 提交你希望优化的项目！</p>
<a href="https://ydove0324.github.io/hx_resume/blog/researchboost/"><img src="https://img.shields.io/badge/Read_the_Blog-7C3AED?style=for-the-badge" height="24" alt="阅读项目 Blog"></a>
&nbsp;
<a href="https://ydove0324.github.io/hx_resume/blog/researchboost/#wishlist"><img src="https://img.shields.io/badge/Submit_to_Wishlist-0891B2?style=for-the-badge" height="24" alt="提交项目"></a>
</td></tr>
</table>
</div>

## 快速开始

在 GPU 主机上用 [claw-orchestrator](https://github.com/Enderfga/claw-orchestrator) 驱动运行：

```bash
npm install -g @enderfga/claw-orchestrator   # 7.13.0 或更高版本
clawo serve                                   # 保持运行
```

配置 agent 使用的模型 API：

```bash
cp goal/codex.env.example goal/codex.env
# 编辑 goal/codex.env：填 OPENAI_API_KEY 和 OPENAI_BASE_URL（可选 CODEX_MODEL）
```

然后让你的 agent 按 [docs/run-a-task.md](docs/run-a-task.md) 操作。

## 运行流程

![运行流程：定义任务并固定评测规则，随后由 agent 在沙箱内反复分析性能、修改代码、计时、完整评测并记录结果](docs/figures/goal-mode-loop.svg)

1. **定义任务。** 任务负责人先明确必须保持不变的设置：上游训练工作负载、每张 GPU 的负载、基线数值精度和训练计算逻辑。负责准备任务的 agent 搭建评测程序（`bench/` 和一份固定版本的 [`numerics/`](numerics)），记录基线结果，并固定容差 δ。随后用已知有问题的候选版本验证各项检查能否正确拒绝错误，最后编写 `GOAL.md`。
2. **运行优化。** 在 bubblewrap 沙箱内，为一个 Codex `/goal` 会话提供工作区、GPU 和技能文档。每轮先分析当前最佳版本的性能，再优化一个瓶颈，并通过配置开关控制是否启用。用 `bench.py time` 计时后，将本轮结果写入 `WORK_LOG.md`。会话由 [claw-orchestrator](https://github.com/Enderfga/claw-orchestrator) 运行：主机重启或模型接口达到用量上限后，它会接回同一个 Codex 线程继续；Codex 停下后，由它亲自运行完整评测。监督 agent 在沙箱外监控运行，仅针对规则执行和事实核对进行干预，不指导优化方向。详见 [docs/goal-mode.md](docs/goal-mode.md)。
3. **验证结果。** 以 `bench.py check` 的结果作为唯一通过标准。完整评测通过后，再通过实际的端到端训练或评测验证结果。

## 已有结果

下表数值来自各任务预先固定的评测程序，或已通过验证的优化版本的完整训练、评测结果。

| 任务 | 上游 | 优化时的硬件 | 评测结论 | 加速 | 代码 |
|---|---|---|---|---|---|
| RAE Stage-1 训练（解码器 + GAN） | bytetriper/RAE @a4d18c4 | 2 × H200 | PASS，统计等价 | 单步训练加速 **5.32×**；8 × H20 完整训练 16 epoch：rFID 0.541，公开权重 0.569 | [Faster-RAE](https://github.com/AI4AI-for-Anything/Faster-RAE) |
| Self-Forcing 视频 DMD 训练 | guandeh17/Self-Forcing @33593df | 2 × H200 | PASS，统计等价 | **2.08×** | [Faster-SelfForcing](https://github.com/AI4AI-for-Anything/Faster-SelfForcing) |
| LLaVA-1.5-7B 第二阶段微调 | haotian-liu/LLaVA @c121f04 | 4 × H20 | PASS，统计等价 | **2.39×**；实际训练 1 epoch 后，四项评测得分与使用官方权重的模型相差 −0.50 ~ +0.44 | [Faster-LLaVA](https://github.com/AI4AI-for-Anything/Faster-LLaVA) |
| DMD2 一步蒸馏（SD1.5 + GAN） | tianweiy/DMD2 @8d8fa55 | 4 × H20 | PASS，统计等价 | **1.72×**；8 × H20 上 FID-30k 8.70，基线 8.65 | [Faster-DMD](https://github.com/AI4AI-for-Anything/Faster-DMD) |

## 评测

候选版本必须通过预先固定的评测。评测依次执行以下检查；某项检查失败后，不再继续：

0. **结构检查**：通过 AST 比对确认评测所调用的训练入口未被修改；数据加载结果逐位一致；训练阶段、调用次数、随机数状态指纹、学习率和跨进程同步等要求精确匹配的项目全部一致。
1. **性能检查**：按“基线 → 候选版本 → 基线”的顺序，在独立进程中分别计时。加速比若不超过 `max(1.02, 1 + 2 × 两次基线计时的相对差异)`，则判定为无性能收益（`no_benefit`），不再进行数值精度检查。
2. **逐位一致性检查**：在确定性的短序列测试中，如果记录的全部张量与基线逐位一致，则通过评测。
3. **统计检查**：如果未达到逐位一致，则使用配对的随机种子分别运行基线和候选版本，比较训练轨迹。各项终点指标与基线的差异必须在容差 δ 内。δ 取基线在不同随机种子下对应指标标准差的两倍，在评测任何候选版本之前固定。

评测程序在优化开始前固定，并记录哈希用于校验，后续不因候选结果而放宽评测规则。详见 [docs/judge.md](docs/judge.md)。

## 创建新任务

先阅读 [AGENTS.md](AGENTS.md) 和 [docs/methodology.md](docs/methodology.md)，再将 [`goal/templates/FORMULATOR_BRIEF.md`](goal/templates/FORMULATOR_BRIEF.md) 交给负责准备任务的 agent。以 [`tasks/dmd2`](tasks/dmd2) 为模板，准备任务说明 `GOAL.md`、提供 `check` / `time` / `profile` 命令的评测目录 `bench/`、对接 [`numerics/`](numerics) 的任务适配器，以及用于重建环境和固定基线的准备脚本。

## 目录

| 路径 | 内容 |
|---|---|
| [`docs/`](docs) | 英文文档：[方法](docs/methodology.md)、[评测](docs/judge.md)、[goal 模式](docs/goal-mode.md)、[任务运行指南](docs/run-a-task.md)、[四个任务的经验](docs/lessons.md) |
| [`goal/`](goal) | 在 claw-orchestrator 上运行 Codex `/goal` 会话的工具：bubblewrap 沙箱、Codex 配置模板和模型 API 配置文件、启动 / 查看状态 / 发送提醒 / 恢复运行的脚本和最终评测、监控脚本，以及任务准备和监督 agent 的说明 |
| [`numerics/`](numerics) | 各任务评测复制并固定版本的数值等价性检查组件：数据记录、逐位和分级比对、配对随机种子的训练轨迹比对、任务适配器基类及自测 |
| [`skills/`](skills) | 选择优化方向前阅读的 8 份技能文档：`train-opt-*`（性能分析、计时、分阶段优化步骤、数值验证、算子融合方法、FSDP 多次前向计算）和 `sglang-diffusion-*`（扩散模型的性能测试与优化方法） |
| [`tasks/`](tasks) | 各任务的材料：agent 使用的 `GOAL.md`、固定版本的评测代码、评测结果存档、监督记录和准备脚本 |

## 致谢

感谢 [SGLang](https://github.com/sgl-project/sglang) 项目。本仓库的部分计算内核优化技能文档移植自 SGLang：[`skills/sglang-diffusion-benchmark-profile`](skills/sglang-diffusion-benchmark-profile) 和 [`skills/sglang-diffusion-performance`](skills/sglang-diffusion-performance) 改编自 [`python/sglang/multimodal_gen/.agents/skills`](https://github.com/sgl-project/sglang/tree/main/python/sglang/multimodal_gen/.agents/skills) 中的技能文档，这些文档采用 Apache-2.0 许可证。
