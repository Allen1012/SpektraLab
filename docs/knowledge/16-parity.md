# 16 与上游参考实现的一致性校验（parity）

> 用途：说明 C++ 引擎是怎么被证明"和上游 Python 参考实现算得一样"的：有哪些校验脚本、各守住什么、门槛为什么定在那里、怎么运行、哪些差异是有意的。改了引擎的输入、内核、资源或渲染边界之后必读。

## 1. 为什么需要它

C++ 引擎是上游 spektrafilm（Python）的移植。参考实现被当作"标准答案"（oracle），但它**不在本仓库**：运行时也不存在，只在校验和重新烘焙资源时通过 `PYTHONPATH` 指过去（`AGENTS.md`「What this repo is」）。

校验脚本通过 `ctypes` 加载 `engine/build.sh dylib` 产出的 `libspektrafilm_engine.dylib`，也就是**和应用里编译的同一份引擎代码**。这正是引擎边界选择手写 C 接口的原因（[05](./05-engine-boundary.md) 第 1 节）。

## 2. 脚本清单（`engine/tests/`）

### 2.1 需要上游参考实现的七个一致性校验

| 脚本 | 守住什么 | 记录的结果（`ARCHITECTURE.md` §8.6） | 怎么接引擎 |
|---|---|---|---|
| `parity_setup.py` | 227 个初始化量（对照 colour-science、scipy、numpy） | 0 失败，86 个逐位一致 | C++ 驱动 `dump_setup` |
| `parity_schema.py` | 线上 schema 和消化后的参数，6 组胶片/相纸；字段名、路径、类型、层、默认值、live、范围、**顺序** | 一致（有一条登记的 `KNOWN` 差异） | C++ 驱动 `dump_json` |
| `parity_render.py` | 画面逐像素，27 种配置，1 MP 帧 | 0 失败，最大误差 2.3e-5 | ctypes |
| `parity_session.py` | 在一个**活的**会话上逐个改动每个线上字段 | 0 失败 | ctypes |
| `parity_grain.py` | 9 个密度下颗粒的均值、标准差、偏度 | 0 失败 | ctypes |
| `parity_exposure.py` | 自动曝光测光的各种方式（设计记录 RFC-015 §6） | **当前损坏**，见第 5 节 | ctypes |
| `parity_lut.py` | 8 张印放表逐位一致，查找表应用、数字中间片（DI）归一化按 `parity_render` 的门槛 | 表逐位一致，最大 8.0e-6 | ctypes |

### 2.2 不需要参考实现、可直接运行的检查

| 脚本 | 检查什么 |
|---|---|
| `gpu_smoke.cpp`（`engine/build/gpu_smoke`） | 设备、metallib、数学模式、几个手工核对的内核 |
| `check_math_guard.sh` | 故意用快速数学编一个 metallib，断言引擎拒绝启动，证明守卫会触发 |
| `bw_checks.py` | 黑白胶片和镜头滤镜（在临时目录把 `resources_product/` 叠加到 `resources/` 上） |
| `overscan_checks.py` | 片边和数据背（34 项） |
| `memory_report.py` | `spk_memory_report` 的数字和回收行为 |
| `pool_invariants.py` | 缓冲池审计计数器必须为 0（[15](./15-engine-gpu-and-memory.md) 第 4 节） |
| `idle_trim.py` | 空闲回收；60 秒阈值就是按它的测量选的 |
| `frame_switch_footprint.py` | 换帧时缓冲池归还 |
| `file_backed_planes.py` | 会话平面的文件映射 |
| `iir_bitexact.py`、`iir_peak.py` | 条带化 IIR（无限冲激响应）模糊逐位一致、条带执行的峰值内存 |
| `strip_executor.py`、`strip_fir.py` | 条带执行器、FIR（有限冲激响应）模糊的 halo |
| `band_purity.py` | 不加载 ctypes，似乎是静态检查（未核实） |

辅助文件：`spk_ctypes.py`（ctypes 封装）、`spk_test_paths.py`（路径解析）、`dump.hpp`、`dump_json.cpp`、`dump_setup.cpp`。其余 `gpu_vulkan_*`、`raw_*`、`windows_*`、`host_smoke.py`、`test_windows_*` 等属于 Windows/Linux，不在范围内。

> 与英文文档的出入：`ARCHITECTURE.md` §8.1、§8.6 说有**七个**一致性校验（含 `parity_exposure.py`）；`AGENTS.md`「The engine」说"现在有六个，`parity_lut.py` 最新"，命令清单里也没有 `parity_exposure.py`。目录里实际是 7 个 `parity_*.py`，其中 `parity_exposure.py` 当前跑不通（第 5 节），所以"六个能跑"。

## 3. 运行方法

**一致性校验要在有参考实现的环境里跑**，但驱动的是**本仓库**的引擎。最简单的形式是在本仓库根目录运行，`PYTHONPATH` 指向上游的 `src`（`AGENTS.md`「The engine」）：

```bash
engine/build.sh dylib          # 校验脚本加载的 dylib
engine/build.sh tests          # C++ 驱动；dylib 不会重建它们
export REF=~/Documents/Summer\ 2026/spektrafilm          # 上游参考实现
export PYTHONPATH="$REF/src:engine/tests"
"$REF/.venv/bin/python" engine/tests/parity_setup.py     # 常量
"$REF/.venv/bin/python" engine/tests/parity_schema.py    # 协议
"$REF/.venv/bin/python" engine/tests/parity_render.py    # 画面
"$REF/.venv/bin/python" engine/tests/parity_session.py   # 活会话上的每个字段
"$REF/.venv/bin/python" engine/tests/parity_grain.py     # 分布
"$REF/.venv/bin/python" engine/tests/parity_lut.py       # 印放表，逐位
# 只需要本仓库的两个：
engine/build/gpu_smoke engine/resources/spektrafilm.metallib
engine/tests/check_math_guard.sh
```

- 全部加起来不到一分钟，每个抓一类不同的错误。
- `parity_render.py --size 180` 用小的合成帧，几秒跑完；不带 `--size` 用 1 MP 冒烟图（RFC-014 §3 规定）。
- 路径覆盖（`spk_test_paths.py`）：显式参数优先，其次环境变量 `SPEKTRAFILM_ENGINE_LIBRARY`（dylib）和 `SPEKTRAFILM_ENGINE_RESOURCES`（资源）。
- **检查发出去的就是测过的**：`build.sh bundle` 是 rsync，没跑时留下陈旧资源，所以要对着**已构建 `.app` 里的资源**跑一遍：

```bash
SPEKTRAFILM_ENGINE_RESOURCES=/path/to/SpektraLab.app/Contents/Resources/Resources/engine \
    PYTHONPATH="$REF/src" "$REF/.venv/bin/python" engine/tests/parity_lut.py
```

- **何时跑**：只在引擎输入、内核、资源或渲染边界改变时；纯界面提交不付这个代价（[12](./12-build-test-release.md) 第 4.1 节）。

## 4. 门槛为什么在那里

### 4.1 渲染门槛：3e-5 绝对误差 + 一个 16 位码值

`engine/tests/parity_render.py` 第 55–78 行、RFC-014 §8.3：

- RFC-011 当年把每个**节点**卡在 float32 存储精度上。端到端穿过 21 个节点（双三次查表、81 项光谱积分、CAM16 正逆变换）后累积误差更大，而且这是 GPU 的误差，不是移植的：同一帧、同一参考下，已验证过的 Python Metal 核心是 1.9e-5，这个 C++ 引擎是 2.3e-5。
- 所以绝对门槛定在 3e-5，略高于已验证核心能达到的值，而不是任何 GPU 路径都达不到的 epsilon。
- 单靠绝对门槛会藏住系统性偏移，所以配一个码值级门槛：几乎每个值都要落在一个 16 位码值以内（输出格式能表达的最小差异）。一个错的常数会先挂在第二个门槛上：这个脚本发现的印放平衡 bug 是 93% 画面差 2 个码值、绝对误差 2e-4，两个门槛都没过。
- **不要把它收紧到 float32 epsilon，也不要在没说明测量依据时放宽**（`AGENTS.md`「Do not」、`ARCHITECTURE.md` §8.6）。

### 4.2 固定的实验配置（`AGENTS.md`「Fixed experimental setup」）

所有记录的数字都假设这套配置，没有理由不要改：

| 项 | 值 |
|---|---|
| 胶片 | `kodak_portra_400` |
| 相纸 | `kodak_portra_endura` |
| 冒烟图 | `tests/Test_image/_smoke_1mp.tif`（1 MP，快速迭代） |
| 45 MP 帧 | `tests/Test_image/Nikon Z7ii/_DSC2439.NEF`（5504×8256） |
| 设备精度 | macOS 上 float32 |
| 颗粒采样器 | `exact`（RFC-002） |
| 工作精度 | float32（RFC-006 起默认；float64 是验证基线） |

一致性校验用 1 MP 帧：这是正确性问题，每次改动都能付得起的检查胜过最后才跑的检查。旧的 Python 时代测量工具（`scripts/gpu_native/`、`compare.py`、`tests/baseline/`）留在上游，`tests/baseline/` **不要恢复**。

### 4.3 关掉随机项

逐像素比较前关掉眩光和颗粒（或 `debug.deactivate_stochastic_effects`），关掉后整条流水线逐位可复现（陷阱 1）。除 `parity_exposure.py` 外，所有脚本都在 `auto_exposure = false` 下跑：两个引擎的测光从没在渲染里对比过，开着测光的渲染会把两种误差混在一起。

## 5. 有意的差异与已知问题

| 项 | 性质 | 怎么处理 |
|---|---|---|
| `camera.lens_blur_um` | 参考实现的 bug：sigma 由 `pixel_size_um` 推导，而它在第一次渲染前是 `None`，所以节点总被剪掉，0 和 50 µm 输出完全相同。C++ 引擎每次运行时计算 sigma，参数是生效的 | `parity_render.py` 断言两者**不同**；若哪天一致了反而失败（陷阱 22，RFC-014 §8.5） |
| 印放平衡用 sRGB 灰 | 参考实现的行为，看似疏忽 | **有意复现**为 `kMidgrayProbeColourSpace`（陷阱 21） |
| 输出色彩空间默认值 | RFC-018 把引擎声明的默认值改成 ProPhoto RGB（工作空间），参考实现仍声明 sRGB | `parity_schema.py` 第 49–64 行的 `KNOWN` 条目登记理由；若哪天两边又一致了，脚本报"登记的差异已过期"（陷阱 28） |
| 原生专有字段 | 参考实现冻结后新增的产品字段（反差蒙版、场景宽容度、片边、数据背、`filter_shift_scale`、`camera_filter` 等） | `parity_schema.py` 的 `NATIVE_ONLY` 精确列出；改名、改顺序、改路径/类型/层/默认值/live/范围，或参考实现某天也有了它，都会失败 |
| `dir_couplers_amount` > 约 1.736 | 模型本身的问题：成色剂逆运算的曝光轴不再单调，参考实现的输出取决于 numpy 的内部搜索；而协议允许到 4.0 | 已记录，未改范围（陷阱 22） |
| **`parity_exposure.py` 损坏** | 自 2026-09-17 起跑不通，原因不是驱动陈旧：参考实现拒绝参数名 `extended_dynamic_range`，C++ schema 从 `aa8bd63`（EDR，2026-09-17）起就有这个字段，上游没有 | 要么上游加上这个字段，要么脚本构造 Python 参数时去掉它，都归上游的维护者。在那之前，其余六个全绿要读成"六个"，不是"全部"（脚本文件头） |

## 6. 一致性校验看不到的东西

**全绿的一致性校验不等于画面正确**（陷阱 23）。移植中的六个真实 bug 里有两个不在任何脚本的覆盖范围内，因为脚本直接给引擎一个 numpy 数组，从不经过应用自己的文件读取：

- `readLinearRGB` 里的**上下翻转**：冲洗正确、上下颠倒的照片，27 个用例全绿；
- 结果**纹理归帧内存池所有**，调用方还没画就被释放了。

现在由 `testTheFrameIsReadTopRowFirst` 和 `testEachTierRendersAtItsOwnResolution` 固定。**要看截图**：`--snapshot` 很便宜，而且是唯一能看到用户所见的检查（[12](./12-build-test-release.md) 第 5 节）。

另一类：缓冲在"释放"后、命令执行完之前就被复用，导致 27 个渲染用例错 25 个，没有崩溃、没有报错（陷阱 19）。这一类一致性校验抓得到，前提是改完引擎**确实跑了**，而且 C++ 驱动不是陈旧的。

## 7. 重新烘焙资源

`engine/resources/` 入库（约 15 MB），全新检出构建时无需烘焙。只有当上游数据或烘焙逻辑变化时才需要用 `engine/tools/bake_resources.py` 重新生成，这同样需要上游 Python 环境（`PYTHONPATH=<上游>/src`）。> 与英文文档的出入：`AGENTS.md` 说烘焙和一致性校验的步骤见 README 的「Parity harnesses」「Rebaking the engine resources」两节，但当前 `README.md`（已通读）没有这两节。具体烘焙命令本次未核实，需要时读 `engine/tools/bake_resources.py` 本身。
