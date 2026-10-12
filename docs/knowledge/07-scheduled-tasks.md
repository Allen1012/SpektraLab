# 07 后台任务与异步处理

> 用途：列出应用和引擎里所有防抖、定时器、轮询、串行队列和后台任务，包括触发条件、间隔，以及什么情况下会被取消或丢弃。这个项目没有定时任务调度器（cron）和消息队列；"后台工作"指的就是下面这些。排查"为什么这次渲染没出现""闲着时后台在跑什么"时查这篇。

## 1. 总表

行号均指 `modern_UI/Spektrafilm/Spektrafilm/` 下的文件，引擎部分另注。

### 1.1 编辑与渲染的防抖

| 名称 | 位置 | 触发 | 间隔 | 取消 / 丢弃条件 |
|---|---|---|---|---|
| 参数合并循环 | `Service/RenderScheduler.swift` 第 100 行 | `scheduler.request(params)` | 含 shoot 层字段 220 ms，否则 40 ms；然后重算差异再发 | generation 变了（换帧、重开、`reset`/`invalidate`）：没发出的记 debug 日志，发出了的结果丢弃并记 info 日志 `superseded` |
| 全分辨率渲染 | `Model/Session.swift` 第 3546–3560 行 `scheduleFullRender` | 一张预览分辨率打印落地（`applyRender`） | 400 ms（`fullRenderDebounceMs`，第 748 行） | 新编辑取消旧任务；守卫不满足（`busy`、`scheduler.pending`、换帧、换会话、generation 变化）时，帧和会话没变就重新排期 |
| 原图解码延迟 | `Session.swift` 第 1701–1730 行 `scheduleNativeOriginal` | 打开一帧后需要原分辨率的显示解码 | 触发原因为 `idle_delay` 时等 400 ms，否则立即 | token 变化即作废 |
| 重新解码 | `Session.swift` 第 2668 行 `scheduleReopen` | 相机白平衡、镜头校正等解码设置改变 | 350 ms | 新的重开取消旧的 |
| 保存 sidecar | `Session.swift` 第 2730 行 `scheduleSave` | 任何编辑 | 500 ms | 新的保存取消旧的；退出时 `flushSave()` 立即写 |
| 宽容度重测 | `Model/Latitude.swift` 第 389–397 行 `scheduleLatitudeRefresh` | 画布有了新打印 | 250 ms | 拖动时每一步都取消上一次，只测最后落定的那张 |
| 半格合成 | `Session.swift` 第 5175–5180 行 | 半格对某帧的打印或调色改变 | 60 ms | 新的取消旧的（拖动时每停顿一次合成一次） |
| 半格曝光重算 | `Session.swift` 第 4346–4350 行 | 半格对某帧的位置改变但无需重新解码 | 250 ms | 新的取消旧的；换帧作废 |
| 半格摆放提交 | `Session.swift` 第 4662 行 `schedulePlacementCommit` | 滚轮、捏合、滑块改半格位置 | 280 ms | 新手势取消旧的 |
| 半格摆放兜底 | `Session.swift` 第 4682–4687 行 `commitPlacement` | 摆放已提交、等冲洗落地 | 8 秒 | 冲洗落地会先清掉；8 秒后若还在"落定中"就强制收起拖动预览，防止冲洗失败时预览永远挂着 |

### 1.2 轮询与计时

| 名称 | 位置 | 间隔 | 作用 |
|---|---|---|---|
| 打印写回轮询 | `Session.swift` 第 3590–3606 行 `schedulePrintWriteback` | 先等 400 ms，之后每 200 ms | 只在 `!busy && !fullPending && !scheduler.pending` 时排空 `PrintWriteback`，积压永远不会和实时编辑抢资源；队列空了就结束 |
| 工作计时 | `Session.swift` 第 4051–4060 行 `startClock` | 每 200 ms | 渲染期间显示已用时间。`reprint` 在渲染完成前不返回，没法轮询真实进度，已用时间是诚实的替代 |
| 启动窗口 | `Windows/BootWindow.swift` 第 133–139 行 | 每 60 ms，最长 20 秒 | 等预热完成再显示编辑器；20 秒硬上限，超时编辑器照常出现，预热在后台继续，`openInService` 的闸门保证不会提前渲染 |
| 设置页刷新 | `Windows/SettingsWindow.swift` 第 103 行 | 每 2 秒（`Timer`，页面出现时启动、消失时停止） | 刷新内存占用和磁盘缓存用量的显示。采样器自己的记录在边界处写，不靠这个计时器 |
| Agent 等待 | `Agent/AgentWorkspace.swift` 第 32–40 行 `wait` | 每 40 ms，有超时 | 命令行（CLI）和 MCP（模型上下文协议）服务端等待打开、冲洗、渲染完成；超时报错并带上 `session.lastError` |
| 截图模式等待 | `SpektrafilmApp.swift` 第 440–590 行 | 50–400 ms 不等，`--wait` 可调 | 只在 `--snapshot` 模式下 |

### 1.3 串行队列与后台线程

| 名称 | 位置 | 队列 | 作用 |
|---|---|---|---|
| 解码管线 | `Import/FramePipeline.swift` 第 50 行 | `spektralab.frame-pipeline`（userInitiated，串行） | 一次只解码一帧。`supersede()` 让代数加一，旧作业在下一个 `checkpoint()` 抛 `CancellationError`；排队还没开始的作业在执行前就被丢弃。由 `FeatureFlags.framePipeline` 控制 |
| 日志写入 | `Diagnostics/LogFile.swift` 第 231、245、285 行 | `com.hanze.filmify.log`（utility，串行） | 写会话日志，每 1 秒 `asyncAfter` 刷盘一次 |
| 引擎帧准备 | `Session.swift` 第 2276 行 | `Task.detached(.userInitiated)` | 把线性解码渲染进共享 `MTLBuffer` |
| 缩略图、半格预览 | `Session.swift` 第 2532、4302、4533 行；`Canvas/PairOverlay.swift` 第 191 行 | `Task.detached` | 生成胶片条缩略图和半格对的预览 |
| 诊断包 | `Diagnostics/Diagnostics.swift` 第 654 行 | `Task.detached(.userInitiated)` | 用户导出诊断包时打包 |

### 1.4 启动与退出时

| 时机 | 位置 | 做什么 |
|---|---|---|
| 启动 | `AppDelegate.applicationDidFinishLaunching` | `TypingKeyGuard.install()` → `Diagnostics.shared.start()`（打开会话日志文件）→ 深色外观 → 解析截图参数；非截图模式打开命令行里的文件并显示启动窗口 |
| `Session` 初始化 | `Session.swift` 第 1041–1062 行 | 删除旧版线性缓存目录（`removeLegacyLinearCache`，后台）；**磁盘缓存清扫**：`Task.detached(.utility)` 里 `garbageCollect()`（删掉有文件无索引行的孤儿）再 `trimToCap()`；读出缓存总量；`bootTask = warmUp()` |
| 预热 | `Session.swift` 第 1087–1160 行 `warmUp` | `capabilities` → 校验并记录引擎版本、资源来自包内还是源码树、`render_core`、尺寸上限 → `warm_up`（`spk_warm_up`，按 sidecar 当前的胶片和相纸）。引擎版本要等这一步才确定，磁盘缓存键依赖它，所以 `load` 一开头就要等它（`awaitBoot`） |
| 改磁盘缓存上限 | `Session.swift` 第 1052 行 | 立即在后台 `setCapBytes`，不等下次启动 |
| 退出 | `AppDelegate.applicationWillTerminate` | `Diagnostics.finish()`（写会话结束记录；下次启动看不到它就说明上次是崩溃、挂起或被系统杀掉）→ `flushSave()` → `client.stop()` |

### 1.5 引擎里的后台工作

引擎本身是同步的，每次 flush 都等 GPU 完成。只有这些例外：

| 名称 | 位置 | 触发 | 作用 |
|---|---|---|---|
| 空闲回收计时器 | `engine/src/gpu/metal_gpu.cpp` 约第 800–870 行 | 每 max(0.25, min(阈值/4, 5)) 秒跳一次 | 60 秒（`SPEKTRAFILM_IDLE_TRIM_SECONDS`）没有渲染就释放整个缓冲池；渲染中不触发 |
| 内存压力源 | 同文件第 107–160、927–950 行 | 系统发出 warn / critical | warn 保留本帧峰值，critical 全部释放并标记下一次渲染 |
| 两者共用的队列 | `com.spektrafilm.engine.memorypressure`（串行） | — | 串行保证两个处理函数互斥 |
| 反差蒙版的 CPU 并行 | `engine/src/pipeline/contrast_mask.cpp` 第 104 行 | 开启反差蒙版时 | `dispatch_apply_f` 在全局 userInitiated 队列上并行计算 |
| 取消 | `spk_cancel` | 任意线程 | 设标志，渲染在下一个节点边界退出 |

## 2. 批量导出循环

`Export/ExportPage.swift` 第 1626 行 `run()`。它不是后台队列，而是在主 actor 上一帧接一帧的 `async` 循环：

- 开始时设 `session.batchExporting = true`，锁住当前帧；所有改变当前帧或选中集的操作都失效，编辑器不接受点击，agent 工具除三个只读工具外都被拒绝（陷阱 34）。
- 每帧：`select(url)` → `await ensureDeveloped()` → `Exporter.export(...)`。没有并行：两次 100 MP 全分辨率渲染放不进内存（`ARCHITECTURE.md` §4、§7.8）。
- Stop 在帧与帧之间生效；正在写的一帧写完。
- 结束后切回原来那一帧，并显示该帧写出文件的内嵌预览。

## 3. 网络请求

唯一的网络请求是版本检查（`Updates/UpdateCheck.swift`，设计记录 RFC-021）：**只在用户点击设置里的按钮时**发起一次，无认证读取 GitHub Releases 公开接口，不发送本地信息。没有定时检查。

## 4. 应用空闲时还在跑什么

编辑停下、导出结束、设置页关着时：

1. `PrintWriteback` 排空：每 200 ms 检查一次，队列空了就停。
2. 日志队列每秒刷一次盘（有新记录时）。
3. 引擎的空闲计时器每 5 秒跳一次；最后一次渲染 60 秒后释放缓冲池，之后每次跳动都无事可做。
4. 引擎的内存压力源一直在监听，不消耗 CPU。

其余防抖和轮询都在各自任务完成或被取消后结束。
