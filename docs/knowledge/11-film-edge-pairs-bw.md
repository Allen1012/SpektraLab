# 11 片边、数据背、半格双拼、黑白

> 用途：说明四个产品特性各自的用户行为和实现位置：片边（Film Edge）、数据背（Date Back）、半格双拼（half-frame pair）、黑白胶片。它们都改变了"引擎拿到的是哪一帧"，所以和普通参数编辑的规则不同。

## 1. 片边（Film Edge，设计记录 RFC-032）

### 1.1 用户看到的

在左栏 Film Edge 选一个格式，画面就按该格式的片窗裁出来，放在胶片条上：片基边、齿孔、该胶片自己的片边字和可设置的帧号；条状扫描在胶片边缘结束。裁切变成片窗里的取景，所以它属于底片的一部分（`README.md`）。

### 1.2 关键规则（`ARCHITECTURE.md` §7.11）

- **胶片就是画布。** 打开片边后，引擎拿到的是**按裁切切好**的解码，返回整张胶片画布（片窗、片基边、齿孔）。所以裁切进入了底片：
  - `FilmParams.cutsFrame` 是唯一的判断："引擎拿到的帧是不是被切过的"；
  - 显示胶片时 `Session.canvasGeometry` 是恒等几何；
  - 裁切工具在胶片打印之上框选解码（`filmEdgeFraming`）。
  - 只开数据背、且有裁切/旋转/翻转时，帧同样会被切。
- **重新解码时保持胶片。** 改白平衡、半格对某帧移动都会重新解码；裸解码是另一个形状、没有胶片，所以不会盖在即将被替换的胶片画布上（`Session.holdsFilmCanvas`）。没有片边时新解码照常立即显示。
- **片边字是胶片自己印的字**（`Session.edgeText`），从不用营销名称；引擎不会自己印任何厂商名。
- **打印戳包含取景**（`Session.printStamp`）：同样的参数、不同的取景，就是另一张画。
- 片边模式只能整帧渲染（条带执行器拒绝它），超出纹理上限的帧在冲洗前就被拒绝，并用文字说明（`Session.filmEdgeRefusal`）。
- 有片边时引擎按片窗尺寸换算胶片的物理尺寸，忽略 `film_format_mm`（API-SPEC §13）。

### 1.3 格式表（`engine/src/pipeline/overscan.cpp` 第 105–121 行 `kFormats`）

| 格式名 | 胶片宽 mm | 片窗横跨 mm | 片窗沿片 mm | 齿孔 | 该格式真实相机的片窗形状 |
|---|---:|---:|---:|---|---|
| `135` | 35.0 | 24.3 | 36.25 | 有 | square |
| `135_half` | 35.0 | 24.0 | 18.0 | 有 | square |
| `120_645` | 61.0 | 56.0 | 41.5 | 无 | eared rounded |
| `120_6x6` | 61.0 | 56.0 | 56.0 | 无 | kicked square |
| `120_6x7` | 61.0 | 56.0 | 69.5 | 无 | square |
| `120_6x8` | 61.0 | 56.0 | 76.0 | 无 | shouldered |
| `120_6x9` | 61.0 | 56.0 | 84.0 | 无 | square |
| `135_xpan` | 35.0 | 24.0 | 65.0 | 有 | square |
| `120_6x12` | 61.0 | 56.0 | 112.0 | 无 | square |
| `120_6x17` | 61.0 | 56.0 | 168.0 | 无 | square |

- 135 的片窗按相机实测而不是 ISO 的 36×24：七条底片上量得 36.0–36.6 × 24.0–24.8（均值 36.25 × 24.3），离齿孔 0.47–0.67 mm。
- XPan 每帧走 14 个齿孔（66.5 mm）。三种宽幅格式在量到真实底片之前都用 square 片窗，且都不带日期。
- 应用侧的同名枚举是 `Model/FilmEdge.swift` 的 `FilmEdgeFormat`；`StockCatalog.isMade(in:)` 判断某胶片是否生产过该格式（电影负片可装进 135 暗盒，不排除 135 格式，但没有 DX 码）。

### 1.4 每种胶片的片边外观（`overscan.cpp` 第 151–222 行 `kEdgeLooks`）

每行：胶片 id、135 布局（`Edge135::Kodak`、`FujiNeg`、`FujiSlide`、`Ilford`、`Cine`）、120 布局（`Edge120::Kodak`、`Fuji`）、片边字打印机对三层的曝光、曝光档数、数字字重、富士 120 名称后的代码（如 Pro 400H 的 `EFCDCD`）。颜色按车主的真实底片扫描测得（2026-10-03）。四款黑白胶片各有一行，HP5 Plus 有自己的 135 布局 `Edge135::Ilford`。

### 1.5 引擎里的三个节点（`ARCHITECTURE.md` §2、§8.10）

| 节点 | 位置 | 做什么 |
|---|---|---|
| `filming.expose.overscan` | 胶片侧，boost 之后、光晕之前（整帧） | 片窗外胶片的曝光：片边字、雾、漏光、日期。放在光晕之前，所以它们和画面一样会辉光、显影、出颗粒 |
| `printing.overscan.film_present` | 印放侧最前面 | 胶片在相纸上的存在（片基边、孔） |
| `printing.overscan.light` | 扫描最后，锐化之后 | 扫描光穿过齿孔和胶片外缘 |

孔的边缘柔度与扫描一致（σ 17 µm 加一个像素）。`spk_overscan_geometry` 返回片窗位置（归一化），应用据此定位，从不猜（`EngineClient.overscanGates`）。

### 1.6 线上字段（API-SPEC §13，全部 shoot 层、非 live）

| 字段 | 默认 | 含义 |
|---|---|---|
| `overscan_active` | false | 总开关；false 时不派发任何东西，与引入前逐字节一致 |
| `overscan_format` | `135` | 上表十种之一 |
| `overscan_mode` | `strip` | `strip` 整条胶片宽，`filed` 锉过的底片夹只露一条片基边 |
| `overscan_gate` | `auto` | 片窗形状族；`auto` 让相机种子从该格式真实相机的形状里选 |
| `overscan_holes` | `white` | 齿孔里透出什么：`white` 扫描的光，`black` 黑背板或暗房印相 |
| `overscan_camera_seed` | 1 | **机身**：片窗形状与圆角、毛刺、片窗到乳剂的间隙、画面在齿孔上的位置、雾、眩光 |
| `overscan_frame_seed` | 1 | **过片与扫描**：晃动、过片误差、扫描旋转、漏光，以及帧号为 0 时片边上的数字 |
| `overscan_frame_number` | 0 | 片边上的帧号；0 用帧种子抽，设了就是这一帧自己的号，邻帧依次计数 |
| `overscan_carrier` | `none` | 条状扫描时胶片长边之外显示什么：`none`（1.3.1 起默认，画布在胶片边缘结束）、`black`、`open` |
| `overscan_pair` | false | 半格双拼放在一条胶片上，只用于 `135_half`；第二张从 19.00 mm 处开始，整帧 37 × 24 |
| `overscan_fog` | 1.0 | 边缘雾强度，0–4 |
| `overscan_leaks` | 0.0 | 暗盒漏光的数量和强度，0–4 |
| `overscan_edge_text` | `""` | 片边字，由宿主决定（桌面用真实名称） |
| `overscan_f_number` | 0.0 | 来自 EXIF，决定片窗半影；0 表示未知（按 f/5.6） |

边缘光的三种来源（雾、漏光、片窗眩光）都是加在原始曝光上的光，在光晕之前加入，所以和画面一起显影、辉光、出颗粒。

## 2. 数据背（Date Back，RFC-031）

### 2.1 用户看到的

把拍摄日期（或手输的日期）曝光进画面，不需要片边。有片边时还可以在画面旁同时印拍摄数据；在 120（645 到 6×9）上，日期和数据印在片基边上，就像中画幅数据背那样（`README.md`）。

### 2.2 线上字段（API-SPEC §13）

| 字段 | 默认 | 含义 |
|---|---|---|
| `date_imprint_active` | false | 开关；片边开或关都能用 |
| `date_imprint_style` | `lcd` | `lcd` 斜体七段码；`dots` 竖直 5×7 点阵；`data` 5×7 拍摄数据字体 |
| `date_imprint_text` | `""` | **由宿主格式化**，如 `'26 10 1` 或 `Av 1/125 F2.8 +1.0Ev 45mm SPOT ISO 200`；5×7 字体只画 0–9、A–Z、m v s 和少量符号 |
| `date_imprint_text_b` | `""` | 半格对第二张的日期 |
| `date_imprint_data_text` | `""` | 日期之外**再印**拍摄数据（1.3.1），需要片边；135 印在帧间，120 印在片基边 |
| `date_imprint_placement` | `frame` | `frame` 画面里，`rebate` 帧之间（需要片边） |
| `date_imprint_corner` | `br` | 以**胶片**的方向为准（相机水平持握时），不是画面方向 |
| `date_imprint_inset_x` / `_y` | 3.0 / 2.4 | 离片窗边的毫米数 |
| `date_imprint_size` | 1.0 | 字高缩放（lcd 1.3 mm、dots 0.95 mm、data 0.50/0.55 mm） |
| `date_imprint_ev` | 3.5 | LED 曝光，相对 18% 灰的档数 |

拍摄数据只以类型化的值进入像素（数据背文字、片窗的光圈值，`ShootingData`，RFC-033）；EXIF 字典本身从不进入引擎（`ARCHITECTURE.md` §7.8）。

## 3. 半格双拼（half-frame pair）

### 3.1 用户看到的

两张照片放在一格 135 上，左右或上下排列，每张有自己的曝光、白平衡、印放和调色。Film Edge 选 *Half* 后，格式下方出现 **Enter Half-Frame Pair**（或选两张照片按 ⌘J）。画布上有两个孔，空孔显示 **+**。点一个孔选中它：Input / Camera、Scene Placement、Enlarger 和 Post-Dev 都只作用于这一张；*+ Film* 让胶片也跟着变。右键孔可以替换、旋转、裁切；裁切模式下拖动移动画面，滚轮或捏合以指针为中心缩放。一对在胶片条上算一项，导出为一张图（`README.md`）。

### 3.2 实现要点（`ARCHITECTURE.md` §7.12）

| 方面 | 规则 | 代码 |
|---|---|---|
| 文件形态 | **一对就是一个文件**：`Sidecars/Pairs/*.spektrapair`（JSON），它的 URL 是胶片条上的一个 `Frame`。它引用两帧，不拥有它们；它的观感是该 URL 的普通 sidecar | `Model/HalfFramePair.swift` |
| 解码 | **合成解码**：每帧按自己的白平衡解码、按自己的几何取景，放到自己的孔下（`Hole.placement`：缩放、x、y、90° 旋转次数），拼成一张，间隙为黑，长度不超过一帧。每个孔按它依赖的一切做键缓存；显示侧用文件的内嵌预览 | `Import/PairComposer.swift` |
| 测光 | **每孔单独测光**：引擎的测光会把两张图和间隙当成一个场景，所以每个孔单独测，把增益乘到整张上（引擎的自动曝光恰好就是 2^EV 的增益），并关掉引擎自己的测光 | `PairComposer.exposed` |
| 印放 | **按帧印放**：一张底片在一次 actor 调用里最多印放三次（`EngineClient.renderLayers`），分别调色，再由 Metal 内核拼起来（`Renderer.compositePair`）。没有任何一帧单独印放或调色时（`pairIsLayered` 为假），整张就是一次印放，上述步骤都不执行 | `Session.swift`、`Canvas/Renderer.swift` |
| 右栏作用于选中帧 | `focusSide`：测光、胶片曝光、白平衡和镜头校正（写进那一帧自己的 sidecar）、Scene Placement（`scene_latitude_split` 和 `scene_latitude_b_*` 字段）、Enlarger、Post-Dev，并有 *Frame / + Film* 作用范围。选中胶片时，Enlarger 会把每一帧自己的印放一起移动 | `Model/Session.swift`、`Panels/Sections/CameraSection.swift` |
| 裁切手势 | **一次手势一次写入**：拖动、滚动、捏合、滑块会立即在孔下显示取景预览（`PairDrag`），停下时才写入：一步撤销、一次保存、一次冲洗。预览保持到冲洗落地；8 秒仍未落地就强制收起（[07](./07-scheduled-tasks.md)） | `Session.commitPlacement` |
| 引擎侧 | `overscan_pair` 让片窗曝光两次，间隙是未曝光的胶片；片边字、雾、漏光、光晕跨越两张，就像一条胶片 | API-SPEC §13 |

## 4. 黑白

### 4.1 数据（`engine/resources_product/`）

| 文件 | 内容 |
|---|---|
| `profiles/kodak_tri_x_400.json`、`kodak_tmax_100.json`、`fujifilm_neopan_acros_100_ii.json`、`ilford_hp5_plus_400.json` | 四款黑白胶片配置（Tri-X 最早，其余三款 2026-10-09 加入） |
| `profiles/ilford_multigrade_iv_rc.json` | Ilford Multigrade IV RC 相纸 |
| `paper_grades.json` | Multigrade 号数 → 线上字段（`c/m/y_filter_neutral`、`print_exposure`）；在 Tri-X 上拟合，光源 TH-KG3；同一张表也适用于另外三款胶片 |
| `neutral_print_filters.json` | 相纸的中性滤色行 |
| `NOTICE.md` | 每份数据的来源 |

`engine/build.sh bundle` 把这些配置放进应用的 `Resources/engine/profiles/`，与 spektrafilm 的 28 个并列；`Tools/gen-catalog.py` 给它们标 `monochrome`。

### 4.2 应用里的行为

| 方面 | 规则 | 代码 |
|---|---|---|
| 是否提供 | `FeatureFlags.blackAndWhite` 为 true（1.3.3 起所有构建）；关闭时目录不列出它们，任何选择器、菜单、agent 工具都不提供 | `Model/FeatureFlags.swift`、`Model/StockCatalog.swift` |
| 胶片与相纸配对 | `StockCatalog.canPrint(film:on:)`：两者 `isMonochrome` 相同才能配对；目录里没有的 id 一律放行 | `Model/StockCatalog.swift` 第 133–136 行 |
| 胶片选择器 | 黑白是第三个胶片分组 | `AGENTS.md`「Black and white」（具体视图文件未核实） |
| 颗粒 | 黑白胶片发 `grain_sublayers_active = false`（单层乳剂）；`grain_amount` 乘以每款胶片自己的系数 `FilmParams.ownGrain(of:)` | `Model/Params.swift` 第 593、750、789 行 |
| 放大机 | Multigrade 2 号滤色作为线上的中性滤色组合发送：(C, M, Y) = (0, 0, 68) | `Model/Params.swift` 第 573–579、816 行 |
| EDR（扩展动态范围） | 黑白不用 | `AGENTS.md`「Black and white」 |
| 还没有的 | 镜头滤镜和相纸号数的控件（引擎都已支持：`camera_filter`、`paper_grades.json`）；这也是开关还保留着的原因 | `FeatureFlags.blackAndWhite` 注释 |

> 与英文文档的出入：`AGENTS.md`「Black and white」写"没有每款胶片单独的颗粒量"，而 `FeatureFlags.swift` 的注释和 `FilmParams.ownGrain` 表明现在每款胶片的颗粒是各自的。以代码为准。

### 4.3 引擎侧唯一的改动：`camera_filter`（API-SPEC §15）

- 字符串，shoot 层，默认空。可选 Kodak Wratten 编号：`w8 w11 w12 w15 w21 w25 w47 w58`；其他值被拒绝并列出可选值。
- 滤镜透过率（`engine/src/core/camera_filters.hpp`，380–780 nm、5 nm）在建上采样表之前乘进胶片感光度；setup cache 按得到的感光度做键，所以别的都不用改。
- **滤镜因数已经算好**：一个标量（绿敏层在胶片参考光源下的比值）除掉结果，所以单层乳剂上 18% 灰曝光不变，彩色胶片保留滤镜的偏色。自动曝光测的是输入，看不到滤镜。
- **只有画面经过镜头**：片边字、雾、日期读的是不带滤镜的感光度 `film_sensitivity_edge_`。
- 数据来自 Kodak B-3 表的第三手转录；与 Tri-X 400 公布的滤镜因数相比，七个里六个在 0.21 档以内，58 号高 0.67 档。

### 4.4 已知局限

- Tri-X 的颗粒、锐度、光晕仍是彩色默认值，渲染的 RMS 颗粒度约 7，而数据表是 17（`AGENTS.md`）。
- 研究资料（哪些是实测、哪些是假设）：`research/black-and-white-tri-x.md`、`research/black-and-white-three-more-films.md`、`research/colour-film-granularity.md`。`/research` 在 `.gitignore` 里，这些文件是手动强制加入的。
- 检查脚本：`python3 engine/tests/bw_checks.py`，只需要 `build.sh dylib`，不需要 Python 参考实现。它在临时目录里把 `resources_product/` 叠加到 `resources/` 上。
