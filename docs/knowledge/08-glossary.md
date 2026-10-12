# 08 术语表

> 用途：统一本知识库和代码里的术语，消除歧义。标 ★ 的是本项目特有的内部术语，外部资料里查不到或含义不同。各篇文档使用的术语以这里为准。

## 1. 系统与架构

| 术语 | 全称 / 含义 | 说明 |
|---|---|---|
| spektrafilm | 上游开源项目（Python） | 物理模型与配置数据的来源，作者 Andrea Volpato。本仓库不含它的代码 |
| 参考实现 / oracle ★ | 上游 spektrafilm 的 Python 包 | 一致性校验时作为"标准答案"；运行时不存在。见 [16](./16-parity.md) |
| 引擎（engine） | `engine/` 下的 C++20 渲染引擎 | 编译进应用二进制，不是独立进程 |
| C 接口 / C 二进制接口（ABI） | `engine/include/spektrafilm/spk_engine.h` 中的 `extern "C"` 函数 | 共 29 个 `spk_*` 函数，见 [06](./06-api-reference.md) |
| 线上协议（wire）★ | 跨越应用与引擎边界的字段名、方法名、档位名、版本号 | 历史上是 stdio JSON-RPC，现在是 C 接口里的 JSON；名字改动即协议改动。见 [05](./05-engine-boundary.md) |
| `params_delta` | 参数增量 JSON | 只含要改的字段；`spk_open`/`spk_set_params` 接收 |
| `Session`（应用） | `modern_UI/Spektrafilm/Spektrafilm/Model/Session.swift` | 应用的全部状态，`@MainActor @Observable`，所有视图只绑定它 |
| `spk_session`（引擎） | `engine/src/pipeline/engine.cpp` 中的结构体 | 引擎侧一次打开的帧：源图、参数、流水线、各档缓存 |
| `EngineClient` | `Service/EngineClient.swift` 中的 actor | Swift 侧对 C 接口的唯一封装 |
| 三个入口（front doors）★ | 窗口、`SpektraLab cli`、`SpektraLab mcp` | 同一个二进制、同一个 `Session`（RFC-026） |
| capabilities | `spk_capabilities` 返回的能力描述 JSON | 含版本号、`render_core`、档位尺寸、缓存统计 |
| `render_core` | 能力描述里的渲染核心标识 | macOS 上只可能是 `native-metal`；日志里 `core=native-metal` 是排查第一步 |
| `transport_version` / `schema_version` | 传输版本 / 参数结构版本 | 目前都是 1，见 [05](./05-engine-boundary.md) |

## 2. 渲染与参数

| 术语 | 全称 / 含义 | 说明 |
|---|---|---|
| Layer 1 ★ | 引擎层参数 | 胶片、相纸、相机、放大机、场景定位等；改动要发 `params_delta` 并等引擎出图 |
| Layer 2 ★ | 应用内调色层 | Post-Dev 的曝光、曲线、色彩平衡等；由应用自己的 Metal 内核做，不经过引擎，亚毫秒级 |
| shoot 层 / print 层 ★ | 线上字段的两类标签（`ParamLayer`） | shoot 层字段改动要重新"冲洗"底片；print 层字段只需从缓存底片重印。见 [04](./04-render-flow.md) |
| live 字段 ★ | 可直接写进现有流水线的 print 层字段 | `core/params.cpp` 的 `is_live`：`print_exposure`、`m_filter_shift`、`y_filter_shift`、`preflash_exposure`、`filter_shift_scale` 及三个条带设置；其余字段改动要重建流水线 |
| 渲染档位（tier）★ | `live` / `preview` / `full` | 按长边像素：live 默认 1600（应用按预览分辨率覆盖，默认 2560），preview 3400，full 为原图。名字属于线上协议，不能改 |
| 预览分辨率 | 应用设置 `ui2.previewLongEdge` | 3840 / 2560（默认）/ 1920 / 1080，作为 `io.preview_long_edge` 发给引擎，决定 live 档尺寸 |
| 全分辨率渲染（Original / full render）★ | 编辑停下 400 ms 后的一次 full 档重印 | 落地时日志写 `full render WxH landed in N ms`，画布右上角显示 `full` 标记 |
| 底片缓存（negative）★ | 胶片侧输出的 CMY 密度图 | 每档一份，存在 `spk_session::TierState.negative`；print 层改动从它重印 |
| 重印（reprint）★ | `spk_reprint`：复用缓存底片，只跑印放和扫描 | 拖印放滑块走这条路 |
| 重新冲洗（render / preview_render）★ | `spk_render`：丢掉缓存底片，胶片侧重跑 | shoot 层改动走这条路 |
| 节点（node） | 流水线里一个物理效应对应的一步 | 名字沿用参考实现，如 `filming.develop.grain`。参数使其为恒等时被跳过 |
| 阶段（stage）★ | 连续若干节点的分组 | 分 Pointwise（逐点）、Neighbourhood（邻域）、Whole（整帧）三类，见 [04](./04-render-flow.md) |
| 条带执行（striped）★ | 把逐点和邻域阶段按行分条执行，以降低内存峰值 | `settings.striped`；邻域阶段需要 halo（上下额外行） |
| 冲洗（develop）★ | 应用第一次把线性解码交给引擎：`spk_open_device` → `solve(exposure)` → `reprint(live)` | `Session.ensureDeveloped` / `openInService`；打开一帧只到解码为止，冲洗按需发生 |
| 印放（printing）/ 扫描（scanning） | 流水线的后两段：底片经放大机印到相纸、相纸（或反转片）被扫描成 RGB | 节点前缀 `printing.*`、`scanning.*` |
| `EngineFrame` | 交给引擎的帧：一块共享 `MTLBuffer` 里的线性 ProPhoto float32 | `ImageDecoder.engineFrame`；引擎只在调用期间借用 |
| 原生专有字段（native-only）★ | 参考实现冻结后新增、Python 里没有的线上字段 | 放在 `preview_long_edge` 之前；`parity_schema.py` 的 `NATIVE_ONLY` 精确列出 |
| 打印戳（print stamp）★ | 一张打印结果对应的参数与取景摘要 | `Session.printStamp`；同参数不同取景就是另一张画 |
| 档位标记（badge） | 画布右上角的 `preview` / `full` 标记 | `Session.canvasBadges`；`full` 表示原分辨率已上画布 |
| `LoadClock` ★ | 打开路径的计时器 | 日志 `open path (ms): …`，**不要删** |
| 测光（meter） | 自动曝光的测量 | 每帧在 1600 px 缩图上测一次，各档共用同一 EV（RFC-015 P.1） |
| Solve | `spk_solve`：解算曝光补偿和/或放大机滤色组合 | target 为 `exposure`、`filter_pack`、`both` |
| Process ★ | 界面上的处理按钮，也是 agent 工具 `process_image` | 冲洗、测光、解算滤色组合，并重置 Y/M 滤色偏移 |
| 滤色组合（filter pack） | 放大机的 C/M/Y 滤色值，单位 CC | 中性值约 55/65；应用发 `filter_shift_scale` = 40（API-SPEC §14） |
| `product_defaults` ★ | `spk_open` 增量里的一个键 | 使 `print_exposure_compensation` = false，让相机曝光补偿真的改变相纸亮度（`engine.cpp`） |
| generation ★ | 防过期结果的代数计数器 | `RenderScheduler` 和全分辨率渲染都用它，结果代数对不上就丢弃并记 `superseded` |
| setup cache ★ | 引擎级初始化缓存（`core/setup_cache.hpp`） | CAM16 的 `C_max` 表和 Hanatos `tc_lut`，见 [15](./15-engine-gpu-and-memory.md) |

## 3. GPU 与内存

| 术语 | 全称 / 含义 | 说明 |
|---|---|---|
| 五个动词 ★ | GPU 接口的 alloc/upload、dispatch、flush、read、texture | `engine/src/gpu/gpu.hpp` |
| `BufferRef` | 引用计数的缓冲句柄 | 最后一个句柄释放时缓冲回池 |
| 空闲且无在途命令（free and idle）★ | 池化缓冲可以复用的两个条件 | 句柄全部释放，且最后引用它的命令缓冲已执行完；见 [15](./15-engine-gpu-and-memory.md) 和陷阱 19 |
| pending ★ | 已释放但命令缓冲还没执行完的缓冲 | `flush` 之后才转为可复用 |
| persistent 缓冲 | 不进池的长期缓冲 | 引用归零即销毁；如印放查找表、结果纹理 |
| file-backed 缓冲 ★ | 页面映射到临时文件的持久缓冲 | 用于源图和缓存底片，显著降低 `phys_footprint`（RFC-020 §4.7） |
| halo | 分条带或分块执行时，为邻域运算额外读取的上下行 | 一段连续可分带阶段的 halo 是各阶段之和 |
| `phys_footprint` / `footprint` | macOS 的进程物理内存占用（jetsam 依据它杀进程）/ 查看它的命令 | RSS 看不到 Metal 池，量内存用 `footprint -p <pid>` |
| 空闲回收（idle trim） | 60 秒无渲染后释放缓冲池 | `SPEKTRAFILM_IDLE_TRIM_SECONDS` 可调，0 关闭 |
| `MemoryArena` ★ | 应用侧内存台账（`Diagnostics/MemoryArena.swift`） | 只记账和驱逐，不拥有内存（RFC-019） |
| `DiskCacheStore` ★ | 磁盘缓存（`Diagnostics/DiskCacheStore.swift`） | 存解码结果和成品打印，SQLite 索引，GDSF（Greedy Dual-Size Frequency，贪心双重大小频率）淘汰 |
| `PrintWriteback` ★ | 成品打印写回磁盘缓存的有界队列 | 只在当前帧空闲时排空 |

## 4. 物理模型与色彩

| 术语 | 全称 / 含义 | 说明 |
|---|---|---|
| 查找表（LUT） | Look-Up Table | 本项目有三种：Hanatos `tc_lut`（初始化用）、8 张印放+扫描查找表（快速换相纸、写 `.cube`）、DI 查看用 `.cube` |
| `tc_lut` | 按胶片感光度收缩后的 192×192×3 上采样表 | setup cache 最多保留 4 个 |
| CAM16-UCS | CAM16 色貌模型的均匀色彩空间 | 输出色域压缩在这里做 |
| `C_max` 表 ★ | 目标色彩空间在 CAM16 下每个亮度/色相的最大色度 | 64×720 单元，按输出空间缓存；`spk_output_transform` 交给应用 |
| Cineon | Kodak 的胶片扫描对数编码 | DI 使用：片基在码值 95 |
| 光谱上采样 | 从 RGB 重建光谱 | 用 Hanatos 2025 方法，初始化时把 192×192×81 光谱表按胶片感光度压成 192×192×3 的 `tc_lut` |
| 特性曲线 | 胶片/相纸的密度—对数曝光曲线 | 256 个采样点，对数曝光 −3 到 4 |
| DIR 成色剂 | Development Inhibitor Releasing couplers，显影抑制剂释放型成色剂 | 层间抑制效应，带空间扩散；节点 `filming.develop.dir_couplers` |
| 颗粒（grain） | 胶片银盐/染料云的随机结构 | 默认 `exact` 采样器，同参数可复现 |
| 光晕（halation） | 光线在片基背面反射回乳剂层形成的辉光 | `filming.expose.halation` |
| 眩光（glare） | 相纸上的随机散射光幕 | `scanning.glare`，唯一默认不可复现的阶段（陷阱 1） |
| 放大机（enlarger） | 印相时把底片投到相纸上的设备 | 光谱积分的第一次（印放） |
| 预闪光（pre-flash） | 印相前对相纸做的均匀弱曝光 | `preflash_exposure` |
| 反转片（slide film） | 直接看正片的胶片 | `scan_film` 为真时没有印放阶段 |
| CCTF | Colour Component Transfer Function，色彩分量传递函数 | 即编码/解码伽马；`input_cctf_decoding`、`output_cctf_encoding` |
| ProPhoto RGB / ROMM RGB | 大色域 RGB 空间，γ1.8，D50 | 本项目的工作空间：引擎输出、Layer 2、画布都在这个空间 |
| 工作空间（working space）★ | 引擎输出和调色所在的色彩空间 | 默认 ProPhoto RGB，CCTF 编码；从 `open` 回复的 `params.io` 读取，不要写死 |
| 色域压缩（gamut compression） | `scanning.gamut_compress`，基于 CAM16-UCS | 亮度的 Reinhard 肩部 + 色度拐点；它本身会改变观感 |
| EDR | Extended Dynamic Range，扩展动态范围 | 输出端的高光余量阶段 `scanning.edr` |
| 软打样（soft proof） | 写文件前在屏幕上按目标色彩空间预览 | 与真实导出走同一条链路（`Export/SoftProof.swift`） |
| DI | Digital Intermediate，数字中间片 | RFC-028：去色罩后的 Cineon log 编码负片，16 位 TIFF，不带色彩标签 |
| 打印密度（printing density） | 以相纸感光度度量的底片密度 | DI 的编码基础 |
| 场景宽容度 / Scene Placement ★ | RFC-023 Scene Latitude Mapping | 胶片前的场景映射，把超出材料能力的高光/阴影拉回；界面叫 Scene Placement |
| 反差蒙版（contrast mask）★ | RFC-024 虚拟反差蒙版 | 放大机侧的区域增益；应用里由 `FeatureFlags.toneMask` 控制，默认关闭 |
| `camera_filter` ★ | 镜头前的彩色滤镜 | Kodak Wratten 编号 w8…w58，黑白摄影用（API-SPEC §15） |
| 材质模型原则 ★ | "不要为了修渲染问题去污染材质模型" | 配置描述实测能力，不是调节面板；见 [10](./10-physical-model-and-colour.md) |

## 5. 产品功能

| 术语 | 全称 / 含义 | 说明 |
|---|---|---|
| Film Edge / overscan ★ | 片边：把底片片基、齿孔、片边字一起渲染 | 线上字段前缀 `overscan_`（RFC-032） |
| 片窗（gate） | 相机里限定画面范围的框 | 形状有 square、rounded、eared 等 |
| 片基边（rebate） | 画面外的胶片边缘 | 片边字、帧号印在这里 |
| Date Back / date imprint ★ | 数据背：把日期或拍摄数据曝光到底片上 | 线上字段前缀 `date_imprint_`（RFC-031） |
| 半格双拼（half-frame pair）★ | 两张照片放在一格 135 上 | 文件形态 `.spektrapair`；每张占一个孔位（hole） |
| 孔位（hole）★ | 半格对里一张照片所在的位置 | `Model/HalfFramePair.swift` 的 `Hole`，含 `placement`（缩放、x、y、旋转） |
| `focusSide` ★ | 半格对里当前被选中的那一张 | 右栏控件作用于它；*Frame / + Film* 决定是否连胶片一起改 |
| DX 码 | 135 胶片片边上的条码 | 电影负片装进 135 时没有 DX 码 |
| Wratten 编号 | Kodak 的摄影滤镜编号体系 | `camera_filter` 的取值 |
| Pre-Dev / Post-Dev ★ | 右栏两个页签 | Pre-Dev 是冲洗前（引擎），Post-Dev 是冲洗后（Layer 2） |
| Film Format ★ | 画幅：格式、方向、长度合成一个数（帧长边毫米数） | 引擎用它把微米量换算成像素 |
| Settings Clipboard ★ | 设置剪贴板（RFC-027） | 7 个分组，可复制、粘贴、同步到多张 |
| Sync to N ★ | 把勾选分组同步到选中的 N 张照片 | 无批量撤销 |
| 导出配方（recipe） | 格式、位深、色彩空间、长边、命名、目录的组合 | 存在 `export-recipes.json` |
| `batchExporting` ★ | 批量导出进行中的标志 | 期间禁止任何改变当前帧的操作（陷阱 34） |
| 胶片条（filmstrip） | 底部缩略图条 | 可拖动排序，顺序按文件夹保存 |
| Navigator | 左栏顶部的导航缩略图 | 只显示裁切后的画面 |

## 6. 持久化

| 术语 | 全称 / 含义 | 说明 |
|---|---|---|
| sidecar ★ | 照片旁参数文件 | 现在不在照片旁边，而在 `~/Library/Application Support/SpektraLab/Sidecars/`（陷阱 35） |
| `ui2.*` / `diag.*` | `UserDefaults` 键前缀 | 界面设置 / 诊断设置 |

## 7. 工程与文档

| 术语 | 全称 / 含义 | 说明 |
|---|---|---|
| 一致性校验（parity）★ | 引擎与上游 Python 参考实现逐项对比 | `engine/tests/parity_*.py`，见 [16](./16-parity.md) |
| KNOWN 差异 ★ | 校验脚本里登记在案的有意差异 | 如果两边某天又一致了，校验反而失败 |
| fixture | 测试用的相机原图 | 不在本仓库，经 `tests` 符号链接引入 |
| 冒烟图（smoke frame） | `tests/Test_image/_smoke_1mp.tif`，1 MP | 一致性校验默认用它 |
| metallib | 编译后的 Metal 着色器库 `spektrafilm.metallib` | 由 `engine/build.sh` 生成，不入库 |
| 快速数学探测（math probe）★ | `spk_math_probe` 内核 | 引擎启动时检测 metallib 是否用了快速数学模式，是则拒绝启动 |
| RFC | 设计记录（Request for Comments） | `rfc/` 下，见 [14](./14-rfc-index.md) |
| PRD | 产品需求文档 | `PRD/` 下 |
| ADR | 架构决策记录 | 本知识库 [09](./09-decisions.md) 的格式 |
| 陷阱（trap）★ | `AGENTS.md` 里编号的踩坑记录 | 共 35 条，见 [13](./13-traps.md) |
| `SurfaceAgreementTests` ★ | "每个显示画面的界面都显示画布的画面"的测试 | 新界面要在这里加用例（陷阱 33） |
| `XCTExpectFailure(strict: true)` | 把已知缺陷固定为"预期失败"的 XCTest 写法 | 缺陷修好那天测试变红，提醒去掉标记 |
| `TypingKeyGuard` ★ | 让打字键先到文本框、再到菜单的按键监听 | 陷阱 32 |
| ad-hoc 签名 | 不带开发者证书的本地签名 | 本项目的发布方式；首次运行要去隔离属性 |
