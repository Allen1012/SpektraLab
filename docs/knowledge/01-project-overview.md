# 01 项目概览

> 用途：用一页说清 SpektraLab 是什么、由哪些部分组成、用什么技术栈、各目录负责什么。新人入门先读这篇。

## 1. 项目定位

SpektraLab 是一个 **macOS 胶片与相纸模拟器**：打开一张 RAW，选一款胶片、一款相纸，按物理模型走完"拍摄 → 冲洗负片 → 放大机印相 → 扫描"的整条暗房链路，大约一秒得到一张带颗粒、光晕（halation）、成色剂效应的"相纸照片"。

- 物理模型和 28 个实测彩色胶片/相纸配置来自上游开源项目 [spektrafilm](https://github.com/andreavolpato/spektrafilm)（作者 Andrea Volpato，Python 实现）。
- SpektraLab 把这个引擎**改写成 C++/Metal 原生实现**，再围绕它做了 macOS 应用。另有 5 个产品自带的黑白配置（4 款胶片 + 1 款 Ilford 相纸），作者 Hanze Qiu。
- 来源：`README.md`、`ARCHITECTURE.md` §0。

## 2. 产品能力一览

| 能力 | 说明 | 详见 |
|---|---|---|
| 光谱渲染 | 光线按 380–780 nm、5 nm 一档共 81 个波长计算，穿过胶片和相纸的染料层；不是查找表（LUT）套色 | [10](./10-physical-model-and-colour.md) |
| 物理尺寸 | 按画幅（135、120 等）把颗粒、光晕、成色剂扩散换算到微米 | [10](./10-physical-model-and-colour.md) |
| 胶片与相纸 | 28 个彩色配置 + 5 个黑白配置（`engine/resources/profiles/`、`engine/resources_product/profiles/`） | [11](./11-film-edge-pairs-bw.md) |
| 片边（Film Edge） | 画出片基、齿孔、片边字、帧号；格式从 135 到 6×17 | [11](./11-film-edge-pairs-bw.md) |
| 数据背（Date Back） | 把日期或拍摄数据曝光到底片上 | [11](./11-film-edge-pairs-bw.md) |
| 半格双拼（half-frame pair） | 两张照片放在一格 135 上，每张有自己的曝光、白平衡、印放和调色 | [11](./11-film-edge-pairs-bw.md) |
| 色彩管理 | 全程 ProPhoto RGB 工作空间，导出时只做一次色域映射，写文件前先软打样 | [10](./10-physical-model-and-colour.md) |
| 导出 | JPEG / PNG 8 位 / TIFF 16 位 / 数字中间片（DI，Digital Intermediate）；导出配方；批量导出 | [04](./04-render-flow.md) |
| 设置同步 | 把当前照片的指定分组设置复制或同步到多张照片 | [03](./03-core-modules.md) |
| 可编程 | 命令行（CLI）`spektralab` 和 MCP（Model Context Protocol，模型上下文协议）服务端，与窗口驱动同一个 `Session`；默认关闭 | [06](./06-api-reference.md) |
| 性能 | 45 MP 全分辨率渲染约 0.87 s，预览尺寸重印约 0.01 s（M3 Max 实测，`ARCHITECTURE.md` §8.7） | [15](./15-engine-gpu-and-memory.md) |

## 3. 技术栈

| 层面 | 技术 | 说明 |
|---|---|---|
| 应用语言 | Swift 6.0（`SWIFT_VERSION`，`modern_UI/Spektrafilm/Tools/gen-project.py` 第 269 行） | |
| 界面 | SwiftUI（面板）+ AppKit（窗口、按键）+ Metal（画布） | `ARCHITECTURE.md` §7 |
| 渲染引擎 | C++20（`-std=c++20 -O2`，`engine/build.sh`） | 编译进应用目标，不是独立进程 |
| GPU 内核 | Metal 着色语言（MSL），由 `engine/build.sh` 编译成 `spektrafilm.metallib` | 不由 Xcode 编译，原因见 [09](./09-decisions.md) |
| C++ 访问 Metal | metal-cpp（`engine/third_party/`，Apache-2.0） | |
| 应用与引擎的边界 | 手写的 C 二进制接口（ABI）`engine/include/spektrafilm/spk_engine.h`，29 个函数 | [05](./05-engine-boundary.md) |
| 图像解码 | Core Image（`CIRAWFilter`） | |
| 图像写出 | ImageIO | 引擎从不写文件 |
| 本地存储 | JSON 文件、`UserDefaults`、SQLite（系统 `libsqlite3`，只用于磁盘缓存索引） | [02](./02-architecture.md) |
| 哈希 | CryptoKit（SHA-256） | sidecar 命名、缓存键 |
| 数据库服务 / 消息队列 / 网络服务 | 无 | 单机桌面应用 |
| 构建 | Xcode 26.6 + `engine/build.sh` + `Tools/gen-project.py`（生成 Xcode 工程） | [12](./12-build-test-release.md) |
| 运行时依赖的 Python | 无。Python 只在两处用：`Tools/*.py` 生成器（仅标准库），以及与上游参考实现的一致性校验和资源重新烘焙（需要外部 Python 环境） | [16](./16-parity.md) |

## 4. 目录结构（只列 macOS 产品相关部分）

```
SpektraLab/
├── modern_UI/Spektrafilm/            macOS 应用（Xcode 工程）
│   ├── Spektrafilm/                  应用源码，共 105 个 .swift
│   │   ├── SpektrafilmApp.swift      @main：窗口 / cli / mcp 三个入口的分派
│   │   ├── Agent/          (7)       命令行与 MCP 服务端（设计记录 RFC-026）
│   │   ├── Canvas/         (10)      Metal 画布：Renderer、着色器、色彩管理、各类叠加层
│   │   ├── Controls/       (13)      通用 SwiftUI 控件：滑块、色轮、曲线、直方图
│   │   ├── Diagnostics/    (9)       日志、内存台账、磁盘缓存、打印结果写回
│   │   ├── Export/         (4)       导出页、导出配方、写文件、软打样
│   │   ├── Import/         (5)       解码、串行解码管线、素材库、半格合成、缩略图
│   │   ├── Localization/   (2)       英文 / 简体中文字符串表
│   │   ├── Model/          (20)      Session（中心状态）、线上参数、调整项、几何、sidecar 等
│   │   ├── Panels/         (18)      左右栏、胶片条及各分区
│   │   ├── Service/        (4)       EngineClient（C 接口边界）、RenderScheduler、错误文案
│   │   ├── Theme/          (1)       设计 token
│   │   ├── Updates/        (1)       检查新版本
│   │   ├── Windows/        (10)      编辑器、启动、关于、设置、导出窗口
│   │   ├── Resources/                胶片目录 JSON、封面、许可证文本、DI 用 .cube；
│   │   │                             Resources/engine/ 由 engine/build.sh bundle 同步进来，不入库
│   │   └── Assets.xcassets、SpektraLab.icon
│   ├── SpektrafilmTests/             单元与集成测试：60 个文件、67 个测试类、561 个测试方法
│   └── Tools/                        工程生成、目录生成、截图、打包脚本（见 12）
├── engine/                           C++20 渲染引擎（macOS 与 Windows 共用源码）
│   ├── include/spektrafilm/spk_engine.h   全部 C 接口
│   ├── src/core/                     初始化阶段的数学：色彩、配置、曲线、成色剂、CAM16 色貌模型、Hanatos 查找表、参数表
│   ├── src/gpu/                      gpu.hpp（GPU 抽象接口）+ metal_gpu.cpp（Metal 后端）
│   ├── src/shaders/                  9 个 .metal / .h：blur、contrast_mask、gamut、grain、nodes、overscan、scene_latitude、util
│   ├── src/pipeline/                 渲染节点序列（pipeline.cpp）、会话与 C 接口实现（engine.cpp）、片边、模糊等
│   ├── resources/                    已烘焙的常量、28 个配置、8 张印放查找表（入库，约 15 MB）
│   ├── resources_product/            产品自带的黑白配置与数据
│   ├── tests/                        一致性校验脚本、独立检查脚本、C++ 驱动
│   ├── tools/bake_resources.py       重新烘焙 resources/（需要上游 Python）
│   └── build.sh                      macOS 构建入口
├── ARCHITECTURE.md / AGENTS.md / API-SPEC-*.md / CONTRACT-*.md   英文原始文档
├── rfc/  PRD/  research/             设计记录（RFC）、产品需求文档（PRD）、研究资料
└── license/                          GPL-3.0、CC BY-SA 4.0、Apache-2.0 等许可证文本
```

以下目录属于 Windows/Linux 版本，**不在本知识库范围内**：`engine/src/gpu/vulkan_gpu.cpp`、`engine/src/shaders/vulkan/`、`engine/src/io/`、`engine/src/desktop/`、`engine/host/`、`engine/CMakeLists.txt` 及 `build-*.sh`/`*.ps1`、`windows_UI/`、`desktop/`。

## 5. 模块协作关系

这个项目不是 Controller → Service → DAO 那样的分层结构，而是"三个入口共用一个状态对象，再经一道 C 接口进入引擎"：

```
入口                       应用（Swift，主线程）                  边界              引擎（C++，同一进程）
──────────                 ─────────────────────                ──────            ────────────────────
窗口（SwiftUI/AppKit） ─┐
SpektraLab cli <命令>  ─┼─► Session ──► RenderScheduler ──► EngineClient ──► spk_*() ──► spk_session ──► Pipeline ──► gpu::Gpu ──► Metal
SpektraLab mcp         ─┘     │                              (actor)        C 接口      (engine.cpp)    (pipeline.cpp)  (metal_gpu.cpp)
                              ├─► Renderer（画布、Layer 2 调色内核）
                              ├─► Exporter（ImageIO 写文件）
                              └─► Sidecar / DiskCacheStore / Log（落盘）
```

- 三个入口跑的是同一个二进制、同一个 `Session` 实现，编辑写到同一个 sidecar（`ARCHITECTURE.md` §0、§7.9）。
- 参数以 JSON 跨过边界，像素不走 JSON：输入是共享的 `MTLBuffer`，输出是零拷贝的 `MTLTexture`（[05](./05-engine-boundary.md)）。

## 6. 版本与标识

| 项 | 值 | 来源 |
|---|---|---|
| 产品版本 | 1.3.3 | `modern_UI/Spektrafilm/Tools/gen-project.py` 第 83 行 `MARKETING_VERSION` |
| 构建号 | 18 | 同文件第 84 行 `BUILD_NUMBER` |
| 最新 git 标签 | `spektralab-v1.3.3` | `git describe --tags` |
| Bundle ID | `com.hanze.filmify`（测试目标加 `.tests`） | 同文件第 74 行 |
| 产品名 | SpektraLab；Xcode 目标名和模块名仍是 `Spektrafilm` | 同文件第 53、72 行 |
| 引擎构建标识 | `spektrafilm-native 0.1.0 (<编译日期>, math=safe)` | `engine/src/pipeline/engine.cpp` 的 `spk_build_info` |
| 线上协议版本 | `transport_version` = 1，`schema_version` = 1 | `spk_engine.h` 的 `SPK_TRANSPORT_VERSION`、`SPK_SCHEMA_VERSION` |

## 7. 运行与开发环境

| 项 | 要求 |
|---|---|
| 运行 | Apple 芯片，macOS 15 或更高；一个 arm64 二进制，安装包约 32 MB（`ARCHITECTURE.md` §0、§8.7） |
| 开发 | Xcode 26.6；`python3`（只给 `Tools/*.py` 用，标准库即可） |
| 一致性校验 | 另需上游 spektrafilm 的 Python 环境，通过 `PYTHONPATH` 指过去（[16](./16-parity.md)） |
| 测试图片 | 不在本仓库，通过 git 忽略的 `tests` 符号链接引入（[12](./12-build-test-release.md)） |

## 8. 分发方式

- 从 GitHub Releases 下载，ad-hoc 签名；首次运行需清除隔离属性：`xattr -d -r com.apple.quarantine /Applications/SpektraLab.app`（`README.md`）。
- 打包脚本 `modern_UI/Spektrafilm/Tools/package.sh`：归档 → 导出 → DMG → 公证 → `spctl` 校验（[12](./12-build-test-release.md)）。
- 应用只在用户点击时检查新版本（`Updates/UpdateCheck.swift`，RFC-021）。

## 9. 许可证

| 部分 | 许可证 | 文本 |
|---|---|---|
| 应用和引擎代码 | GPL-3.0-or-later | `license/LICENSE`、`license/SpektraLab-GPL-3.0.txt` |
| 胶片与相纸配置、印放查找表 | CC BY-SA 4.0 | `license/Profiles-and-LUTs-CC-BY-SA-4.0.txt` |
| metal-cpp | Apache-2.0 | `license/metal-cpp-Apache-2.0.txt` |

许可证文本会打进应用包，在「关于 SpektraLab」窗口里显示。构建前检查脚本会在文本缺失时让构建失败，`LicensingTests` 断言它们能被「关于」窗口读到（`AGENTS.md`「The app」一节）。
