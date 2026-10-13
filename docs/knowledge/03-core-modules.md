# 03 核心模块

> 用途：逐个说明应用和引擎的模块职责、两层参数的分工、界面上每个控件改动的代价，以及功能开关。要改某块代码时，先在这里找到它属于哪个模块、牵动哪一层。

## 1. 应用模块（`modern_UI/Spektrafilm/Spektrafilm/`）

| 目录 | 文件数 | 职责 | 关键文件 |
|---|---|---|---|
| 根目录 | 1 | `@main` 入口：判断启动方式是窗口、`cli` 还是 `mcp`；场景、菜单、截图模式 | `SpektrafilmApp.swift` |
| `Model/` | 20 | 全部状态与数据模型 | `Session.swift`（约 5200 行，中心状态）、`Session+FilmEdge.swift`、`Params.swift`（Layer 1 线上字段）、`Adjustments.swift`（Layer 2）、`Geometry.swift`、`Sidecar.swift`、`SettingsClipboard.swift`、`StockCatalog.swift`、`FeatureFlags.swift`、`FilmEdge.swift`、`HalfFramePair.swift`、`Latitude.swift`、`ToneMask.swift`、`Mask.swift`、`FrameOrder.swift`、`CachePolicy.swift`、`DecodeResidency.swift`、`CurveMath.swift` |
| `Service/` | 4 + 桥接头 | 与引擎的边界 | `EngineClient.swift`（actor，唯一调用 `spk_*` 的地方）、`Methods.swift`（线上类型和 `Method` 枚举）、`RenderScheduler.swift`（合并参数编辑）、`EngineMessage.swift`（把引擎错误改写成用户能看懂的话）、`Spektrafilm-Bridging-Header.h` |
| `Import/` | 5 | 解码与素材库 | `ImageDecoder.swift`（Core Image 双解码）、`FramePipeline.swift`（串行解码管线）、`Library.swift`（打开文件或文件夹）、`PairComposer.swift`（半格合成解码）、`ThumbnailCache.swift`（读内嵌预览做缩略图，不经过引擎） |
| `Canvas/` | 10 + `Shaders.metal` | Metal 画布 | `Renderer.swift`（按需绘制：Layer 2 → 直方图 → 几何采样）、`MetalCanvasView.swift`、`TextureStore.swift`（打印与源纹理缓存，向 `MemoryArena` 登记）、`ViewportState.swift`、`ColourManagement.swift`（输出变换）、`CineonLUT.swift`（数字中间片 DI 用的 `.cube`）、叠加层 `CropOverlay`/`MaskOverlay`/`CompareOverlay`/`PairOverlay` |
| `Export/` | 4 | 导出 | `ExportPage.swift`（导出页 UI 和批量循环 `run()`）、`ExportRecipe.swift`、`Exporter.swift`（ImageIO 写文件）、`SoftProof.swift` |
| `Agent/` | 7 | 命令行（CLI）与 MCP（Model Context Protocol，模型上下文协议）服务端（设计记录 RFC-026） | `AgentTools.swift`（唯一的工具表）、`AgentCLI.swift`、`MCPServer.swift`、`AgentWorkspace.swift`、`AgentSchema.swift`、`AgentAccess.swift`（开关与安装脚本）、`JSONValue.swift` |
| `Diagnostics/` | 9 | 日志、内存、缓存 | `LogCore.swift`、`LogFile.swift`、`JobLog.swift`、`Diagnostics.swift`（诊断设置）、`MemoryArena.swift`、`MemorySampler.swift`、`DiskCacheStore.swift`、`PrintWriteback.swift`、`DiagnosticBundle.swift` |
| `Panels/` | 4 + `Sections/` 14 | 左右栏、胶片条、各分区 | `LeftPanel.swift`、`RightPanel.swift`、`Filmstrip.swift`、`CropMaskedThumbnail.swift`；`Sections/*Section.swift` |
| `Controls/` | 13 | 通用控件 | `ScrubSlider`、`DetentSlider`、`ColorWheel`、`CurveEditor`、`HistogramView`、`SectionHeader`/`SectionLayout`、`PanelResize`、`FormatPicker`、`SegmentedSwitch`、`WhiteBalanceRows`、`FlowLayout`、`BeforeAfterIcon` |
| `Windows/` | 10 | 窗口与全局交互 | `EditorWindow`、`BootWindow`、`AboutWindow`、`SettingsWindow`、`AgentsSettingsPage`、`ExportWindow`、`TopBar`、`TrafficLights`、`CollapseTab`、`TypingKeyGuard`（打字键优先给文本框，陷阱 32） |
| `Localization/` | 2 | 英文与简体中文 | `Strings.swift`（一张 Swift 字符串表，用 `L(_:)` 查找，切换语言无需重启）、`Localization.swift`（语言设置 `ui2.language`）。没有 `.lproj`/`.xcstrings`；枚举显示名保持英文 |
| `Theme/` | 1 | 设计 token、尺寸 | `Theme.swift` |
| `Updates/` | 1 | 检查新版本 | `UpdateCheck.swift` |
| `Resources/` | — | 胶片目录、封面、许可证、DI 的两个 `.cube` | `StockCatalog.json`（`Tools/gen-catalog.py` 生成）；`Resources/engine/` 由 `engine/build.sh bundle` 同步 |

测试目标 `SpektrafilmTests/` 是独立目标（没有 TEST_HOST），把应用源码和引擎源码一起编译进来（`AGENTS.md`「The app」）。

## 2. 引擎模块（`engine/`）

| 目录 | 职责 | 说明 |
|---|---|---|
| `include/spektrafilm/spk_engine.h` | 全部公开 C 接口 | 29 个函数，见 [06](./06-api-reference.md) |
| `src/core/` | 初始化阶段的主机端数学（float64），不碰 GPU、不碰像素，可单独测试 | 见下表 |
| `src/gpu/` | GPU 抽象与 Metal 后端 | `gpu.hpp`（接口，上层代码不出现 Metal 字样）、`metal_gpu.cpp`（Metal 实现）、`metal_impl.cpp`（metal-cpp 的实现单元）。`vulkan_gpu.cpp` 只用于 Windows |
| `src/shaders/` | Metal 内核源码 | `blur`、`contrast_mask`、`gamut`（CAM16 色貌模型下的色域压缩）、`grain`（颗粒与眩光）、`nodes`（逐点节点）、`overscan`、`scene_latitude`、`util`（基础操作、降采样、输出转换）、`spk_common.h`。由 `build.sh` 编译 |
| `src/pipeline/` | 渲染图、会话、C 接口实现 | `pipeline.cpp/.hpp`（节点序列与阶段表）、`engine.cpp`（C 接口、会话、档位、参数失效规则）、`overscan.cpp`（片边与数据背）、`blur.cpp`、`contrast_mask.cpp`、`scene_latitude.cpp`、`image.hpp`、`strip.hpp`、`timer.hpp` |
| `resources/` | 已烘焙数据（入库） | 见 [02](./02-architecture.md) 第 3.3 节 |
| `resources_product/` | 产品自带黑白数据 | 4 款黑白胶片 + Ilford Multigrade IV RC 相纸、`paper_grades.json`、`neutral_print_filters.json`、`NOTICE.md` |
| `tests/` | 一致性校验与独立检查 | 见 [16](./16-parity.md) |
| `tools/bake_resources.py` | 从上游 Python 重新烘焙 `resources/` | 其余 `tools/windows_*` 属于 Windows |
| `build.sh` | macOS 构建 | 见 [12](./12-build-test-release.md) |

主要源码规模：`pipeline.cpp` 2383 行、`engine.cpp` 2336 行、`overscan.cpp` 2224 行、`metal_gpu.cpp` 1196 行（引擎调研时 `wc` 统计）。

### 2.1 `src/core/` 文件一览

| 文件 | 职责 |
|---|---|
| `blob.{hpp,cpp}` | 映射 `spektrafilm_constants.bin`，按名字取常量（返回 float64） |
| `cam16.{hpp,cpp}` | 输出色域压缩用的 CAM16-UCS 初始化（逐像素部分在 `gamut.metal`） |
| `camera_filters.hpp` | Kodak Wratten 镜头滤镜的透过率表（380–780 nm，5 nm） |
| `colour.{hpp,cpp}` | 基于烘焙数据的色彩变换（移植自 `colour_baked.py`） |
| `curves.{hpp,cpp}` | 密度曲线、DIR 成色剂（显影抑制剂释放型成色剂）、印放曲线变形 |
| `digital_intermediate.{hpp,cpp}` | 数字中间片（RFC-028）的常数：打印密度、Cineon |
| `file_path.hpp` | UTF-8 路径（POSIX 上原样，Windows 上转宽字符） |
| `hanatos.{hpp,cpp}` | Hanatos 光谱上采样查找表，内含输入色域压缩 |
| `json.{hpp,cpp}` | 引擎自带的小型 JSON 解析与输出（无第三方依赖） |
| `latitude_fit.{hpp,cpp}` | 场景宽容度（RFC-023）的主机端拟合 |
| `numeric.{hpp,cpp}` | float64 小向量、小矩阵 |
| `params.{hpp,cpp}` | 参数树、线上字段表 `kFields`、校验、增量应用、`digest` |
| `print_lut.{hpp,cpp}` | 按相纸查找烘焙好的印放+扫描查找表 |
| `printing.{hpp,cpp}` | 每次渲染的放大机常数、印放平衡 |
| `profile.{hpp,cpp}` | 加载胶片/相纸配置 JSON |
| `setup_cache.{hpp,cpp}` | CAM16 与 `tc_lut` 两个初始化缓存 |
| `spectral.{hpp,cpp}` | 光源、放大机滤色片、光谱积分常数 |

### 2.2 引擎参数树（`engine/src/core/params.hpp`）

`struct Params` 的顶层分组：`film` / `print` / `di_paper`（三个配置）、`film_render`（grain、halation、dir_couplers、glare、overscan、date_imprint）、`print_render`（glare、contrast_mask、density_curves_morph、EDR 扩展动态范围）、`camera`（含 scene_latitude、auto_exposure、lens_blur_um、film_format_mm）、`enlarger`、`scanner`、`io`（几何、输出色域压缩、输入输出色彩空间、CCTF 开关、`preview_long_edge`、`scan_film`）、`settings`（条带、颗粒采样器）、`debug`。

线上字段表 `kFields` 从 `params.cpp` 第 39 行开始，每行有名字、点分路径、类型、shoot/print 层、范围、是否 live。字段总数引擎调研时用正则统计为 98 行，**未精确核实**。

## 3. 两层参数：Layer 1 与 Layer 2

来源：`ARCHITECTURE.md` §7.2。

| | Layer 1 | Layer 2 |
|---|---|---|
| 内容 | 胶片、相纸、相机、放大机、场景定位、反差蒙版 | 曝光、曲线、色彩平衡、对扫描结果的白平衡 |
| 在哪算 | **引擎** | **应用里的一个 Metal 内核**（`Canvas/Shaders.metal` 的 `layer2`） |
| 代价 | 默认 2560 预览约 14 ms，原图约 0.12 s | 亚毫秒 |
| 代码入口 | `Session.params` setter → `requestPrint()` | `Session.adjustments` setter → `renderer.layer2 = …` |
| 存储 | `Model/Params.swift` 的 `FilmParams` | `Model/Adjustments.swift` 的 `Adjustments` |

Layer 1 的改动发 `params_delta` 并等像素；Layer 2 的改动从不离开应用。**控件放错层，就是"滑块跟手"和"不跟手"的区别。**

`FilmParams.wire` 是 Layer 1 字段名唯一的定义处，每个字段都标了 `shoot` 或 `print`。`ParamsTests.testWireNamesMatchTheServiceSchema` 和 `engine/tests/parity_schema.py` 固定这些名字：改名会让测试失败，而不是悄悄让每个增量都被引擎拒绝。

Layer 2 调整项（`Model/Adjustments.swift`）：enabled、temperature、tint、exposure（±3 档）、contrast、brightness、saturation、highlights、shadows、blackPoint、whitePoint；master/shadows/midtones/highlights 四个色轮（各有 hue/sat/lum）；暗角 amount/midpoint；曲线。

## 4. 界面与控件改动的代价

来源：`ARCHITECTURE.md` §7.1（v4 布局，2026-09-26），分区顺序对照 `Panels/LeftPanel.swift` 第 23–40 行、`Panels/RightPanel.swift` 第 41–57 行。

| 区域 | 分区（按顺序） | 在哪算 |
|---|---|---|
| 左栏 Film and Print | Navigator · Half-Frame Pair（仅半格对）· Settings Clipboard · Styles（风格，仅 Debug）· Film · Film Edge · Date Back · Print · Crop（半格对时没有）· Enlarger | 引擎；Crop 是几何（见下表），但有片边时裁切进入底片 |
| 右栏 Parameters ▸ Pre-Dev | Latitude · Input / Camera · Film Format · Scene Placement ·（Tone Mask，开关关闭） | 引擎；其中 Camera 的白平衡和镜头校正属于**解码** |
| 右栏 Parameters ▸ Post-Dev | White Balance · Exposure · Curve · Color Balance ·（Masks，开关关闭） | Layer 2，一次绘制 |
| 画布右上角 | 直方图 · 档位标记 | 只读 |
| 底部胶片条 | 每帧一格 | — |

| 改动 | 代价 |
|---|---|
| Camera 的色温、色调、镜头校正 | 重新解码（`CIRAWFilter`），然后渲染 |
| 左栏和 Pre-Dev 的其他控件 | 一个 `params_delta` + 一次渲染 |
| Post-Dev | 一次绘制 |
| 裁切、拉直、90° 旋转、翻转 | 一次绘制：几何在引擎**之后**，`Exporter` 对返回的打印结果应用几何。有片边或数据背时例外，裁切进入底片 |
| 按住空格看原图 | 一次绘制：显示解码结果而不是打印 |

几条容易误解的规则：

- **Film Format 不是元数据。** 格式、方向、长度合成一个数：帧长边的毫米数。引擎用它换算所有微米量，同一张照片标成 35 mm 时颗粒更粗，这是对的。裁切默认不改变它，除非打开 `recalculateEffectsAfterCrop`。
- **三种白平衡在三个阶段**：Camera 的是解码阶段（开尔文）；Post-Dev 的是 Layer 2，作用在扫描结果上；放大机滤色组合是 Solve 解算的对象。两个阶段从不共用一个名字。
- **Latitude** 读的是经过 Scene Placement 曲线之后的场景直方图（`spk_scene_latitude` 的 `placed_fractions`），测不了时会说明原因，而不是显示空白。
- **界面可缩放**（`ui2.interfaceScale`），标签列随字号缩放。

## 5. 设置剪贴板

`Model/SettingsClipboard.swift` 的 `ClipboardGroup` 共 7 组：`filmAndPaper`、`exposure`、`whiteBalance`、`filmEffects`、`printEffects`、`scenePlacement`、`masks`。

- `masks` 组只在 `FeatureFlags.masks` 或 `FeatureFlags.toneMask` 打开时显示（`ClipboardGroup.offered`，第 25–27 行）。当前两个开关都关，所以界面上是 6 组。
- 勾选状态存在 `ui2.clipboard.groups`。菜单 Copy Settings ⇧⌘C、Paste Settings ⇧⌘V、Sync Settings。
- 裁切、Post-Dev、镜头校正、片边、数据背始终跟随各自照片，不随同步走；As Shot 白平衡和拟合出的 Scene Placement 按目标照片各自解算；同步没有批量撤销（`README.md`）。

### 5.1 风格（PRD/PRD-胶片指南卡片与风格.md §5）

风格是"保存下来的粘贴"：点一下就写到 `pasteTargets`，走粘贴的两条写入路径（`Session.writeSettingsLive` 写画布上那张，可撤销；`Session.writeSettingsOffline` 写其他选中照片的 sidecar 并标记待冲洗）。

- **内置风格**（`Model/Style.swift` 的 `BuiltInStyle.all`，11 个）只写胶片、相纸、扫描与数字中间片的选择、三个效果开关和完整的 `EffectStrengths`，不碰画幅。选胶片走 `FilmParams.choosingFilm(_:in:)`：这是胶片列表的规则（自动配相纸、黑白配黑白相纸、反转片直接扫描）抽成的纯函数，`Session.selectFilmStock` 也调用它，所以离线照片和画布照片结果一致。
- **我的风格**（`UserStyle`）存成 `SettingsClip` 的形态：勾选的分组，加这些分组的字段写在一份空白 sidecar 上，应用时就是一次粘贴。
- **存储**：`Model/StyleStore.swift`，`~/Library/Application Support/SpektraLab/styles.json`，原子写入；读不出的文件先改名为 `styles.unreadable-<时间戳>.json` 再保存，不覆盖。名称去掉首尾空格后不能与内置风格的中英文名或已有风格重名（不分大小写）。
- **测试**：`StyleTests` 用临时路径的 `StyleStore`，不碰用户文件。

### 5.2 胶片指南卡片与场景筛选（同一 PRD，§3–§4）

- 数据全部来自 `StockCatalog.json`，由 `Tools/gen-catalog.py` 合并三处来源：文案与场景标签 `modern_UI/stock_guide.json`（人工）、指标 `modern_UI/stock_traits.json`（`engine/tests/stock_traits.py` 测量生成）、示意图 `modern_UI/stock_art/<id>.svg`（尚未绘制，缺图时画按类型配色的占位图）。
- 指标 5 档在同类（胶片或相纸）实测范围内线性划分，不用分位数：彩色负片颗粒几乎相同，分位数会造出不存在的差别。宽容度只测胶片本身的特性曲线，不经相纸；饱和度用与中灰同亮度的 12 色环，在不裁色域的线性 ProPhoto RGB 下测；相纸统一用 Portra 400（黑白用 Tri-X 400）作参考胶片。方法和改动原因见 `engine/tests/stock_traits.py` 的文件说明。
- 卡片（`Panels/StockCard.swift`）只接收一款胶片和目录，不持有 `Session`，所以不会写参数或触发渲染。悬停 0.5 秒弹出；灰显的相纸行也能弹卡片，所以 `StockRow` 不用 `rowEnabled`，而是保留鼠标、在点击时拒绝。
- 场景筛选只影响显示，状态不保存；当前胶片不属于所选场景时保留并变暗。规则在 `StockCatalog.filmGroups(scene:keeping:)`。

## 6. 功能开关（`Model/FeatureFlags.swift`）

都是编译期常量。除 `scratchPool`、`filmGuide`、`styles` 外，Debug 和 Release 相同；`filmGuide` 和 `styles` 只在 Debug 打开。

| 开关 | 值 | 控制什么 | 何时改 |
|---|---|---|---|
| `masks` | false | 局部蒙版：`Session.syncMasks` 不再把蒙版打包给内核（已有蒙版的 sidecar 照常读写但不生效）、右栏不显示、没有 Mask 菜单 | 等用户自己的蒙版产品需求文档（PRD）落地 |
| `toneMask` | false | RFC-024 反差蒙版（界面叫 Tone Mask）：分区不显示，线上永远发 `contrast_mask_active = false` | 2026-09-29 用户决定先撤下 |
| `enlarger` | false | 注释说是控制左栏 Enlarger 分区 | **代码里没有任何地方引用这个开关**；`LeftPanel` 无条件加入 Enlarger 分区（第 38 行）。开关当前不起作用，原因未核实 |
| `filmGuide` | Debug 为 true | 胶片与相纸的悬停卡片、胶片列表的场景筛选、两个"关于当前胶片 / 相纸"菜单项 | 设计稿确认后进 Release（PRD §9） |
| `styles` | Debug 为 true | 左栏风格分区 | 同上 |
| `blackAndWhite` | true | 黑白胶片和相纸是否出现在目录里 | 1.3.3 起所有构建都打开；等镜头滤镜和相纸号数的控件设计好后删除开关 |
| `framePipeline` | true | 串行解码管线是否接管加载路径 | 真实使用一周无问题后删除 |
| `scratchPool` | Release 恒为 false；Debug 下看环境变量 `SPEKTRAFILM_SCRATCH_POOL=1` | 草稿缓冲池（具体用途未核实） | — |

## 7. 窗口与场景

`SpektrafilmApp.swift` 声明四个 `Window` 场景：`editor`（编辑器，默认 1920×1080，隐藏标题栏）、`about`、`settings`、`export`（`ExportWindowID.scene`）。

设置页**刻意不用** SwiftUI 的 `Settings` 场景：用了它，编辑器窗口永远不会被创建（二分定位过），所以 ⌘, 是在 `CommandGroup(replacing: .appSettings)` 里手写的（`SpektrafilmApp.swift` 第 72–83 行注释）。
