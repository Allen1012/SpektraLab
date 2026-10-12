# 04 核心流程：从打开照片到出图

> 用途：给出一张照片从"点开"到"画布上出现相纸效果"再到"导出成文件"的完整调用链，并写清每种编辑会触发什么。应用侧写到调用 C 接口为止，引擎侧写到每个节点和内核。GPU 内存细节见 [15](./15-engine-gpu-and-memory.md)。

## 1. 入口总览

| 入口 | 触发方式 | 处理入口的类 / 函数 | 访问控制 |
|---|---|---|---|
| 打开文件或文件夹 | ⌘O、拖入、命令行参数、Finder 打开 | `Session.open(urls:)`（`Model/Session.swift` 第 1270 行）、`Session.openPanel` | 无 |
| 选中一帧 | 点击胶片条、←/→ | `Session.select(_:)`（第 1458 行） | 批量导出期间禁止 |
| 冲洗（develop） | 第一次需要相纸效果时（改参数、导出、Process） | `Session.requestPrint()`（第 2188 行）→ `ensureDeveloped()`（第 2147 行） | 无 |
| Process / Solve | 按钮、MCP（Model Context Protocol，模型上下文协议）工具 `process_image` | `Session.solveNow()`（第 3884 行） | Agent 开关 |
| 改参数 | 任意滑块、菜单、粘贴、撤销 | `Session.params` / `adjustments` / `decode` / `geometry` / `masks` 的 setter | 无 |
| 导出 | ⌘E 打开导出页；MCP 工具 `export_image`；命令行（CLI）`export` | `ExportPage.run()`、`Exporter.export(...)` | Agent 开关（仅 CLI/MCP） |
| CLI / MCP 调用 | `SpektraLab cli …` / `SpektraLab mcp` | `AgentCLI.run` → `AgentTools.call` → `AgentWorkspace` | `ui2.agentAccess`，默认关闭 |

## 2. 应用侧：打开与冲洗

`Session.swift` 文件头注释（第 1–23 行）的要点：**打开只到解码为止**。冲洗（把线性解码交给引擎）是慢的一半，等到真的有人要看相纸效果时才做。

```
Session.open(urls:)                              打开文件或文件夹（不递归、跳过隐藏文件，Import/Library.swift）
└─ Session.select(url)                           把某帧放上画布
   └─ load(url, generation:)                     第 1909 行；在 FramePipeline 串行队列上执行，新任务使旧任务作废
      ├─ 查磁盘缓存的解码结果（CacheKind.decode）
      ├─ ImageDecoder.decode(...)                 Import/ImageDecoder.swift 第 178 行
      │   └─ CIRAWFilter 解码两次，几何一致（镜头校正同开同关、方向和缩放相同）：
      │      ├─ linear：给引擎，关掉 Apple 全部色调渲染（boostAmount = 0），线性 ProPhoto float
      │      └─ display：画布上的"原图"，不进引擎
      └─ 画布显示 display 解码                      此时还没有相纸效果

Session.requestPrint()                           第 2188 行：引擎还没持有这帧 → 冲洗；已持有 → 交给 scheduler
└─ ensureDeveloped()                             第 2147 行：等解码落地；已在冲洗就加入，不重复冲洗
   └─ develop(url, decoded)                      第 2099 行
      └─ openInService(decoded)                  第 2221 行
         ├─ awaitBoot                            等启动时的 warmUp（spk_warm_up）完成，引擎版本号才确定，缓存键才正确
         ├─ noteProjection / filmEdgeRefusal     先预估内存；片边模式下超出纹理上限的帧直接拒绝
         ├─ Task.detached：engineImage(cut:) → PairComposer.exposed（半格对）→ ImageDecoder.engineFrame
         │   └─ 用 Core Image 把线性解码渲染进一块共享 MTLBuffer（45 MP 时 727 MB）
         ├─ client.open(frame, openDelta)        EngineClient → spk_open_device（引擎只在调用期间借用这块缓冲）
         │   └─ openDelta = sidecar 全部参数 + preview_long_edge + product_defaults: true（第 1790–1795 行）
         ├─ MemoryArena.registerPinned(engine)   给引擎占用记账
         ├─ noteWorkingSpace(params.io.output_color_space)   从回复里读工作空间，不假设（陷阱 28）
         ├─ scheduler.reset(sessionID, params: opened)       generation + 1
         ├─ client.call(.solve, target: "exposure")          测光基线 → sidecar.solvedEV、exposureEvByMethod
         ├─ client.render(.reprint)               tier 默认 "live"（Service/Methods.swift RenderRequest）
         ├─ applyRender(...)                     第 2394 行：generation 不符就丢弃；否则上画布，并安排全分辨率渲染
         └─ scheduler.request(sidecar.params)    冲洗期间用户又动了滑块？把差异补发
```

**Process / Solve 按钮**（`solveNow`）：`ensureDeveloped()` → `spk_solve(target: "both")`（自动曝光 + 放大机滤色组合），把 Y/M 滤色偏移清零，然后 `scheduler.reset` 重开一代（`Session.swift` 第 3884–3931 行）。冲洗本身只做 `exposure`，`both` 只在按 Process 时做。

## 3. 五类编辑如何分流

| 编辑 | setter（`Session.swift`） | 立即动作 | 走到引擎的路径 | 代价 |
|---|---|---|---|---|
| `params`（Layer 1） | 第 110–120 行 | `pushUndo` → `filmEdgeWillChange` → 写 sidecar → `requestPrint()`、`markStale()`、`scheduleSave()` | `RenderScheduler` → `spk_set_params` + `spk_reprint` 或 `spk_render` | print 层约 10 ms 级；shoot 层要重跑胶片侧 |
| `adjustments`（Layer 2） | 第 121–138 行 | `renderer.layer2 = uniforms`；曲线变了 `setCurves`；`scheduleSave()`。半格对改走 `recomposePair()` | **不经过引擎** | 一次绘制 |
| `decode`（相机白平衡、镜头校正） | 第 139–152 行 | 写 sidecar → `scheduleSave()` → `scheduleReopen()`（350 ms 防抖） | 重新解码，再 `spk_open_device` 一个新会话 | 解码 + 冲洗 |
| `geometry`（裁切、旋转、翻转） | 第 156–181 行 | `renderer.geometry = canvasGeometry`；`scheduleSave()` | 默认**不经过引擎**，几何在打印结果之后应用。只有片边或数据背让裁切进入底片时（`geometryIsInTheNegative`），且不在裁切工具中，才 `requestPrint()` | 一次绘制；或一次冲洗 |
| `masks` | `syncMasks()` | 重新打包蒙版给 Layer 2 内核 | 不经过引擎；`FeatureFlags.masks` 关闭时不打包 | 一次绘制 |

撤销（`undo()`）是用快照确定性地重渲染：参数很小，颗粒已经烘焙在缓存底片里，所以重印是稳定的。`pushUndo` 0.5 秒内合并为一次，最多 60 步；批量导出期间禁用（`Session.swift` 第 3680 行 `pushUndo`、第 3694 行 `undo`）。

## 4. RenderScheduler：把一串编辑合并成最少的引擎调用

`Service/RenderScheduler.swift`。维护两份参数：引擎已有的 `sent`，用户想要的 `wanted`；只跑一个循环。

```
request(params)                                   wanted = params；没有循环就启动一个
run()
└─ while generation 未变 且 有 sessionID
   ├─ (delta, layers) = wanted.delta(from: sent)  FilmParams.delta 同时返回涉及哪些层
   ├─ delta 为空 → 结束
   ├─ sleep(含 shoot 层 ? 220 ms : 40 ms)         防抖
   ├─ generation 变了 → 记 debug 日志 "superseded before it was sent"，结束
   ├─ 重新计算 delta（用户还在拖）
   ├─ onBusy(true)
   ├─ 含 shoot 层 → client.render(.previewRender, layer: "shoot")   → spk_set_params + spk_render
   │  否则       → client.render(.reprint)                         → spk_set_params + spk_reprint
   ├─ generation 一致 → sent = target，onResult(结果)
   │  不一致       → noteSuperseded：记 info 日志 "superseded"（带引擎耗时和像素数，证明它真的跑过）
   ├─ 失败 → onError；**仍把 sent 设为 target**，避免在同一个失败上空转
   └─ onBusy(false)
```

- `pending` = `wanted != sent`。全分辨率渲染在 `pending` 时不启动。
- `EngineClient.renderTexture`（`Service/EngineClient.swift` 第 666–700 行）：请求里带 `params_delta` 就先 `spk_set_params`，再按方法调 `spk_render` 或 `spk_reprint`，结果纹理用 `takeRetainedValue()` 接管（+1 所有权）。

## 5. 编辑停下后的全分辨率渲染

`Session.scheduleFullRender()` / `renderFullRender(...)`（`Session.swift` 第 3546–3690 行），对应 `ARCHITECTURE.md` §7.3「两个状态，不是阶梯」。

```
applyRender 落地一张预览分辨率的打印
└─ scheduleFullRender()
   ├─ 取消上一个任务；fullGeneration += 1
   └─ sleep(fullRenderDebounceMs = 400 ms)，再核对 generation
      └─ renderFullRender(url, sessionID, generation)
         ├─ 守卫：!busy && !scheduler.pending && selection == url && serviceSessionID == sid
         │         && gen == fullGeneration && wantsFullRender
         │   └─ 不满足：帧和会话没变就重新排期，否则放弃
         ├─ printStamp：在调用前按 scheduler.sent 盖戳
         ├─ noteProjection(operation: "full")     全分辨率是应用最大的一次分配（45 MP 约 7.6 GB）
         ├─ client.render(.reprint, tier: "full")
         ├─ 再次核对 generation、selection、sessionID（白平衡重开会换会话）
         ├─ 半格对：pairLayered(base:, tier: "full")
         ├─ renderer.store.setFullRender(..., cacheKey: printCacheKey)   进纹理缓存
         ├─ renderer.setFullRender(tex)；previewSoft = false
         ├─ 日志 "full render WxH landed in N ms"
         └─ schedulePrintWriteback()              空闲时写进磁盘缓存
```

- 预览分辨率可选 3840 / 2560（默认）/ 1920 / 1080，对应引擎 `live` 档。**缩放不选档**：放大超过预览边长时画面是软的（`preview` 标记），直到原图落地（`full` 标记）。
- 45 MP、关颗粒和眩光时，live 重印在 1600 是 6.2 ms，2560 是 13.7 ms，8192 是 121.7 ms（`ARCHITECTURE.md` §7.3）。

## 6. 引擎侧：一次 `spk_set_params`

`engine/src/pipeline/engine.cpp` 第 1692–1799 行。

```
spk_set_params(session, delta)
├─ Json::parse → validate_delta              未知字段、类型不符、枚举值不对、越界 → SPK_ERR_USER，什么都不改
├─ shoot = delta_touches_shoot(delta)        是否含 shoot 层字段
├─ stock_change = 含 film_stock 或 print_stock
├─ rebuild = stock_change || delta_needs_rebuild(delta)    即含非 live 字段
├─ live_edge_before = live 档当前长边
├─ if stock_change
│  ├─ 保留 settings（调用方在 open 时的决定，与配置无关）
│  ├─ 读出当前全部参数，叠加 delta → init_params(新胶片, 新相纸) 加载配置
│  ├─ 其余字段原样带过去 → apply_product_defaults → digest（中性滤色等）
│  └─ session->params = fresh
│  else
│  ├─ apply_delta
│  └─ 含 antihalation_removed 时重新套用光晕预设
├─ if rebuild → new Pipeline(gpu, colour, blob, &engine->setup_cache)->build(params)   共享 setup cache
│  else       → pipeline->apply_live_delta(delta)                                      直接改现有流水线
├─ live 档长边变了 → 清空 tiers["live"]（图像和底片都按旧尺寸做的）
├─ shoot || 换了胶片 → 丢弃所有档的缓存底片（缓冲回池）
└─ 返回 {"invalidated": "shoot" | "print", "params": {...}}
```

| 改动类型 | 例子 | 流水线 | 缓存底片 | 下一次渲染 |
|---|---|---|---|---|
| live 字段 | `print_exposure`、`m_filter_shift`、`y_filter_shift`、`preflash_exposure`、`filter_shift_scale`、条带设置 | 原地修改 | 保留 | 重印，约 10 ms 级 |
| 其他 print 层字段 | 相纸曲线相关、扫描、眩光、反差蒙版 | 重建（实测约 18.8 ms，API-SPEC §10.2） | 保留 | 重印 |
| 换相纸 | `print_stock` | 重建参数树 + 重建流水线 | 保留 | 重印 |
| shoot 层字段 | 曝光补偿、颗粒、光晕、几何、片边、场景定位、`camera_filter` | 重建 | **全部丢弃** | 胶片侧重跑 |
| 换胶片 | `film_stock` | 重建参数树 + 重建流水线 | **全部丢弃** | 胶片侧重跑 |
| 预览长边 | `preview_long_edge` | 原地 | live 档清空 | live 档重建缩图并重跑胶片侧 |

**为什么 live 字段这么少**：在现有流水线对象上原地改参数，会让构造时推导的状态变陈旧，例如印放平衡的中灰参考、`scan_film` 拓扑分支、被剪掉的恒等节点（sigma 为 0 时剪掉的节点，调大 sigma 也不会回来）。重建只要约 18.8 ms，所以保守默认几乎免费。扩大 live 集合前必须对每个新字段重跑"重印等于完整渲染"的校验（API-SPEC §10.2）。

## 7. 引擎侧：一次渲染

```
spk_reprint(session, tier, out) / spk_render(session, tier, out)
└─ render_tier(session, tier_name, use_reprint, out)          engine.cpp 约第 1170–1240 行
   ├─ find_tier：只认 "live" / "preview" / "full"，否则 SPK_ERR_INVALID_ARG
   ├─ lock(session->lock)；新 progress_id；SPEKTRAFILM_NODE_TIMINGS 决定是否逐节点计时
   ├─ gpu->begin_frame()；读一次性的"严重内存压力"标志
   ├─ spk_render 且已有底片 → 先丢弃该档底片，强制重跑胶片侧
   ├─ tier_image(session, tier)                             第 991 行
   │   └─ 按档长边从 session->source 降采样（GPU 上做）；不大于该档时直接共用源图；结果按长边缓存
   ├─ pipeline->set_source_long_edge(...)
   ├─ negative_for(session, tier)                           第 1082–1120 行
   │   ├─ 有缓存底片 → 直接返回（重印路径）
   │   └─ 没有：
   │      ├─ ensure_meter：每帧只测一次光（1600 px 缩图，七种方式），缓存键为输入色彩空间、输入 CCTF（色彩分量传递函数）开关、geometry_* 等字段
   │      ├─ pipeline->set_auto_exposure_ev(当前方式的 EV)  各档共用同一 EV（设计记录 RFC-015 P.1）
   │      ├─ run_film（或 run_film_striped）
   │      └─ 把底片拷进 file-backed 持久缓冲 → 存为该档缓存
   │         （颗粒已烘焙在里面，所以之后的重印颗粒一致，不会重新抽样）
   ├─ pipeline->set_overscan_frame(...)                      片边布局按缓存底片重设
   ├─ run_print（或 run_print_striped）
   ├─ materialise：新分配持久缓冲 → spk_to_rgba16 → 建 RGBA16Unorm 纹理，+1 交给调用方
   │   （不用池化缓冲：应用会缓存最近若干帧的纹理，复用就会悄悄变成另一张照片）
   ├─ gpu->end_frame()
   └─ out.reprint / negative_was_cached = 是否用了缓存底片；取消时返回 SPK_ERR_CANCELLED
```

### 7.1 胶片侧：`run_film`（`engine/src/pipeline/pipeline.cpp`）

每个节点都包在宏 `SPK_NODE(...)` 里：先检查取消标志，再执行节点，**然后 `flush`**（第 1756–1774 行）。这个 flush 不是记账：节点释放的缓冲要等引用它的命令执行完才能复用，不 flush 的话全分辨率渲染的峰值就是所有中间结果之和（24 MP 实测：攒到帧末 6.4 s / 3.2 GB，逐节点 flush 0.4 s）。

**前缀 `film_prefix`**（第 1789–1838 行，必须看到整帧）：

| 顺序 | 节点（计时标签） | 作用 | 跳过条件 | 内核 |
|---|---|---|---|---|
| 1 | `preprocess.input_cast` | 4 通道转 3 通道 | 输入已是 3 通道 | `spk_take_rgb` |
| 2 | `preprocess.decode_input` | 输入 CCTF 解码 | `!io.input_cctf_decoding`（应用送线性数据，所以通常跳过） | `spk_cctf_decode` |
| 3 | `preprocess.geometry` | 裁切、旋转、翻转（双精度浮点对坐标） | 几何为恒等 | `spk_geometry_resample_df` |
| 4 | `preprocess.auto_exposure` | 应用测光 EV | `!camera.auto_exposure` | （用缓存 EV 做增益） |
| 5 | `preprocess.crop_rescale` | 只计时，不派发：定下胶片像素尺寸 `pixel_size_um_ = 长边毫米 × 1000 / 裁切前长边像素`；片边模式下长边毫米取片窗尺寸 | — | — |
| — | 抽取胶片侧随机种子 | 每次渲染一个种子，条带执行时不会在条带边界出接缝 | — | — |

**阶段表 `kFilmStages`**（第 2013–2021 行）：

| 阶段 | 类别 | 节点 | 跳过条件 / 说明 |
|---|---|---|---|
| `film_scale_and_expose` | Pointwise | `filming.expose.scene_latitude`、`filming.expose.upsample`、`filming.expose.exposure` | scene_latitude 只在开启时有；upsample 用 `spk_tc_b` + `spk_lut2d_cubic`（Hanatos 光谱上采样） |
| `film_boost` | Whole | `filming.expose.boost` | `boost_ev == 0` 时跳过；**按整帧最大值归一**，所以不能分条带 |
| `film_overscan` | Whole | `filming.expose.overscan` | 片边或数据背开启时才有：片窗外的胶片曝光（片边字、雾、漏光、日期） |
| `film_blurs` | Neighbourhood | `filming.expose.lens_blur`、`filming.expose.halation` | lens_blur sigma ≤ 0 跳过；halation `!active` 跳过 |
| `film_log_and_curves` | Pointwise | `filming.expose.log`、`filming.develop.curves` | 产出 `log_e_film` 和显影后的 CMY 两个中间结果 |
| `film_couplers` | Neighbourhood | `filming.develop.dir_couplers` | 同时读 CMY 和 `log_e_film`；`!active` 跳过；内核 `spk_couplers_correction` |
| `film_grain` | Whole | `filming.develop.grain` | `!active` 或 amount ≤ 0 跳过；内核 `spk_grain_layers` / `spk_grain_layer_one` / `spk_grain_simple` |

输出：该档的**底片**（CMY 密度）。

### 7.2 印放与扫描侧：`run_print`

`print_prefix`（第 2308 行）：除非是反转片（`scan_film`）或数字中间片（DI）模式，每次都重新推导放大机常数（因为 `print_exposure` 和两个滤色偏移是 live 字段）；抽取印放侧种子（给眩光）。然后 `prepare_contrast_mask`。

| 阶段 | 类别 | 节点（按顺序） | 说明 |
|---|---|---|---|
| `print_spectral` | Pointwise | `printing.overscan.film_present`（片边）→〔DI 模式：`scanning.digital_intermediate` 后直接返回〕→〔非反转片：反差蒙版收尾节点 **或** `printing.expose.enlarger_spectral` → `printing.expose.print_exposure` → `printing.develop.print_curves`〕→ `scanning.scan_spectral` → `scanning.bw_correction` | 两次光谱积分（印放、扫描）都用 `spk_spectral_epilogue`；反转片没有印放三步 |
| `print_glare` | Whole | `scanning.glare` | 反转片、DI、`!active` 或 percent ≤ 0 时跳过；内核 `spk_lognormal_field` + `spk_glare_add` |
| `print_linear` | Pointwise | `scanning.xyz_to_rgb`、`scanning.gamut_compress` | DI 模式整阶段跳过；色域压缩算法为 `off` 时跳过；内核 `spk_matmul3`、`spk_cam16ucs_compress` |
| `print_scan_finish` | Neighbourhood | `scanning.scanner_blur`、`scanning.unsharp`、`printing.overscan.light` | 扫描光透过齿孔的效果放在锐化**之后**，否则锐化会在齿孔周围冲出两像素黑边（2026-10-04 修正） |
| `print_output` | Pointwise | `scanning.edr`、`scanning.cctf` | EDR（扩展动态范围）只在 `edr_enabled` 且非反转片时；`cctf` 写进调用方的目标缓冲，内核 `spk_cctf_encode_matrix` |

节点总数 `node_count_` 由 `Pipeline::build` 按同样的跳过条件计算（第 443–463 行），用于进度条。

### 7.3 条带执行（可选）

`settings.striped` 为真时走 `run_film_striped` / `run_print_striped`（第 2099–2250、2284、2355 行）：

- Pointwise 阶段可以分条带；Neighbourhood 阶段问自己的 `demand()`，需要"跨条带携带状态"时整阶段改为整帧执行；Whole 阶段总是整帧。
- 一段连续可分带阶段的 halo 是各阶段 halo **之和**，不是最大值：后一个阶段在条带边缘的输出依赖前一个阶段更外圈的输入。
- 条带高度只由 `choose_strip_height` 决定（唯一策略点），目前只看 `settings.strip_rows`，预算参数已接收但未使用（留给 RFC-021 之后的策略）。
- 已知隐患：`node_geometry` 用 `in.h` 推断帧高，只在整帧时成立；谁把 geometry 改成可分带，谁就要同时把帧尺寸作为参数传进来（`pipeline.cpp` `node_geometry` 注释）。

## 8. 导出流程

来源：`ARCHITECTURE.md` §7.8、§8.8，`Export/ExportPage.swift`。

```
ExportPage.run()                                 Export/ExportPage.swift 第 1626 行；一次一帧，没有队列和并行
├─ session.batchExporting = true                 锁住当前帧：任何改变当前帧或选中集的操作都失效，agent 工具被拒
└─ for url in 选中帧（按显示顺序）
   ├─ session.select(url)                        这是导出循环自己的门
   ├─ await session.ensureDeveloped()
   └─ Exporter.export(...)
      ├─ 引擎：spk_reprint(tier: "full")
      ├─ 应用：Layer 2 → 几何 → 缩放（从不放大）→ 输出变换（CAM16 压进配方色域 + 配方传递曲线）
      └─ ImageIO 写到隐藏的 .<name>.partial-xxxx，再移到正式文件名；TIFF 预览作为第二页
   Stop：在帧与帧之间生效；正在写的一帧会写完
```

- 默认输出到源文件旁的 `_prints/` 子文件夹（`ExportRecipe.subfolder`，`Export/ExportRecipe.swift` 第 537 行），文件名按配方的命名规则（可用原名、胶片、相纸、日期）；DI 为 `<名字>_DI.tif`（第 613–622 行），并在同一文件夹放两个查看用 `.cube`（Cineon→ProPhoto、Cineon→Rec709）。
- 软打样（`Export/SoftProof.swift`）走同一条 `Exporter.filePixels` 链路，在文件自身分辨率上做，实测与文件逐像素一致。
- 源 EXIF 作为旁路原样写回，ImageIO 改写像素尺寸；只有类型化的拍摄值（数据背文字、片窗的光圈值）会进入像素（RFC-033）。

## 9. 核心类与函数汇总

| 类 / 函数 | 位置 | 角色 |
|---|---|---|
| `Session` | `Model/Session.swift` | 应用状态与流程编排 |
| `FramePipeline` | `Import/FramePipeline.swift` | 串行解码队列，带 generation，旧任务在第一个 `checkpoint()` 抛 `CancellationError` |
| `ImageDecoder` | `Import/ImageDecoder.swift` | Core Image 双解码；`engineFrame` 生成共享缓冲 |
| `RenderScheduler` | `Service/RenderScheduler.swift` | sent/wanted 合并与防抖 |
| `EngineClient` | `Service/EngineClient.swift` | C 接口封装（actor） |
| `Renderer` / `TextureStore` | `Canvas/` | 画布绘制、纹理缓存 |
| `Exporter` / `ExportPage` | `Export/` | 写文件、批量循环 |
| `spk_set_params` / `render_tier` / `negative_for` / `tier_image` / `ensure_meter` / `materialise` | `engine/src/pipeline/engine.cpp` | 会话层逻辑 |
| `Pipeline::build` / `run_film` / `run_print` / `kFilmStages` / `kPrintStages` / `SPK_NODE` | `engine/src/pipeline/pipeline.cpp` | 节点序列 |
| `MetalGpu` | `engine/src/gpu/metal_gpu.cpp` | 缓冲池、派发、flush |

## 10. 已知缺陷与隐患

| 优先级 | 问题 | 位置 / 出处 |
|---|---|---|
| P2 | 直方图统计的是**未裁切**的打印：`encodeHistogram` 在几何之前读 Layer 2 纹理。已用 `XCTExpectFailure(strict: true)` 固定，修好后标记会自动报错 | `ARCHITECTURE.md` §7.7、`SurfaceAgreementTests` |
| P2 | `node_geometry` 的帧高推断只在整帧时成立，条带化 geometry 会悄悄让所有微米量出错 | `pipeline.cpp` `node_geometry` 注释 |
| P3 | 片边画布的 DI 没有齿孔切口效果：`overscan_light` 没有 DI 对应节点，孔是平的 | `pipeline.cpp` `print_spectral` 注释；API-SPEC §13 |
| P3 | 印放查找表和 DI 路径（`spk_print_lut_table`、`spk_preview_stock_lut`、`spk_export_di`）不包含反差蒙版，也不包含眩光 | API-SPEC §11；`spk_engine.h` 注释 |
| P3 | `FeatureFlags.enlarger` 定义了但没有引用，Enlarger 分区总是显示 | [03](./03-core-modules.md) 第 6 节 |
| P3 | `gpu.hpp` 文件头说"21 个节点的渲染是一次提交"，与 `SPK_NODE` 逐节点 flush 的实际行为矛盾（注释过时） | `engine/src/gpu/gpu.hpp` 第 21–24 行 |
