# 06 对外入口索引

> 用途：列出 SpektraLab 的全部对外入口。这个项目没有 HTTP 接口，入口有七种形态：引擎的 C 接口、Swift 侧的方法枚举、命令行（CLI）、MCP（Model Context Protocol，模型上下文协议）工具、菜单与快捷键、启动参数、环境变量。按功能分类，每条注明代码位置。规则与约定见 [05](./05-engine-boundary.md)。

## 1. 引擎 C 接口（`engine/include/spektrafilm/spk_engine.h`，29 个函数）

"应用调用"一列按 `Service/EngineClient.swift` 是否调用统计。

### 1.1 引擎生命周期与能力

| 函数 | 作用 | 输入 → 输出 | 应用调用 |
|---|---|---|---|
| `spk_engine_create(resources_dir, device)` | 加载常量、色彩数据、中性滤色、印放查找表索引，创建 Metal 后端并做快速数学探测 | 路径 + `MTLDevice`（NULL 则自建）→ 句柄 | 是 |
| `spk_engine_destroy` | 销毁引擎及其全部会话 | — | 是 |
| `spk_capabilities` | 能力描述：版本、`render_core`、档位尺寸、`max_pixels`、`concurrent`、setup cache 统计 | → 引擎持有的 JSON | 是 |
| `spk_params_schema` | 全部线上字段的 schema | → 引擎持有的 JSON | 是 |
| `spk_memory_report` | 缓冲池与持久占用的明细（[15](./15-engine-gpu-and-memory.md) 第 4 节） | → 引擎持有的 JSON | 否（测试脚本用） |
| `spk_warm_up(film, print, out_json)` | 在用户看之前付掉某胶片/相纸组合的初始化（`tc_lut` 收缩、`C_max` 二分），幂等（RFC-013 §3） | → JSON（各步骤耗时） | 是（启动窗口期间） |
| `spk_build_info` | 构建标识 `spektrafilm-native 0.1.0 (<日期>, math=safe)` | → 字符串 | 否（经 capabilities 的 `version` 读取） |

### 1.2 会话与参数

| 函数 | 作用 | 输入 → 输出 | 应用调用 |
|---|---|---|---|
| `spk_open(engine, spk_image*, delta, out)` | 用主机 float32 像素（3 或 4 通道）打开一帧 | → 会话句柄 + JSON（会话 id、元数据、检测到的输入、解析后的参数） | 否（测试用） |
| `spk_open_device(engine, spk_device_image*, delta, out)` | 同上，但输入是设备上的 `MTLBuffer`，省掉一次主机拷贝（45 MP 时 727 MB、约 235 ms）；仅 Metal | 同上 | 是 |
| `spk_set_params(session, delta, out)` | 应用参数增量，按需重建流水线、丢弃缓存（[04](./04-render-flow.md) 第 6 节） | → `{"invalidated": "shoot"\|"print", "params"}` | 是 |
| `spk_get_params` | 当前全部参数 | → JSON | 是 |
| `spk_session_release` | 释放会话 | — | 是 |

### 1.3 渲染

| 函数 | 作用 | 输入 → 输出 | 应用调用 |
|---|---|---|---|
| `spk_reprint(session, tier, out)` | 复用缓存底片，只跑印放和扫描 | 档名 → `spk_result`（纹理 +1） | 是 |
| `spk_render(session, tier, out)` | 先丢弃该档缓存底片，强制胶片侧重跑 | 同上 | 是 |
| `spk_result_free` | 释放结果的纹理和像素（Swift 用 `takeRetainedValue` 时**不要**再调用） | — | 否 |
| `spk_cancel(session, progress_id)` | 线程安全；渲染在下一个节点边界退出 | — | 是 |
| `spk_progress(session, progress_id, out)` | 渲染进度、节点计时、本次应用的自动曝光 EV、条带执行报告 | → JSON | 是 |

### 1.4 分析与求解（不渲染）

| 函数 | 作用 | 应用调用 |
|---|---|---|
| `spk_solve(session, target)` | `target` = `exposure`、`filter_pack` 或 `both`；返回 `solved_params` 和顶层的 `exposure_ev_by_method`（四种测光意图） | 是 |
| `spk_scene_latitude(session, request, out)` | 场景宽容度：测量介质边界、场景统计、建议的回拉量、拟合结果（RFC-023，API-SPEC §12） | 是 |
| `spk_contrast_mask_field(session, tier, …)` | 反差蒙版的增量网格（档位），用于画布叠加（RFC-024） | 是 |
| `spk_overscan_geometry(session, out)` | 上一次渲染里各片窗在胶片画布上的四边形（归一化坐标），应用据此定位，不用猜（RFC-032） | 是 |

### 1.5 印放查找表与数字中间片

| 函数 | 作用 | 应用调用 |
|---|---|---|
| `spk_print_lut_catalog` | 8 张烘焙好的印放+扫描查找表的索引（`print_luts.json` 原文） | 是 |
| `spk_print_lut_table(engine, stock, …)` | 一张 (S,S,S,3) float32 表，供写 `.cube` | 是 |
| `spk_preview_stock_lut(session, stock, tier, out, json)` | 用查找表代替重新渲染来切换相纸：45 MP 预热后 live 2.0 ms（重印 9 ms）、full 47 ms（重印 167 ms）；胶片与表烘焙时的胶片不同会返回警告 | 是 |
| `spk_render_digital_intermediate(session, out, json)` | RFC-028 数字中间片：去片基、在胶片自身中性曲线上反转、Cineon log 编码；反转片返回 `SPK_ERR_USER` | 是 |
| `spk_export_di(session, stock, out, json)` | 旧的"DI（数字中间片）包"接口：全分辨率底片按查找表密度轴归一到 [0,1]。应用已于 2026-09-29 弃用，保留给校验脚本和求解器读底片 | 否 |

查找表路径不包含眩光（随机、空间性的光幕无法放进逐点表，误差约为平均绝对值 0.00085 → 0.00177），也不包含反差蒙版。成品打印仍走 `spk_reprint`。

### 1.6 色彩输出

| 函数 | 作用 | 应用调用 |
|---|---|---|
| `spk_output_transform(engine, src_cs, dst_cs, gamut_json, out_json, out_cmax, count)` | 只取数据不碰像素：色适应后的线性矩阵、两种传递函数模式、目标空间的 CAM16-UCS（CAM16 色貌模型的均匀色彩空间）参数和 `C_max` 表。未知空间返回 `SPK_ERR_USER`，**不回退**（RFC-018 §5.2） | 是（`Canvas/ColourManagement.swift`） |

### 1.7 字符串与错误

| 函数 | 作用 |
|---|---|
| `spk_string_free` | 释放任何 `out_json` |
| `spk_last_error(engine)` | 当前线程的最后错误，从不为 NULL，没有错误时为 `""` |

## 2. Swift 侧方法枚举（`Service/Methods.swift` 第 311–319 行）

`enum Method` 共 14 个值，按旧服务的线上名编码。`EngineClient.call` 处理返回 JSON 的方法，`EngineClient.render` 处理返回纹理的方法；用错会抛 `needsRenderPath` / `needsFrame`。

| 值 | 线上名 | 调用的 C 函数 | 走哪个入口 |
|---|---|---|---|
| `capabilities` | `capabilities` | `spk_capabilities` | `call` |
| `paramsSchema` | `params_schema` | `spk_params_schema` | `call` |
| `warmUp` | `warm_up` | `spk_warm_up` | `call` |
| `open` | `open` | `spk_open_device` | `open(_:paramsDelta:)`，需要 `EngineFrame` |
| `getParams` | `get_params` | `spk_get_params` | `call` |
| `setParams` | `set_params` | `spk_set_params` | `call` |
| `solve` | `solve` | `spk_solve` | `call` |
| `progress` | `progress` | `spk_progress` | `call` |
| `cancel` | `cancel` | `spk_cancel` | `call` |
| `previewRender` | `preview_render` | `spk_set_params`（有增量时）+ `spk_render` | `render` |
| `reprint` | `reprint` | `spk_set_params`（有增量时）+ `spk_reprint` | `render` |
| `export` | `export` | 同 `reprint`（full 档） | `render` |
| `previewStockLUT` | `preview_stock_lut` | `spk_preview_stock_lut` | `render` |
| `digitalIntermediate` | `digital_intermediate` | `spk_render_digital_intermediate` | `render` |

`EngineClient` 另有不经 `Method` 的直接方法：`printLUTCatalog`、`printLUTTable`、`outputTransform`、`previewStockLUT`、`renderDigitalIntermediate`、`sceneLatitude`、`renderLayers`（半格对：一次 actor 调用里把同一张底片最多印放三次）、`overscanGates`、`contrastMaskField`、`open`（`EngineClient.swift` 第 424–632 行）。

`close` 刻意没有。CONTRACT §1.1 冻结的 15 个方法里，`export_di` 和 `configure_transport` 在 Swift 侧没有对应值：前者已弃用，后者属于旧的 stdio 传输。

`RenderRequest.tier` 默认 `"live"`。

## 3. 命令行（`Agent/AgentCLI.swift`）

调用方式：`SpektraLab cli <命令> …`，或安装后的 `spektralab <命令> …`（`~/.local/bin/spektralab`，在「设置 ▸ Agents」里安装）。**访问开关关闭时一切命令都被拒绝。**

| 命令 | 参数 | 作用 | 对应 MCP 工具 |
|---|---|---|---|
| `help` / `-h` / `--help` | — | 打印用法 | — |
| `status` | — | 访问开关是否打开、应用在哪 | — |
| `schema` | — | 所有可编辑字段及其范围 | `get_schema` |
| `stocks` | — | 胶片和相纸 id | `list_stocks` |
| `recipes` | — | 导出配方名 | `list_recipes` |
| `info <file>` | — | 描述一张图 | `describe_image` |
| `get <file>` | — | 它的编辑文档 | `get_edit` |
| `edit <file>` | `--patch JSON\|@file\|-`、`[--preview out.jpg]` | JSON merge patch 修改编辑 | `edit_image` |
| `reset <file>` | `[--preview]` | 胶片、相纸、调色、几何恢复默认 | `reset_edit` |
| `process <file>` | `[--preview out.jpg]` | 等同 Process 按钮 | `process_image` |
| `latitude <file>` | — | 胶片和相纸能容纳多少场景 | `measure_latitude` |
| `place <file>` | `--highlight S --shadow S`、`[--preview]` | 通过拟合做 Scene Placement | `place_scene` |
| `preview <file>` | `-o\|--output out.jpg`、`[--long-edge N]` | 成品的 sRGB JPEG | `preview_image` |
| `export <file>` | `[--recipe NAME] [--to DIR]` | 按配方导出 | `export_image` |
| `mcp` | — | 在 stdio 上提供 MCP 服务 | — |

- 输出：stdout 上一个 JSON 对象，含 `ok`；失败时有 `refused`（布尔）和 `error`。
- 退出码：**0** 完成；**1** 失败（应用自身的问题）；**2** 拒绝（调用方的问题，包括访问开关关闭）。
- `cli`/`mcp` 模式下不创建 `NSApplication`：没有窗口、没有 Dock 图标；文件描述符 1 被重定向到 stderr，真正的 stdout 只留给协议（`SpektrafilmApp.swift` 第 17–36 行）。

## 4. MCP 服务端（`Agent/MCPServer.swift`）

- 传输：stdin/stdout 上按行分隔的 JSON-RPC 2.0；`protocolVersion` "2025-06-18"（客户端提出别的版本时回显客户端的）；请求按顺序逐个处理；整个服务生命周期共用一个 `AgentWorkspace`；stdin 关闭时 `flushSave` 后退出。
- 方法：`initialize`、`ping`、`tools/list`、`tools/call`、`prompts/list`、`prompts/get`（只有一个提示词 `edit_photo`）。
- 错误码：−32700（解析错误）、−32600（无效请求）、−32601（方法不存在）、−32602（参数无效）。**工具本身失败不报 JSON-RPC 错误**，而是返回 `isError: true` 的结果。
- 预览以 base64 的 `image/jpeg` 内容返回。
- 配置示例在「设置 ▸ Agents」页面可复制：`claude mcp add spektralab -- '<可执行文件>' mcp`，以及 Claude Desktop 的 `mcpServers` JSON（`Windows/AgentsSettingsPage.swift`）。

### 4.1 十二个工具（`Agent/AgentTools.swift` 第 37–86 行）

| 工具 | 必填参数 | 作用 |
|---|---|---|
| `get_schema` | — | 每个可编辑字段在编辑文档里的路径、类型、范围、含义。编辑前先读 |
| `list_stocks` | — | 胶片和相纸；胶片的 `declaredPaper` 是默认搭配的相纸；反转片（type positive）是扫描而不是印放 |
| `list_recipes` | — | 用户的导出配方 |
| `describe_image` | `path` | 尺寸、是否 RAW、相机白平衡、EXIF、当前胶片和相纸、是否已处理 |
| `get_edit` | `path` | 当前编辑文档 `{params, adjustments, geometry, decode}` |
| `edit_image` | `path`、`patch` | JSON merge patch；未知键、只读字段、越界值整体拒绝，什么都不写；可选 `preview` |
| `reset_edit` | `path` | 恢复默认，解码设置（白平衡、镜头校正）保留 |
| `process_image` | `path` | 冲洗、测光、解算滤色组合，重置 Y/M 偏移。判断色彩前先做一次 |
| `measure_latitude` | `path` | 介质边界（相对中灰的档数）、超出部分的比例、引擎建议的回拉量 |
| `place_scene` | `path`、`highlight`、`shadow`（0–6 档） | 通过引擎拟合做 Scene Placement；拟合拒绝就不应用；都为 0 则移除 |
| `preview_image` | `path` | sRGB JPEG，`long_edge` 64–4096，默认 1024；可选 `output` 另存 |
| `export_image` | `path` | 用某个配方（默认第一个）导出，可选另指 `folder`；返回写出的文件 |

调用前的检查（`AgentTools.call`）：访问开关 → 工具名存在 → 批量导出期间只放行前三个只读工具 → 不认识的参数和缺失的必填参数直接拒绝 → `edit_image` 的补丁在打开图片之前就先校验。

## 5. 菜单与快捷键（`SpektrafilmApp.swift` 的 `EditorCommands`）

| 菜单 | 项目 | 快捷键 |
|---|---|---|
| 应用 | About SpektraLab；Settings… | ⌘, |
| File | Open…；Export… | ⌘O；⌘E |
| Edit | Undo | ⌘Z |
| Edit | Copy Settings；Paste Settings | ⇧⌘C；⇧⌘V（普通 ⌘C/⌘V 留给系统剪贴板） |
| Edit | Select All Photos；Sync Settings | ⌘A；— |
| View | Zoom In / Out | ⌘+ / ⌘− |
| View | Zoom to Fit / 100 % | `,` / `.`（无修饰键） |
| View | Toggle Side Panels；Toggle Filmstrip | ⌘B；⇧⌘F |
| View | Bypass / Restore Adjustments | ⇧⌘B |
| View | Before / After | Y |
| View | Restart Render Service | ⌥⌘R |
| Frame | Previous / Next | ← / → |
| Frame | New Half-Frame Pair | ⌘J |
| Frame | Reset Film, Paper, Camera and Enlarger；Reset Adjustments；Reveal Settings in Finder | — |
| Crop | Rotate Left / Right | ⌥⌘[ / ⌥⌘] |
| Crop | Flip Horizontally / Vertically；Reset Crop | — |
| Tool | Select / Hand / Crop | V / H / C |
| Mask | 仅当 `FeatureFlags.masks` 打开时出现 | ⇧M 等 |

裁切工具里缩放项变灰（`Session.zoomLocked`）。单键快捷键在文本框里打字时不会触发，由 `Windows/TypingKeyGuard.swift` 保证（陷阱 32，`ARCHITECTURE.md` §7.10）。

## 6. 启动参数

| 形式 | 作用 | 位置 |
|---|---|---|
| `SpektraLab <文件路径>…` | 不以 `-` 开头且存在的路径会被打开 | `AppDelegate.openCommandLineArguments` |
| `SpektraLab cli …` / `SpektraLab mcp` | 见第 3、4 节 | `SpektraLabEntry.main` |
| `--snapshot WxH out.png` | 截图模式：在独立的无边框窗口里渲染并写 PNG，然后退出 | `SnapshotRequest.parse`、`AppDelegate.runSnapshot` |

截图模式的附加参数：`--open <路径>`、`--wait <秒>`（默认 1.5）、`--folded left|right|both`、`--zoom`、`--geometry x,y,w,h,angle[,turns]`、`--mask kind,exposure[,overlay]`、`--compare [pos]`、`--original`、`--export`、`--export-grid`、`--settings general|rendering|memory|diagnostics|agents`、`--film-edge`、`--date-back`、`--pair-layer film|left|right`、`--pair-zoom f s`。截图前会清除 `ui2.section.*` 和 `ui2.exportSettingsCollapsed`，并强制标准栏宽。用法见 [12](./12-build-test-release.md)。

## 7. 环境变量

只列 macOS 产品会读的（`vulkan_gpu.cpp` 的 `SPEKTRAFILM_VULKAN_*`、`SPEKTRAFILM_TRANSFER_TIMINGS` 属于 Windows）。

| 变量 | 读取方 | 作用 |
|---|---|---|
| `SPEKTRAFILM_ENGINE_RESOURCES` | `EngineClient.defaultResources` | 指定引擎资源目录，**优先于应用包内资源**。用于让校验脚本或应用读已构建 `.app` 里的资源 |
| `SPEKTRAFILM_CANVAS_LOG=1` | `Canvas/Renderer.swift`、`Session`、`EngineClient` | 每次绘制一行日志，外加打开路径各阶段耗时、`core=…`、`full render … landed` |
| `SPEKTRAFILM_NODE_TIMINGS` | `engine.cpp` `render_tier` | 逐节点等待 GPU 并记录真实耗时（否则只测编码时间） |
| `SPEKTRAFILM_IDLE_TRIM_SECONDS` | `metal_gpu.cpp` | 空闲回收阈值，默认 60，0 关闭；解析失败退回 60 |
| `SPEKTRAFILM_TEST_PRESSURE=warn\|critical` | `metal_gpu.cpp` | 测试缝：每个帧边界投递一次模拟内存压力事件 |
| `SPEKTRAFILM_PLANE_DIR` | `metal_gpu.cpp` | 文件映射缓冲的临时目录 |
| `SPEKTRAFILM_SCRATCH_POOL=1` | `Model/FeatureFlags.swift` | 仅 Debug 构建：打开 `scratchPool` |
| `SPEKTRAFILM_MASK_GUIDED`、`SPEKTRAFILM_MASK_POINTWISE`、`SPEKTRAFILM_MASK_DUMP` | `engine/src/pipeline/contrast_mask.cpp` | 反差蒙版的研究用开关（引导滤波基底、逐点分支、导出蒙版数据），产品不用 |
