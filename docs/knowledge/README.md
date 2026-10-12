# SpektraLab 知识库

> 面向第一次接触本仓库的开发者和 AI 工具：用中文、自包含地说明 SpektraLab（macOS 胶片与相纸模拟器）是什么、怎么组织、怎么渲染、怎么构建验证，以及踩过哪些坑。所有事实以代码为准；翻译自英文文档的内容注明了原文出处（如「`ARCHITECTURE.md` §7.3」「陷阱 26」），便于以后对照同步。

## 文档索引

| 文档 | 内容 | 适合场景 |
|---|---|---|
| [01-project-overview.md](./01-project-overview.md) | 定位、能力、技术栈、目录结构、模块协作、版本、环境、许可证 | 新人入门 |
| [02-architecture.md](./02-architecture.md) | 单进程架构图、外部依赖、落盘位置与 SQLite 表、缓存汇总、内存与色彩概要、访问控制 | 了解全局、排查数据问题 |
| [03-core-modules.md](./03-core-modules.md) | 应用与引擎各模块职责、Layer 1/Layer 2、控件代价表、设置剪贴板、功能开关 | 找代码在哪、判断改动牵动哪层 |
| [04-render-flow.md](./04-render-flow.md) | 打开 → 解码 → 冲洗 → 编辑分流 → 合并调度 → 全分辨率渲染 → 导出；引擎侧每个节点与跳过条件；已知缺陷 | 理解"拖一下滑块发生了什么" |
| [05-engine-boundary.md](./05-engine-boundary.md) | C 接口约定、所有权、并发、线上协议规矩、版本协商、98 个字段、资源加载顺序、启动自检 | 加字段或改接口之前 |
| [06-api-reference.md](./06-api-reference.md) | 29 个 C 函数、14 个 Swift 方法、命令行（CLI）、12 个 MCP（Model Context Protocol，模型上下文协议）工具、菜单快捷键、启动参数、环境变量 | 查某个入口的用途 |
| [07-scheduled-tasks.md](./07-scheduled-tasks.md) | 全部防抖、轮询、串行队列、启动与退出动作、引擎后台工作、批量导出循环 | 排查"结果没出现""后台在跑什么" |
| [08-glossary.md](./08-glossary.md) | 术语表 | 遇到看不懂的词 |
| [09-decisions.md](./09-decisions.md) | 20 条架构决策记录（ADR） | 想知道"为什么不那样做" |
| [10-physical-model-and-colour.md](./10-physical-model-and-colour.md) | 光路、材质模型原则、三段核心变换、阶段性质、色彩链路、反直觉实测 | 改任何影响画面的代码前 |
| [11-film-edge-pairs-bw.md](./11-film-edge-pairs-bw.md) | 片边格式与字段、数据背、半格双拼实现、黑白数据与配对规则 | 改这四个特性 |
| [12-build-test-release.md](./12-build-test-release.md) | 构建命令、工程生成、测试分级与可信度、截图工具盲区、发布 | 第一次构建、选测试、发版 |
| [13-traps.md](./13-traps.md) | 35 条踩坑记录，按主题分组 | 动手前、排查诡异问题 |
| [14-rfc-index.md](./14-rfc-index.md) | 28 篇设计记录（RFC）、11 篇产品需求文档（PRD）每篇一行，含文件头状态与实际情况 | 按主题找原始设计记录 |
| [15-engine-gpu-and-memory.md](./15-engine-gpu-and-memory.md) | GPU 五个动词、缓冲复用规则、内存回收、审计计数器、缓存、尺寸上限、性能数字 | 改引擎、排查慢和内存 |
| [16-parity.md](./16-parity.md) | 一致性校验脚本清单、运行方法、门槛依据、有意差异、校验盲区 | 改引擎之后 |

## 阅读路径

| 你是 | 按这个顺序读 |
|---|---|
| 新人，想先弄懂项目 | 01 → 02 → 04 第 1–5 节 → 08 → 13 的陷阱 26、33 |
| 要改引擎（`engine/`） | 10 → 04 第 6–7 节 → 15 → 05 → 16 → 13 第 1、2 节 → 09 |
| 要改界面或应用逻辑（`modern_UI/`） | 03 → 04 第 2–5 节 → 07 → 11 → 12 第 4–5 节 → 13 第 5、6 节 |

## 范围

本知识库只覆盖 **macOS 产品**：`modern_UI/Spektrafilm/`（应用）和 `engine/`（共用的 C++ 引擎，只写 Metal 路径）。以下内容属于 Windows/Linux 版本，不在范围内：

- `engine/` 里的 Vulkan 后端（`src/gpu/vulkan_gpu.cpp`、`src/shaders/vulkan/`）、LibRaw 解码（`src/io/`）、`host/`、CMake 与 `build-*.sh`/`*.ps1`；
- `windows_UI/`：基于 Qt Quick 的 Windows 原生前端；
- `desktop/`：基于 Tauri 的 Linux/Windows 前端，配合 `spektralab-host` 宿主进程。

## 关联项目

| 项目 | 关系 |
|---|---|
| [spektrafilm](https://github.com/andreavolpato/spektrafilm)（Python） | 上游。物理模型、28 个彩色配置和印放查找表的来源；一致性校验的参考答案；重新烘焙 `engine/resources/` 的唯一途径。本地约定路径 `~/Documents/Summer 2026/spektrafilm`。相机测试图片也在它的 `tests/` 里 |
| SpektraLab_mobile | 移动端仓库。片边与数据背（RFC-031、RFC-032）的条文最先写在那里，再同步到本仓库的 API-SPEC §13；线上协议改动要在下次同步时带过去（`AGENTS.md`） |
| 本仓库的 Windows/Linux 部分 | 见上一节，不在范围内 |

## 与英文文档的已知出入

生成知识库时发现以下不一致，知识库一律按代码写。英文文档本身没有修改。

| 事项 | 英文文档的说法 | 代码 / 实际情况 | 知识库位置 |
|---|---|---|---|
| 当前版本 | `ARCHITECTURE.md`：1.3.0（2026-10-04）；`AGENTS.md`：1.1.1 + main（2026-09-26） | 1.3.3，构建号 18（`Tools/gen-project.py` 第 83–84 行），标签 `spektralab-v1.3.3` | [01](./01-project-overview.md) |
| 完整测试规模 | README、`ARCHITECTURE.md`：约 550；`AGENTS.md`：约 430；`modern_UI/Spektrafilm/README.md`：139 | 67 个测试类、561 个 `func test` | [12](./12-build-test-release.md) |
| 完整测试耗时 | 约 6 分钟 / 约 350 s / 约 420 s / 375 s | 本次未运行 | [12](./12-build-test-release.md) |
| 引擎资源查找顺序 | `AGENTS.md` 陷阱 14：先应用包，再环境变量，再源码树 | 先环境变量 `SPEKTRAFILM_ENGINE_RESOURCES`，再应用包，再源码树（`EngineClient.swift` 第 221–239 行） | [05](./05-engine-boundary.md)、[13](./13-traps.md) |
| 一致性校验数量 | `ARCHITECTURE.md`：7 个；`AGENTS.md`：6 个 | 目录里 7 个 `parity_*.py`，其中 `parity_exposure.py` 自 2026-09-17 起跑不通 | [16](./16-parity.md) |
| 导出色彩空间 | `Export/Exporter.swift` 文件头注释：成品是 Display P3、打 P3 标签 | 实际按配方的色彩空间做输出变换（`ColourManagement`、`SoftProof`）；注释过时 | [04](./04-render-flow.md) |
| 黑白颗粒 | `AGENTS.md`：没有每款胶片单独的颗粒量 | `FilmParams.ownGrain(of:)` 按胶片给系数 | [11](./11-film-edge-pairs-bw.md) |
| 放大机开关 | `FeatureFlags.enlarger` 注释：控制 Enlarger 分区 | 没有任何引用，Enlarger 分区总是显示 | [03](./03-core-modules.md) |
| GPU 提交次数 | `gpu.hpp` 文件头：21 个节点是一次提交 | `SPK_NODE` 每个节点后都 flush | [15](./15-engine-gpu-and-memory.md) |
| 并发 | `capabilities_json` 注释：不同档位的渲染持不同的锁 | `render_tier` 持整个会话的锁 | [05](./05-engine-boundary.md) |
| 打包脚本 | `ARCHITECTURE.md` §5：没有 Developer ID 时以 1 退出 | 脚本文件头：仍会生成 DMG，最后提示 ad-hoc 签名（未运行核实） | [12](./12-build-test-release.md) |
| README 章节 | `AGENTS.md` 说步骤见 README 的「Parity harnesses」「Rebaking the engine resources」 | 当前 `README.md` 没有这两节 | [16](./16-parity.md) |
| 配置数量 | README："28 个配置 + 4 个新黑白配置" | 28 个彩色 + 5 个产品自带（4 款黑白胶片 + 1 款相纸），应用包内共 33 个 | [01](./01-project-overview.md) |
| RFC 状态 | RFC-013、015、019、020、023 文件头写"未实现 / 无界面" | 代码表明已全部或部分落地 | [14](./14-rfc-index.md) |
| CONTRACT 画布转换 | CONTRACT §1.2："画布转换到 Display P3" | 画布打 ProPhoto 标签，由 ColorSync 转换 | [05](./05-engine-boundary.md) |

## 维护说明

- 最后更新日期：2026-10-12
- 基于提交：`01d32a2`（main），产品版本 1.3.3（18）
- 验证方式：所有事实对照代码读取或 grep 得到；**未运行任何构建或测试**，表中耗时、性能数字均引自英文文档的实测记录。
- 增量更新时，按 knowledge-base 规范的改动映射表只改受影响的文档，并更新本节日期和基线提交。
