# Qwen3.8-27B 本地部署 Runbook（JIP · Java/PL-SQL 代码与运行时根因分析）

> 用途：在双卡 RTX 4090（48GB 魔改版 ×2）服务器上，用 Ollama 部署 Qwen3.8-27B，
> 支撑 Java + PL/SQL 代码分析、客户运行时问题根因诊断。
> 阶段：**POC，质量优先**（效率优化留待后续）。
> 维护者：AI Team。最后更新：2026-08-18。

---

## 0. TL;DR（照抄即可）

```bash
# 首选：质量与显存/速度的甜点（8bit，质量≈bf16 肉眼无差）
ollama pull qwen3.8:27b-q8_0

# 极致质量（原始精度，双卡 96GB 才带得动）—— POC 想排除量化影响时用
ollama pull qwen3.8:27b-bf16

# 起模型做根因分析：显式拉大 context + 开高深度推理
ollama run qwen3.8:27b-q8_0 --think=high
#   在交互里 /set parameter num_ctx 131072  （或走 API 传 num_ctx，见 §4）
```

**两个必记的运行时坑**
1. Ollama 默认 context 仅 ~4K，**必须显式设 `num_ctx`（128K+）**，否则长代码被悄悄截断，质量假性下降。
2. 深度推理是**请求时**参数（`--think` / `think`），非 pull 时固定。根因分析用 `high`/`max`。

---

## 1. 目标硬件（实测确认）

| 项目 | 实测值 |
|------|--------|
| GPU | 2× NVIDIA GeForce RTX 4090，**每张 49140 MiB（≈48GB）**，双卡共 **≈96GB VRAM** |
| 驱动 / CUDA | 550.90.07 / CUDA 12.4 |
| 系统内存 | 251 GB total（充裕） |
| Swap | 8GB 已用满（物理内存足够，可忽略，建议关注） |
| OS | Ubuntu，(base) conda 环境，Ollama 已装 |
| 主机 | `ps@ps`（登录方式见团队记录） |

> 结论：硬件不是瓶颈。27B/128K 上下文绰绰有余，可放心走"质量优先"，甚至跑满 bf16。

---

## 2. 目标模型：Qwen3.8-27B（Ollama 官方库，2026-08 上架）

来源：<https://ollama.com/library/qwen3.8/tags>

| 能力 | 说明 |
|------|------|
| 参数 | 27B **稠密** |
| Context | **原生 256K**（远超需求的 >128K，留一倍余量） |
| 能力标签 | **thinking / tools / vision** |
| 强项 | coding、专业工作、research、长程 agentic 任务全面增强 |
| 推理控制 | thinking 默认开、可 per-request 关；`reasoning_effort` 调深度；`preserve_thinking` 保留历史推理 |
| 多模态 | 原生 image/video 理解（可直接看报错截图/监控图/架构图） |

**为何选它**：256K 上下文 + 强 coding/agentic + 可调深度推理，正对"读长代码 + 想清楚根因"；
原生 vision 是白送的能力，避免把未来用例限死。

---

## 3. 量化版本对比（体积为 Ollama registry 实测字节数）

| Tag | 体积 | 精度/质量 | 单卡(48G)放得下 | POC 建议 |
|-----|------|-----------|:---:|------|
| `27b-bf16` | **51.8 GB** | 原始全精度，质量天花板 | 否，需双卡切分 | ⭐ 极致质量 |
| `27b-mxfp8` | 29.5 GB | 8bit(MX)，≈无损 | 可 | 可选 |
| **`27b-q8_0`** | **27.9 GB** | 8bit，质量≈bf16 | 可 | ⭐⭐ **首选** |
| `27b-nvfp4` | 16.9 GB | 4bit(NVFP4，4090 友好) | 可 | 要速度时 |
| `27b-q4_K_M` | 16.5 GB | 4bit，有可感知质量损失 | 可 | POC 不推荐 |
| `27b-mtp-*` | 同对应量化 | 带 MTP 多token预测**加速**层 | — | 效率阶段再评估 |
| `27b-mlx-*` | — | Apple Silicon 专用 | 不适用 | ❌（本机是 4090） |

**决策逻辑**
- POC 质量优先 → **q8_0**（8bit 对 27B 输出质量与 bf16 基本不可区分，体积腰斩、加载快、KV cache 更省，长上下文更从容）。
- 想彻底排除"量化拖后腿"疑虑 → **bf16**（双卡才敢玩，别处没这条件）。
- **暂不碰 q4 系列**：4bit 在代码符号、PL/SQL 边界条件、长链推理上偶尔丢细节，与根因分析诉求冲突；留待效率阶段配 `mtp` 加速再评估。

> 查体积的方法（备查）：registry manifest 需带 header
> `Accept: application/vnd.docker.distribution.manifest.v2+json`，累加 layers[].size。

---

## 4. 部署步骤

### 4.1 环境检查
```bash
nvidia-smi                      # 确认双卡在线、显存空闲
ollama --version                # 确认 ollama 已装
ollama ps                       # 确认当前无模型占用显存
df -h ~                         # 确认磁盘 ≥ 60GB（bf16 需 ~52GB）
```

### 4.2 拉取模型
```bash
ollama pull qwen3.8:27b-q8_0        # 首选
# ollama pull qwen3.8:27b-bf16      # 极致质量（可选）
ollama list                          # 确认落地
```
> 若服务器上网需代理：`export https_proxy=http://proxy.apj.ibm.com:8080 http_proxy=$https_proxy`
> （若该机走内网直连 ollama 镜像则不需要，按实际网络为准。）

### 4.3 多卡放置
- Ollama 会**自动跨双卡切分** bf16（单卡 48G 放不下 51.8GB）。
- q8_0（27.9GB）单卡即可，无需干预。
- 如需强制指定卡：`export CUDA_VISIBLE_DEVICES=0,1`。

### 4.4 起模型（关键：大 context + 深推理）

**交互式（CLI）**
```bash
ollama run qwen3.8:27b-q8_0 --think=high
# 进入后设置大上下文：
>>> /set parameter num_ctx 131072
>>> 分析下面这段 PL/SQL 的死锁根因 ...
```

**API（/api/chat，推荐用于集成）**
```bash
curl http://localhost:11434/api/chat -d '{
  "model": "qwen3.8:27b-q8_0",
  "messages": [
    {"role":"system","content":"你是资深 Java/PL-SQL 代码与运行时问题根因分析专家。先给根因，再给对策，附证据。"},
    {"role":"user","content":"<粘贴代码/堆栈/日志>"}
  ],
  "think": "high",
  "options": { "num_ctx": 131072 },
  "stream": false
}'
```
- 思考过程在返回的 `message.thinking`，正式答案在 `message.content`（前后端可解耦展示）。
- 常驻内存避免反复加载：加 `"keep_alive": "30m"`（或 `-1` 常驻）。

---

## 5. 运行时推理深度控制（请求时可调，非 pull 固定）

| 层 | 参数 | 取值 | 用途 |
|----|------|------|------|
| Ollama | `think` / `--think` | `false` / `true` / `low` / `medium` / `high` / `max` | 总开关+四档深度 |
| 模型原生 | `reasoning_effort` | low..high | 细调推理深度（OpenAI 兼容端点/chat template） |
| 模型原生 | `preserve_thinking` | bool | 多轮保留历史推理上下文 |

**任务档位建议**

| 场景 | 配置 |
|------|------|
| 根因分析 / 复杂 Java·PL-SQL 推理（POC 主场景） | `think: "high"` 或 `"max"` + `num_ctx` 拉满 |
| 简单查代码 / 格式化 / 摘要 | `think: false`（省时间） |
| 多轮追问同一 bug | 开 thinking + `preserve_thinking` |

> think 档位越高越慢——POC 质量优先无所谓；进入效率阶段时，这是第一个可回调的旋钮，其次是切 `mtp` 量化。

---

## 6. 验证清单（部署后逐项打勾）

- [ ] `nvidia-smi` 双卡在线、显存空闲，驱动 550.90.07 / CUDA 12.4。
- [ ] `ollama list` 能看到 `qwen3.8:27b-q8_0`（及可选 bf16）。
- [ ] **冒烟测试**：`ollama run qwen3.8:27b-q8_0 --think=high`，问一句简单代码问题，确认能出 thinking + 答案。
- [ ] **大上下文测试**：`num_ctx=131072`，粘贴一个 >5万 token 的真实 Java 文件，确认**未被截断**（模型能引用文件末尾内容）。
- [ ] **多卡测试（仅 bf16）**：加载时 `nvidia-smi` 观察两卡显存都被占用（自动切分生效）。
- [ ] **深度对照**：同一根因分析问题分别跑 `think=false / high / max`，记录**质量 vs 耗时**，据此定 POC 默认档。
- [ ] **质量对照（可选）**：`q8_0` vs `bf16` 跑同一批真实 Java/PL-SQL 案例，确认 q8_0 质量足够（多数情况下应无明显差距）。
- [ ] 记录首 token 延迟 / tok/s / 峰值显存，写回本文件 §8。

---

## 7. 常见坑速查

| 现象 | 原因 | 处理 |
|------|------|------|
| 长文件分析"漏看"结尾 | `num_ctx` 默认太小（~4K） | 显式设 `num_ctx` 128K+ |
| 不出思考过程 | `think` 未开或设了 `false` | `--think=high` / API 传 `think` |
| 加载慢/反复重载 | 未常驻 | `keep_alive: "30m"` 或 `-1` |
| bf16 报显存不足 | 未跨卡切分 | 确认 `CUDA_VISIBLE_DEVICES=0,1`，Ollama 自动分片 |
| Swap 报警 | 8GB swap 用满 | 物理内存 251G 充足，一般可忽略；持续增长再排查 |
| 拉取超时 | 需代理 | `export https_proxy=http://proxy.apj.ibm.com:8080`（按实际网络） |

---

## 8. 实测记录（部署后填写）

| 日期 | 模型/量化 | num_ctx | think 档 | 首token延迟 | tok/s | 峰值显存 | 质量主观评分 | 备注 |
|------|-----------|---------|----------|-------------|-------|----------|--------------|------|
|      |           |         |          |             |       |          |              |      |

> 依据本表实测结果，最终锁定 POC 默认配置（量化版本 + think 档位 + num_ctx），并在此记录决策理由。
