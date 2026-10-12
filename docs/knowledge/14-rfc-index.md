# 14 设计记录（RFC）与产品文档（PRD）索引

> 用途：`rfc/` 下 28 篇设计记录和 `PRD/` 下 11 篇产品与交接文档，每篇一行，说明主题、文件头写的状态，以及按代码判断的实际情况。想知道"某个设计为什么这样"时，从这里找到原文。已落地的关键决策提炼在 [09](./09-decisions.md)。

## 1. 阅读提示

- **很多 RFC 文件头的状态比代码旧。**例如 RFC-019、RFC-020 写着"提案，未实现"，而 `ARCHITECTURE.md` §4 和代码表明它们已经落地。下表"实际情况"一列以代码为准，标注了核对依据。
- **RFC-001 到 RFC-012 描述的是留在上游的 Python/MLX 引擎**，是现在这个移植长成这样的原因，但里面的命令在本仓库跑不了（`AGENTS.md`「Conventions」）。
- 被引用但本仓库没有文件的编号：RFC-009（API-SPEC 引用）、RFC-022（RFC-023、RFC-028 引用）、RFC-029（RFC-028 引用）、RFC-031 和 RFC-032（片边与数据背，条文写在移动端仓库 `SpektraLab_mobile/rfc/`，见 API-SPEC §13）、RFC-033（拍摄数据，ARCHITECTURE 与 PRD 引用）。

## 2. 设计记录（`rfc/`）

### 2.1 Python 时代（上游引擎的历史）

| 编号 | 标题（意译） | 文件头状态 | 主题 |
|---|---|---|---|
| RFC-001 | spektrafilm 运行时的 MLX/Metal 后端 | Draft | Python 时代的 GPU 后端计划 |
| RFC-002 | 精确颗粒采样与 45 MP 内存预算 | 已实现（M1.6） | `exact` 颗粒采样器、内存；陷阱 8 的来源 |
| RFC-003 | 流水线解耦 | 提案（M2） | 命名节点序列与"抽头"（tap）拓扑，C++ 引擎的节点名沿用它 |
| RFC-004 | 分阶段 GPU 移植（M3） | Accepted（M3.0） | float32 GPU 移植路线 |
| RFC-005 | GPU 时间到底花在哪：派发、驻留、内核质量 | P0 已实现，P1–P3 提案 | 派发与驻留 |
| RFC-006 | float32 色彩精度：工作精度切换是否安全 | Applied | float32 成为默认工作精度；陷阱 7 |
| RFC-007 | CPU 路径：融合、语言选择、异构调度 | A 已实现，B–D 提案 | numba 融合与线程 |
| RFC-008 | 可选的随机颗粒与眩光 | A 已实现，B 提案 | 颗粒引擎替换 |
| RFC-010 | 在每个失败都无声的情况下如何测试色彩科学 | Proposed | 不变性测试；陷阱 11 |
| RFC-011 | GPU 原生渲染核心：热路径上没有 numba、NumPy、Python | 已在 `gpu/native-metal` 实现（2026-09-10） | Python 版的 Metal 核心；渲染门槛 1.9e-5 的来源 |
| RFC-012 | 一个进程、一个包：退役 Python 服务 | Proposed | 目标已由 RFC-014 实现（运行时无 Python） |

### 2.2 原生引擎与应用

| 编号 | 标题（意译） | 文件头状态 | 实际情况（依据） | 主题 | 知识库 |
|---|---|---|---|---|---|
| RFC-013 | 会话缓存，以及先付掉启动窗口的时间 | 后端已实现；前端未写 | 应用有启动窗口并在其间调用 `warm_up`（`Windows/BootWindow.swift`、`Session.warmUp`），文件头可能过时 | `spk_warm_up`、启动窗口 | [07](./07-scheduled-tasks.md) |
| RFC-014 | 链接进应用的 C++ 渲染引擎 | 已实现 2026-09-10（步骤 1–5） | 已实施。§8 是事后记录：一致性测什么、门槛为什么、发现过哪些 bug | 引擎、C 接口、一致性 | [05](./05-engine-boundary.md)、[16](./16-parity.md) |
| RFC-015 | 按意图测光的自动曝光，以及能到达引擎的白平衡 | 提案 2026-09-11，"未实现" | **部分已落地**：`auto_exposure_method`（四种意图 + 三种旧方式）与每帧一次测光（P.1）在 CONTRACT §6 记为 2026-09-12 上线，代码有 `kMeterLongEdge`、`kMeterKeyFields` | 测光方式、白平衡 | [04](./04-render-flow.md) |
| RFC-016 | 值得一读的日志 | 已实现 2026-09-12 | 已实施（`Diagnostics/LogCore.swift`、`LogFile.swift`） | 日志、内存采样、诊断包 | [02](./02-architecture.md) |
| RFC-017 | 应用到全部图片，以及谁有权启动工作 | 提案，未实现 | 未核实；设置同步由 RFC-027 实现 | 批量应用、准入控制 | — |
| RFC-018 | ProPhoto 工作空间、一次输出变换、导出前所见即所得 | 已实现 2026-09-13（导出页布局除外） | 已实施（`ColourManagement.swift`、`spk_output_transform`、`SoftProof.swift`） | 色彩管理、软打样 | [10](./10-physical-model-and-colour.md) |
| RFC-019 | 拥有、记账、封顶的内存，让应用吃不掉机器 | 提案 2026-09-14，"未实现" | **已落地**（`MemoryArena`、`DiskCacheStore`、`PrintWriteback`；`ARCHITECTURE.md` §4） | 内存台账、上限、磁盘缓存 | [15](./15-engine-gpu-and-memory.md) |
| RFC-020 | 引擎归还内存，以及分块冲洗一帧 | 提案 2026-09-20，"未实现" | **已落地**：缓冲池回收、内存压力、空闲回收、文件映射平面、条带执行器都在 `metal_gpu.cpp`/`pipeline.cpp`；条带执行应用未开启 | 内存回收、条带渲染 | [15](./15-engine-gpu-and-memory.md) |
| RFC-021 | 告诉用户有新版本 | 已实现 2026-09-21 | 已实施（`Updates/UpdateCheck.swift`） | 版本检查 | [07](./07-scheduled-tasks.md) |
| RFC-023 | 场景宽容度映射：把现代场景装进不变的胶片/相纸模型 | 引擎已实现 2026-09-24，默认关闭，暂无界面 | 应用已有 Latitude 和 Scene Placement 分区（`Panels/Sections/LatitudeSection.swift`），文件头"无界面"已过时 | 胶片前的场景映射 | [05](./05-engine-boundary.md)、[10](./10-physical-model-and-colour.md) |
| RFC-024 | 虚拟反差蒙版：把负片装进不变的相纸 | 引擎已实现 2026-09-23，默认关闭，暂无界面 | 引擎在；应用界面由 `FeatureFlags.toneMask = false` 撤下（2026-09-29 用户决定） | 放大机侧区域增益 | [05](./05-engine-boundary.md) |
| RFC-025 | 解耦的效应强度 | 已实现 2026-09-25；被 RFC-034 修订 | 已实施（`grain_amount`、`glare_amount`、`halation_scatter_amount` 等字段） | 各效应独立的强度滑块 | — |
| RFC-026 | 命令行与 MCP 服务端：agent 只编辑，不生成 | 已实现 2026-09-26（1.1.1） | 已实施（`Agent/`） | CLI、MCP、访问开关 | [06](./06-api-reference.md) |
| RFC-027 | 设置剪贴板：七个分组，按选择复制，在目标上解算 | 已实现 2026-09-28（分支 `recipe-clipboard`） | 已在主线（`Model/SettingsClipboard.swift`） | 复制、粘贴、同步设置 | [03](./03-core-modules.md) |
| RFC-028 | 数字去色罩与反转（去色罩）：从计算出的负片得到扫描仪式的正像 | 已实现 2026-09-29 | 已实施，界面名 Digital Intermediate / 数字中间片（`spk_render_digital_intermediate`） | Cineon log 数字中间片 | [06](./06-api-reference.md) |
| RFC-030 | 胶片性格：DI 里的每胶片反差，以及每胶片颗粒 | §2 已实现（1.2.1）；§4–§5 等真实数据 | 部分已实施（`FilmParams.ownGrain`） | DI 反差、颗粒 | [11](./11-film-edge-pairs-bw.md) |
| RFC-034 | 效应强度是面积乘数 | 已实现 2026-10-01 | 已实施；眩光范围待负责人确认 | 光晕、眩光强度的定义 | — |

`rfc/probes/` 下是各 RFC 的探测脚本（如 `rfc023-slm-probe.py` 测介质宽容度，`rfc020-footprint-probe.swift` 测内存占用）；`rfc/figures/rfc028/` 是 RFC-028 的图。

## 3. 产品与交接文档（`PRD/`）

| 文件 | 类型 | 主题 |
|---|---|---|
| `PRD-export-page-v2.md` | 产品需求 | 导出页 v2、解码缓存、去掉 Browse 模式 |
| `IMPL-export-page-v2.md` | 实现说明 | 导出页 v2 的实现 |
| `PRD-settings-clipboard.md` | 产品需求 | 编辑配方的复制与粘贴，由 RFC-027 实现 |
| `IMPL-RFC-019-memory.md` | 实现说明 | RFC-019 的台账、上限、驻留、缓存、缓冲池实现逻辑 |
| `PLAN-RFC-019-quality.md` | 质量计划 | RFC-019 内存子系统的质量计划 |
| `IMPL-decode-pipeline.md` | 实现说明 | 解码取消、单飞、缓存，去掉 Browse |
| `Frontend_Rework_2026-09-17.md` | 产品需求 | 新界面体系（Capture One / Codex 风格、可折叠侧栏、测光方式） |
| `BUG-DIAGNOSIS-2026-09-14-export-and-decode.md` | 诊断 | 导出页、解码路径、"幽灵点"问题，只诊断不修 |
| `HANDOFF-2026-10-02-half-frame-pair-and-panoramic.md` | 交接 | 半格双拼、片边、宽幅的设计交接（当时尚未实现） |
| `QUESTIONS-2026-10-02-half-frame-film-edge-panoramic.md` | 问答 | 负责人对半格、片边、宽幅问题的回答。代码注释里的"answer sheet C1、C5、C8""answer E10"很可能指它（推断，未逐条核对） |
| `HANDOFF-2026-10-03-film-edge-fixes-and-next.md` | 交接 | 片边与数据背修复后的状态和下一步 |

另有三张参考图：`capture_one_crop_reference.png`、`export_page_reference_capture_one.png`、`new_frontend_top_layout.png`。

被引用但不存在的文件：`PRD-callable-render-api.md`（API-SPEC 引用）、`HANDOFF-OPEN-PATH.md`、`HANDOFF-DISTRIBUTION.md`（`modern_UI/Spektrafilm/README.md`、`package.sh` 引用）、`handoff/` 目录（已被 git 忽略）。
