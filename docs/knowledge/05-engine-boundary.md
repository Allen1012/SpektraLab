# 05 引擎边界与线上协议

> 用途：说明应用和引擎之间那道 C 接口的规矩：谁拥有什么内存、错误怎么报、参数长什么样、哪些名字一改就算"协议改动"、版本怎么协商。要加字段、改字段、加 C 函数之前必读。全部函数清单见 [06](./06-api-reference.md)。

## 1. 边界的形态

```
Swift（EngineClient，actor）
   │  JSON 字符串（params_delta、回复）
   │  共享 MTLBuffer（输入帧，调用期间借用）
   │  MTLTexture +1（输出，零拷贝）
   ▼
engine/include/spektrafilm/spk_engine.h   29 个 extern "C" 函数
   ▼
engine/src/pipeline/engine.cpp           spk_engine / spk_session 实现
```

**为什么是手写 C 接口，而不是 Swift 的 C++ 互操作**（`ARCHITECTURE.md` §8.2）：ABI 稳定、面窄，而且能被 Python `ctypes` 调用。后一点是关键：一致性校验脚本因此能直接驱动**要发布的那个二进制**，而不是一个专门为测试编译的版本（[16](./16-parity.md)）。

历史：这条边界最初是一个 Python 服务的 stdio JSON-RPC（`CONTRACT-frontend-backend.md` §1），设计记录 RFC-014 把它换成了进程内的 C 接口。方法名、字段名、档位名和版本号都保留了下来，Swift 侧的 `Method` 枚举仍按线上名编码（`Service/Methods.swift` 第 311–319 行）。

## 2. C 接口的三条约定

来源：`ARCHITECTURE.md` §8.2、`spk_engine.h` 第 17–29 行。

### 2.1 不抛异常，失败返回状态码

每个入口都是 `noexcept`；失败时返回负的 `spk_status`，消息用 `spk_last_error(engine)` 取。错误槽是**线程局部**的（`engine.cpp` 的 `thread_local std::string g_error`），两个线程同时渲染时各自的错误互不覆盖。

| 状态码 | 值 | 含义 |
|---|---|---|
| `SPK_OK` | 0 | 成功 |
| `SPK_ERR_INVALID_ARG` | −1 | 空指针、未知档位、非法枚举 |
| `SPK_ERR_USER` | −2 | 调用方请求有误（如字段越界、反转片要 DI） |
| `SPK_ERR_RESOURCE` | −3 | 内存不足、图像过大 |
| `SPK_ERR_UNSUPPORTED` | −4 | 本构建渲染不了的配置 |
| `SPK_ERR_GPU` | −5 | 设备、着色器库或派发失败 |
| `SPK_ERR_IO` | −6 | 资源文件缺失或损坏 |
| `SPK_ERR_CANCELLED` | −7 | 被 `spk_cancel` 取消 |
| `SPK_ERR_INTERNAL` | −8 | 引擎自身的 bug |

应用侧 `Service/EngineMessage.swift` 把这些开发者口吻的错误改写成用户能采取行动的话。

### 2.2 所有权不跨边界，只有一个例外

| 东西 | 谁拥有 | 怎么释放 |
|---|---|---|
| `out_json`（各函数的 JSON 回复） | 调用方 | `spk_string_free` |
| `spk_capabilities`、`spk_params_schema`、`spk_memory_report`、`spk_print_lut_catalog`、`spk_last_error`、`spk_build_info` 的返回值 | 引擎 | 不释放；有效到同一引擎的下一次调用 |
| `spk_print_lut_table` 的表指针、`spk_output_transform` 的 `out_cmax` | 引擎（setup cache 里） | 不释放；整个引擎生命周期有效 |
| `spk_contrast_mask_field` 的浮点网格 | 引擎 | 有效到同一会话的下一次调用 |
| **`spk_result.texture`** | **调用方（+1）** | Swift 用 `takeRetainedValue()` 交给 ARC；C 调用方用 `spk_result_free`。**两者不能同时用** |
| `spk_result.rgba16` | 跟随 `texture` | 纹理活着它就有效 |
| 传入的 `spk_image.data` / `spk_device_image.buffer` | 调用方 | 引擎只在调用期间借用，返回后调用方可立即复用或释放 |
| `spk_session` / `spk_engine` | 调用方 | `spk_session_release`，然后 `spk_engine_destroy`（顺序要紧：会话还给引擎，引擎析构时释放 GPU） |

**例外的原因**：应用会缓存最近若干帧的打印纹理，切换帧才能瞬间完成。如果引擎在同一档的下一次渲染里复用这块像素，被缓存的纹理就会悄悄变成另一张照片。所以每次渲染都新分配缓冲，把唯一的引用交给调用方（`spk_engine.h` `spk_result` 注释）。

`spk_result.row_stride_px` 由设备查询得到（`minimumLinearTextureAlignmentForPixelFormat`），不要自己按 256 字节推算：曾有调用方这么假设，结果读越界。

Swift 侧的 `EngineClient.Handles` 在 `deinit` 里先释放会话再销毁引擎。以前只有 `stop()` 会释放，而退出时没人调用它；每个被丢弃的客户端都留着约 458 MB（5.6 MP 帧），测试套件峰值因此从 1.76 GB 涨到 2.55 GB（`EngineClient.swift` 注释）。

### 2.3 参数一律 JSON，一个例外

所有参数和回复都是 JSON，只有 `spk_print_lut_table` 直接给出一张 (S, S, S, 3) 行主序的 float32 表（431 kB），供 `.cube` 写出器使用。像素输入用 `spk_image`（主机 float32）或 `spk_device_image`（设备上的 `MTLBuffer`），输出用 `spk_result`。

## 3. 线程与并发

| 事实 | 出处 |
|---|---|
| `spk_cancel` 可以从别的线程调用，渲染在下一个节点边界退出并返回 `SPK_ERR_CANCELLED` | `spk_engine.h`；`pipeline.cpp` `SPK_NODE` 检查取消标志 |
| 锁：`engine->lock`（会话列表、能力描述）、每会话一把 `session->lock`、`SetupCache` 的锁、GPU 池的 `pool_lock_` | `engine.cpp`、`setup_cache.hpp`、`metal_gpu.cpp` |
| `render_tier`、`spk_set_params`、`spk_get_params` 都持有整个会话的锁，所以**同一会话内的调用是串行的** | `engine.cpp` |
| `capabilities.backend.concurrent` 报 `true`，注释写"不同档位的渲染持不同的锁"；但代码里 `render_tier` 持的是会话锁，与注释不符（未进一步核实是否有绕开它的路径） | `engine.cpp` `capabilities_json` |
| 应用侧 `EngineClient` 是 actor，对引擎的调用本来就是一个接一个 | `Service/EngineClient.swift` |

## 4. 线上协议：哪些名字不能随便改

`ARCHITECTURE.md` §0：**字段名、档位名、文件布局、版本号的改动都算协议改动，即使看起来只是重构。**

### 4.1 规矩

- `API-SPEC-callable-render-service.md` 是现行协议契约，被 `params.cpp`、`engine.cpp`、`parity_schema.py`、`Params.swift` 和测试引用。**协议改动要在同一个提交里修改它对应的章节**；移动端仓库的 `API-SPEC.md` 在下次同步时取同样的文字（`AGENTS.md`「What this repo is」）。
- 原生专有字段（Python 参考实现没有的字段）一律放在 `preview_long_edge` **之前**，在 `params.cpp` 和 `engine/tests/parity_schema.py` 里顺序一致，并在同一提交里编辑 API-SPEC 对应章节（`ARCHITECTURE.md` §8.10）。`parity_schema.py` 会检查顺序。
- 应用侧 Layer 1 字段名只在 `FilmParams.wire`（`Model/Params.swift`）里定义一次，每个都标了 `shoot` 或 `print`。`ParamsTests.testWireNamesMatchTheServiceSchema` 把它们固定住。
- **只挪代码的重构也可能改动协议**（陷阱 15）：协议由两半拼成，一半是引擎生成的 JSON，一半是 Swift 解码它的类型。2026-09-10 一次拆分漏掉了 `transport_version` 和 `schema_version`，而 Swift 侧这两个字段不是可选的，结果会是拒绝启动而不是警告。动能力描述或任何回复结构前，先打印出来和 Swift 类型对比。
- **测试脚本要向引擎询问配置，不要自己存一份约定**（陷阱 28）：RFC-018 把输出色彩空间从 Display P3 改成 ProPhoto 时，三个校验脚本因为写死了 Display P3 而大面积变红，而实际上没有任何节点、任何算术改变。现在它们从 `open` 回复的 `params.io` 读取。

### 4.2 版本协商（`CONTRACT-frontend-backend.md` §2）

| 版本号 | 当前值 | 何时加一 | 应用的反应 |
|---|---|---|---|
| `transport_version` | 1 | 传输方式或像素交接约定改变 | 遇到不认识的版本**拒绝启动**，给出可见错误而不是空白画布 |
| `schema_version` | 1 | `params_delta` 字段改名、删除或改单位 | 警告 |

新增字段或方法**不**加版本号，任何时候都允许。破坏性改动的流程是：先加一个做新事情的可选字段或方法，旧的继续可用并标为弃用，在 CONTRACT §6 记一行，过一个周期再删。

### 4.3 三条承重的不变量（`CONTRACT-frontend-backend.md` §1.2，按现状改写）

1. **`rgba16` 布局**：`宽 × 高 × 4 × uint16`，行主序，第 0 行是图像顶部，数值**已按会话输出色彩空间编码**。应用从不施加传递曲线。输出空间默认是 ProPhoto RGB（CCTF 编码），可被 `open` 增量里的 `io.output_color_space` 覆盖，**必须从 `open` 回复的 `params.io` 读取**。（CONTRACT 里"画布转换到 Display P3"的说法已过时：现在画布打 ProPhoto 标签，由 ColorSync 转换，见 [10](./10-physical-model-and-colour.md)。）
2. **单飞传输**：原意是一次只有一个请求在途。现在引擎是进程内的，`capabilities.backend.concurrent` 为 true，但应用的 `EngineClient` 是 actor，`RenderScheduler` 和全分辨率渲染仍按"不在有编辑待发时启动全分辨率渲染"的规则工作。
3. **档位名**：`live`、`preview`、`full`。应用的缓存键、纹理预算都用这三个词。可以加新档位，这三个不能动。live 的像素尺寸现在由会话设置 `io.preview_long_edge` 决定，默认表里的 1600 只是默认值。

CONTRACT 的其余部分（§3 前后端需求、§4 文件归属、§4.1 双工作树、§5 请求记录）描述的是 2026-09 两个会话并行开发时的分工，**已是历史**。§6 是截至 2026-09-13 的协议变更日志。

## 5. 参数字段

### 5.1 规模与分层

`engine/src/core/params.cpp` 的 `kFields` 共 **98 个字段**：67 个 shoot 层、31 个 print 层（逐行统计）。最后一个是 `preview_long_edge`。

| 类别 | 字段（节选） | 层 |
|---|---|---|
| 胶片与相纸 | `film_stock`、`print_stock` | shoot / print |
| 相机与曝光 | `exposure_compensation_ev`、`auto_exposure`、`auto_exposure_method`、`film_format_mm`、`lens_blur_um`、`camera_filter` | shoot |
| 胶片效应 | `halation_*`、`grain_*`、`dir_couplers_*`、`density_curve_gamma`、`antihalation_removed` | shoot |
| 输入与几何 | `input_color_space`、`input_cctf_decoding`、`geometry_crop_x/y/w/h`、`geometry_rotation_deg`、`geometry_quarter_turns`、`geometry_flip_h/v` | shoot |
| 放大机 | `print_exposure`、`m_filter_shift`、`y_filter_shift`、`c/m/y_filter_neutral`、`preflash_exposure`、`enlarger_illuminant`、`filter_shift_scale` | print |
| 扫描与输出 | `glare_active`、`glare_amount`、`scanner_*`、`output_color_space`、`output_cctf_encoding`、`scan_film`、`extended_dynamic_range` | print |
| 执行设置 | `striped`、`strip_rows`、`strip_budget_bytes` | print（live） |
| 反差蒙版 | `contrast_mask_*`（6 个） | print |
| 场景宽容度 | `scene_latitude_*`（8 个）+ 半格对用的 `scene_latitude_split`、`scene_latitude_b_*`（6 个） | shoot |
| 数字中间片 | `digital_intermediate`、`digital_intermediate_blue_compensation` | print |
| 片边与数据背 | `overscan_*`、`date_imprint_*` | shoot |
| 档位 | `preview_long_edge` | print |

- live 字段（不重建流水线）：`print_exposure`、`m_filter_shift`、`y_filter_shift`、`preflash_exposure`、`filter_shift_scale`、`striped`、`strip_rows`、`strip_budget_bytes`（`params.cpp` 第 24–37 行 `is_live`）。
- `product_defaults` 是 `spk_open` 增量里的一个键，**故意不是** `kFields` 的一行：它选择的是一套默认值，属于打开时的决定。加成第 99 个字段会让 `parity_schema` 报告一个其实不存在的差异（`engine.cpp` `kProductDefaultsKey` 注释）。

### 5.2 校验规则（`validate_delta`，`params.cpp` 第 411–466 行）

- 增量必须是 JSON 对象；未知字段名直接拒绝。
- 类型严格：JSON 布尔不算数字。
- 枚举字符串：`camera_filter`（空或 `w8 w11 w12 w15 w21 w25 w47 w58`）、`auto_exposure_method`（`balanced`、`center`、`protect_highlights`、`protect_shadows`，以及旧的 `center_weighted`、`average`、`median`）、`contrast_mask_scheme`（`gaussian`）、`scene_latitude_norm`（`power`、`y`、`max`）。
- 数值检查 `[lo, hi]` 区间。
- 任何一项不通过就返回 `SPK_ERR_USER`，会话参数保持不变。

注意 schema 的范围可能比数学允许的宽：`dir_couplers_amount` 超过约 1.736 时成色剂逆运算的曝光轴不再单调，而协议允许到 4.0（陷阱 22）。

### 5.3 原生专有字段摘要（API-SPEC §11–§15）

| 章节 | 功能 | 字段 | 层 / live | 要点 |
|---|---|---|---|---|
| §11（2026-09-23） | 虚拟反差蒙版（RFC-024） | `contrast_mask_active`、`_highlights`（0–3）、`_shadows`（0–3）、`_core`（0–3）、`_scale`（0.002–0.12）、`_scheme`（`gaussian`） | print，非 live | 关闭时与引入前逐字节一致；改蒙版是重建 + 重印，不重新冲洗。只用于负片印相，反转片、正片相纸、`lut_mode` 下忽略。查找表与 DI 路径不带蒙版。应用里由 `FeatureFlags.toneMask` 关闭 |
| §12（2026-09-24） | 场景宽容度映射（RFC-023） | `scene_latitude_active`、`_norm`、`_highlight_knee`（默认 2.0）、`_highlight_room`（0 关闭高光侧）、`_shadow_knee`（−2.0）、`_shadow_room`、`_rolloff`（1–4）、`_max_lift`（0.25–12） | shoot，非 live | 配合 `spk_scene_latitude`（只测量、建议、拟合，从不渲染）；它返回的 `params_delta` 就是提交时要发的增量 |
| §13（2026-10-01） | 片边与数据背（RFC-032、RFC-031） | `overscan_*` 14 个、`date_imprint_*` 11 个 | shoot，非 live | 所有痕迹（片窗阴影、雾、漏光、片边字、DX 码、日期）都是底片上的曝光，所以改动会重新冲洗。条文先写在移动端仓库再同步过来。详见 [11](./11-film-edge-pairs-bw.md) |
| §14（2026-10-04） | `filter_shift_scale` | 1 个，默认 1.0，范围 1–60 | print，live | Y/M 偏移原本是 −1…1 加到 CC 单位的滤色组合上，整个范围只有 1 CC、0.014 档，看不出来。应用永远发 40（`FilmParams.filterShiftCC`），滑块两端即 ±40 CC |
| §15（2026-10-07） | `camera_filter` | 1 个，空或 Wratten 编号 | shoot | 透过率乘进胶片感光度，再建上采样表；滤镜因数按绿层比值算好；片边字、雾、日期读的是不带滤镜的感光度。应用目前没有控件 |

## 6. 引擎资源从哪里加载

`EngineClient.defaultResources()`（`Service/EngineClient.swift` 第 221–239 行）按以下顺序查找含 `spektrafilm_constants.bin` 的目录：

1. 环境变量 `SPEKTRAFILM_ENGINE_RESOURCES`（非空即用）；
2. 应用包内的 `Resources/engine/`（用 `Bundle(for:)` 而不是 `Bundle.main`：测试目标没有宿主，`Bundle.main` 是 Xcode 的测试代理）；
3. 从应用包往上最多 8 级目录，找 `engine/resources/`（给从源码树直接运行的构建用）；
4. 都没有就返回 `<包>/Contents/Resources/Resources/engine`，由 `start()` 报"资源缺失，请运行 engine/build.sh bundle"。

> 与英文文档的出入：`AGENTS.md` 陷阱 14 写的是"先查应用包，再查环境变量"，代码实际是**环境变量优先**。

这里的坑（陷阱 14）：代码已经编译进二进制，不会弄错；但**数据**可能来自别处。第 3 步的回退会让一个没同步资源的构建悄悄用上层源码树的资源渲染。`engine/build.sh bundle` 负责同步；应用目标的构建前脚本 `Tools/check-bundle-resources.sh` 在资源缺失时让构建失败，所以静默的情况是"陈旧"而不是"缺失"。`EngineResourceOriginTests` 断言资源来自应用包内；`EngineClient.resourcesAreBundled` 也在能力描述里报告这一点。

## 7. 启动时的自检

`spk_engine_create`（`engine.cpp`）依次：打开常量文件 → 初始化色彩数据 → 读中性滤色 JSON → 初始化印放查找表索引 → 创建 Metal 后端（加载 `spektrafilm.metallib`）→ **运行快速数学探测**：`spk_math_probe` 计算 `a*b − a*b`，快速数学模式下恰好为 0，安全模式下是 fma 舍入误差。64 个探测值全为 0 就拒绝启动，并提示用 `-fmetal-math-mode=safe -fmetal-math-fp32-functions=precise` 重新编译（RFC-014 §5.1 陷阱 1：快速数学让 `exp` 和 fma 收缩漂移最多 1.1e-5，超过 float32 的容差且无声无息）。`engine/tests/check_math_guard.sh` 证明这个守卫确实会触发。
