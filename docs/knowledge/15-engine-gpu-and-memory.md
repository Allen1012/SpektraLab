# 15 引擎的 GPU 层与内存

> 用途：讲清引擎怎么用 Metal、缓冲区什么时候能复用、内存什么时候还给系统、哪些东西被缓存、性能数字从哪来。要改 `engine/src/gpu/`、`engine.cpp` 的会话缓存，或排查"慢"和"内存爆"之前，先读这篇。

## 1. GPU 抽象：五个动词

`engine/src/gpu/gpu.hpp` 第 1–40 行。这层故意不是通用计算抽象：渲染图是一串处理紧凑 float32 整帧的内核，五个动词就够了。`gpu.hpp` 以上的代码不出现 Metal 字样，所以 Windows 版能换成 Vulkan 后端而不改流水线和 C 接口。

| 动词 | 作用 | Metal 实现要点（`metal_gpu.cpp`） |
|---|---|---|
| `alloc` / `upload` | 拿一块内存，往里放常量 | 共享存储（`StorageModeShared`）：Apple 芯片上 CPU 和 GPU 看的是同一批页，`contents()` 直接可读写，无需暂存拷贝 |
| `dispatch` | 在 N 个线程上运行一个具名内核 | 编码进当前打开的命令缓冲后立即返回；≤4 KB 的参数走 `setBytes`，更大的临时上传并持有到 flush；线程组宽 256 |
| `flush` | 提交并等待 | `endEncoding` → `commit` → `waitUntilCompleted` → 释放在途临时缓冲 → `reclaim()` |
| `read` | 把缓冲内容拷回主机 | 默认实现是 flush + memcpy |
| `texture` | 零拷贝把像素交给画布 | 在结果缓冲上建 `RGBA16Unorm` 纹理，以 **+1** 返回给调用方 |

接口里还有：持久缓冲（`alloc_persistent`）、文件映射缓冲（`alloc_file_backed`）、借用调用方缓冲（`borrow`，只给 `spk_open_device` 用）、`begin_frame`/`end_frame`、`check_math_mode`、`pool_stats`、`trim_pool`、`take_critical_pressure`。

**整个引擎是同步的**：没有编码与执行的重叠，每次 flush 都等 GPU 完成。

## 2. 缓冲区的一生

### 2.1 四类缓冲

| 类别 | 分配函数 | 释放时 | 用途 |
|---|---|---|---|
| 池化缓冲 | `alloc` / `upload` | 引用归零后进 `pending_`，flush 后变为可复用 | 节点之间的中间结果 |
| 持久缓冲 | `alloc_persistent` / `upload_persistent` | 引用归零**直接销毁**，还给系统 | 烘焙常量、`tc_lut`、印放查找表的设备拷贝、每次渲染的 RGBA16 结果 |
| 文件映射缓冲 | `alloc_file_backed` | 同持久缓冲 | 会话的源图和各档缓存底片 |
| 借用 | `borrow` | 不进池，句柄释放即归还 | `spk_open_device` 调用期间借用应用的 `MTLBuffer` |

`BufferRef`（`gpu.hpp` 第 60–84、455–478 行）是侵入式引用计数句柄：复制加一，析构减一。节点链写成 `cur = next`，前一阶段的内存就会在后一阶段跑完后自动归还，节点自己不需要知道哪个输入已经没用了。

### 2.2 复用规则：空闲且无在途命令

一个池化缓冲**同时满足两个条件**才能再次分配出去（`metal_gpu.cpp` 第 43–74 行 `struct Buffer` 注释）：

1. **free**：最后一个句柄已释放；
2. **idle**：最后引用它的命令缓冲已执行完。

```
release(buffer)                        metal_gpu.cpp 约第 290–324 行
├─ 持久缓冲 → 直接 release 给系统
├─ 已在 pending_ 中 → audit.over_releases += 1，不重复入队（重复入队会变成释放后使用）
└─ 否则 → in_pending = true，push 进 pending_       ← 注意：此时还不能复用
flush()
└─ commit + waitUntilCompleted → reclaim()：pending_ 里的缓冲全部标为可复用
alloc(bytes)                           约第 326–400 行
├─ 取能装下的**最小**可复用缓冲（没有大小上限：小请求也可能拿到整帧大小的缓冲）
├─ 请求 ≥ 16 MB 且 pending_ 里有能满足的 → 先 flush 再取     （见下）
└─ 都没有 → newBuffer(StorageModeShared)，计入池
```

只检查第一个条件会怎样：后面的内核覆盖了前面内核还没读的缓冲，**27 个渲染一致性用例错 25 个，没有崩溃、没有报错**（陷阱 19，`ARCHITECTURE.md` §8.3）。

**≥16 MB 先 flush** 的来由：颗粒和扩散阶段（`spk_grain_layer_one`、`spk_sep_fir_acc`、`spk_couplers_correction`）中间很长一段没有 flush，102 MP 时会积压 19 个、共 13.1 GB 待回收缓冲，而真正同时存活的只有 11.0 GB；`alloc` 又新开 8 个 1.22 GB 缓冲，峰值 28.9 GB 撑爆 24 GB 机器。所以分配大缓冲前先看 pending 里有没有合适的，有就 flush 让它变成真的可用（`metal_gpu.cpp` alloc 注释，修复提交 `b61282c`）。三个要点：flush 前必须先放锁（否则死锁）；16 MB 下限让小常量上传不付提交等待的代价；这在 `alloc` 里埋了一个同步点，以后若要重叠编码与执行，必须在这里处理。

### 2.3 为什么每个节点后都 flush

`pipeline.cpp` 的 `SPK_NODE` 宏在每个节点后调用 `flush`。只在帧末回收时，渲染峰值是所有中间结果之和：24 MP 时约 11 个 288 MB 缓冲，一个命令缓冲同时引用 3.2 GB，耗时 **6.4 s 而不是 0.4 s**，看起来和"退回 CPU"一模一样，其实不是（陷阱 18 原因一）。逐节点 flush 也正好是参考实现求值的位置（陷阱 5 的 `mx.eval`）。**别为了速度删掉这些 flush**（`AGENTS.md`「Do not」）。

`gpu.hpp` 文件头仍写着"21 个节点是一次提交"，这句已过时。

### 2.4 文件映射缓冲（设计记录 RFC-020 §4.7）

- 页面放在一个文件里，而不是进程自己的内存账本，从而大幅降低 jetsam（系统内存紧张时终止进程的机制）看的 `phys_footprint`：同一个 1.22 GB 平面，普通共享缓冲占 **1362 MB**，文件映射只占 **137 MB**，GPU 读取速度相同（`gpu.hpp` 注释）。
- 实现：`mkstemp` 建临时文件后**立即 `unlink`**（在写入第一个字节前），只保留 inode；`mmap` 得到页对齐指针交给 Metal（`metal_gpu.cpp` 约第 479–532 行）。临时目录用 `confstr` 取，`TMPDIR` 作后备。
- 建不了文件时退回普通持久缓冲，不让优化变成打开失败；退回是可见的：`file_backed_bytes` 不增长。

## 3. 把内存还给系统

`trim_pool(keep_bytes)`：按大小从大到小释放引用为 0 的池化缓冲，直到池总量 ≤ `keep_bytes`（0 表示全放）。**永远不释放引用 > 0 的缓冲**。返回实际释放的字节数。三个触发点：

| 触发 | 位置 | 保留多少 | 说明 |
|---|---|---|---|
| 换帧 | `engine.cpp` `open_frame` 第 776–806 行 | 0 | 之前的会话都关了，或新帧尺寸与池里缓冲对应的帧不同时才回收。**不在 `end_frame` 回收**：同一会话里相同尺寸马上会再用 |
| 内存压力 warn | `metal_gpu.cpp` `handle_pressure` | 本帧的峰值（`frame_high_water_`） | 留下当前帧需要的，放掉更大帧的残留 |
| 内存压力 critical | 同上 | 0 | 并置一次性标志，下一次渲染的 `progress` 会报告"在压力下渲染" |
| 空闲 60 秒 | `maybe_trim_idle` | 0（`idle_keep_bytes()`） | 系统内存压力是被动的，机器空闲时永远不触发；这是主动版本。渲染中或从未渲染过时不触发 |

- 内存压力源和空闲计时器挂在同一个串行队列 `com.spektrafilm.engine.memorypressure` 上（`metal_gpu.cpp` 第 107–160 行）。串行队列保证两个处理函数互斥；析构时先 cancel 再 `dispatch_sync_f` 一个空任务排空，最后释放。
- 计时器每 max(0.25, min(阈值/4, 5)) 秒跳一次。
- 环境变量：`SPEKTRAFILM_IDLE_TRIM_SECONDS`（0 关闭计时器；解析失败时**不关闭**，退回 60 秒）、`SPEKTRAFILM_TEST_PRESSURE=warn|critical`（测试缝：在每个帧边界通过真实处理函数投递一次事件）。两者都在引擎创建时读取一次。
- 设计边界：调节策略（例如按空闲内存选择条带高度）留给 RFC-021，这里每个策略只有一个函数，以后整体替换（RFC-020 §7）。

## 4. 记账：`spk_memory_report` 与审计计数器

`spk_memory_report` 返回 JSON（`spk_engine.h` 注释、`engine.cpp` `memory_report_json`），开销小到可以给界面计时器用：

| 字段 | 含义 |
|---|---|
| `pool.total_bytes` | 所有池化缓冲 = `live_bytes` + `free_bytes` + `pending_bytes` |
| `pool.live_bytes` | 被节点、Image 或在途派发持有 |
| `pool.free_bytes` | 下一次 alloc 现在就能拿 |
| `pool.pending_bytes` | 已释放但命令缓冲还引用着 |
| `pool.frame_high_water_bytes` | warn 级压力时会保留的大小 |
| `pool.audit.*` | 分配、复用、持久分配次数，以及下面四个必须为 0 的计数器 |
| `persistent.bytes` | 池外的一切：会话源图、缓存底片、烘焙表、渲染结果 |
| `persistent.source_bytes` / `cached_negative_bytes` / `file_backed_bytes` / `sessions` | **都是 `persistent.bytes` 的拆分，不是额外加项** |
| `total_bytes` | `pool.total_bytes + persistent.bytes`，即引擎的全部持有 |

不包括调用方自己的内存（传给 `spk_open_device` 的帧、Core Image 解码），这些由应用的 `DecodeResidency` 记账。

**必须恒为 0 的审计计数器**（`gpu.hpp` `PoolAudit`）：

| 计数器 | 一旦非 0 说明 |
|---|---|
| `pending_held` | 有句柄的缓冲被放进了待复用队列 |
| `over_releases` | 释放了一个没人持有的缓冲 |
| `reclaim_while_encoding` | 命令缓冲还开着时就把缓冲标为可复用 |
| `live_underflows` | 引用计数与池计数对不上。2026-09-20 发现：`release` 减掉了一个从未计入的持久缓冲，导致 warn 级回收的目标变成"十八艾字节"，从 1.0.2 起 warn 级回收实际上失效（不崩溃、不影响画面） |

这些不变量由 `engine/tests/pool_invariants.py` 检查。注释里的论证不会失败，计数器会。

## 5. 缓存：为什么拖滑块快

来源：`ARCHITECTURE.md` §8.5、`engine/src/core/setup_cache.hpp`。

| 缓存 | 贵在哪 | 键 | 容量 | 位置 |
|---|---|---|---|---|
| CAM16 色貌模型的 `C_max` 表 | 64×720 个单元，每个 18 次二分，约 83 万次 CAM16 逆变换 | 输出色彩空间 | 不限 | `SetupCache::cam16`（引擎级） |
| Hanatos `tc_lut` | 192×192×81 收缩 + 射线多边形重映射 | 胶片配置**和感光度数组**（`camera_filter` 改变感光度，自然换键） | 最多 4 个（`kMaxLuts`），每个 884 kB，最近使用优先 | `SetupCache::tc_lut`（引擎级） |
| 各档缓存底片 | 整个胶片侧 | 档名；shoot 层改动失效 | 每档一份 | `spk_session::TierState` |
| 档位缩图 | 一次 GPU 降采样 | 档名 + 长边 | 每档一份 | `TierState.image` |
| 测光 | 七种测光方式 | `kMeterKeyFields`（输入色彩空间、输入 CCTF、`geometry_*`） | 一份 | `spk_session::meter` |
| 场景宽容度 | 一次中性灰阶渲染（介质探测）+ 场景统计 | 各自读到的参数 | 各一份 | `spk_session::scene_latitude` |
| 印放查找表 | 从常量文件加载 + 上传 431 kB | 相纸名 | 引擎生命周期 | `spk_engine::print_luts`、`print_lut_buffers` |
| float32 `C_max` | 给 `spk_output_transform` 调用方的指针 | 目标色彩空间 | 引擎生命周期，指针稳定 | `spk_engine::cam16_cmax_f32` |

- setup cache 由一个引擎的所有流水线共享：非 live 字段触发的流水线重建不会重算它们。命中和未命中次数在 `capabilities.backend.session_cache` 里。
- 当初移植漏掉了这三个缓存（Python 里是 `_SETUP_CACHE`、`_OUTPUT_CMAX_CACHE`、`filming_tc_lut_memory`），每次动 live 集合以外的滑块都要 160–250 ms（陷阱 18 原因二）。
- **shoot/print 标签因此是正确性问题**：print 层改动复用底片，shoot 层改动绝不能复用。

## 6. 尺寸上限与档位

| 常量 | 值 | 位置 | 说明 |
|---|---|---|---|
| `kTiers` | live 1600 / preview 3400 / full 0（原图） | `engine.cpp` 第 72 行 | live 按会话设置 `io.preview_long_edge` 覆盖 |
| `kMeterLongEdge` | 1600 | `engine.cpp` | 测光分辨率独立于档位，档位改动不会移动自动曝光 |
| `kMaxFramePixels` | 14204 × 10652 = 151,301,008 px | `engine.cpp` 第 102 行 | Phase One IQ4 150；按像素数而非 MP 定，因为内存随像素线性增长。原先的 60 MP 上限来自 Python 服务，挡住了 A7R V（60.22 MP） |
| 最大纹理边长 | 16384 | `metal_gpu.cpp` `max_texture_dimension_2d` | Metal 不公开这个值，按 GPU family 查询；超过的帧能渲染但画布显示不了 |

## 7. 条带执行（RFC-020 §4）现状

- 引擎已实现可选的条带执行器（`settings.striped`，默认 false），输出与整帧执行**逐位一致**是上线门槛。
- **应用目前不开启它**：应用代码里没有发送 `striped`、`strip_rows`、`strip_budget_bytes`。
- 不能分条带的阶段：`boost`（用整帧最大值）、`film_overscan`、`film_grain`、`print_glare`（体内含自己的模糊）；片边模式整帧渲染，所以应用会在超出纹理上限时提前拒绝（`Session.filmEdgeRefusal`）。
- 详细规则见 [04](./04-render-flow.md) 第 7.3 节。

## 8. 应用侧内存（RFC-019）

| 组件 | 作用 | 默认值 |
|---|---|---|
| `MemoryArena`（`Diagnostics/MemoryArena.swift`） | 登记每块大内存（pinned 或可驱逐）及驱逐回调；`enforce` 计算缺口 = max(余量 − 空闲内存, 可驱逐总量 − 上限)，按优先级从低到高驱逐 | 余量 `diag.memoryReserveMB` 2000 MB；上限 `diag.memoryCapMB` = min(8192, 物理内存 MB × 0.4)，范围 2048–131072，0 表示不限 |
| `TextureStore` | 源图和打印纹理缓存，通过 `admitCache` 向台账申请 | — |
| `DecodeResidency` | Core Image 解码的驻留记账 | — |
| 引擎占用 | 冲洗时 `registerPinned(engineArenaEstimateBytes, kind: "engine")` | — |
| `DiskCacheStore` + `PrintWriteback` | 内存之下的磁盘层 | 8000 MB；写回队列 5 亿字节 |

## 9. 性能数字

**这台机器不是基准**（陷阱 17）：开发机的计时经常被大幅污染，例如 2026-09-10 一次 `service.open` 从 922 ms 变成 1.86–2.81 s，原因是后台游戏占着 GPU。引用数字前先看 `ps -Ao %cpu,comm -r | head` 和 `uptime`；交替测量而不是先后测量；涉及导入或分配时优先看 CPU 时间。`core=native-metal` 和正确性结果与计时无关，单独报告。

45 MP、预热后、M3 Max（`ARCHITECTURE.md` §8.7）：

| 档位 | 首次渲染 | 重印 | 换相纸查找表 |
|---|---|---|---|
| live 1600 px | 0.13 s | 0.01 s | 2.0 ms |
| preview 3400 px | 0.25 s | 0.04 s | 9.5 ms |
| full 7800×5800 | 0.87 s | 0.17 s | 47 ms |

- 打开一张 24 MP RAW 约 2.0 s，其中约 1.6 s 是 Core Image。
- 内存峰值（打包好的 1.0.3 版，外部探针，RFC-020「Final baseline」）：24 / 45 / 61 / 102 MP 分别为 4.1 / 7.0 / 7.9 / 13.7 GB。
- 安装包 32 MB，其中代码约 3 MB：引擎数据 15 MB（常量里主要是 float16 的 Hanatos 光谱和 3.45 MB 印放查找表，加 5.8 MB 配置）、`Assets.car` 13 MB（图标的 SVG 图层）、可执行文件 3.3 MB、画布 metallib 148 kB。
- RSS（常驻内存集）看不到 Metal 池，用 `footprint -p <pid>`。

**节点计时默认只测编码时间**（`ARCHITECTURE.md` §8.9）：派发攒在一个命令缓冲里，节点外面的计时器量的是编码。`progress.node_times` 默认为空，除非设置 `SPEKTRAFILM_NODE_TIMINGS=1`（会逐节点等待 GPU，渲染变慢）。空字段是诚实的，看似合理的错误数字不是。

## 10. 慢渲染排查清单

"渲染慢"不是"退回了 CPU"，因为没有 CPU 路径。已测到的三个原因（陷阱 18）都可能复发：

1. **帧内缓冲不复用**（第 2.3 节）。
2. **setup cache 缺失或失效**（第 5 节）。
3. **打开路径上的整帧拷贝**：以前 Swift 在 `-Onone` 下逐像素去 alpha，源图既留在主机又按档上传，24 MP 打开要 5.9 s，现在 2.0 s。

排查顺序：先看日志 `core=native-metal`，再分别计 live/preview/full 三档，再看**重复**渲染时的峰值内存：池在增长就是信号。
