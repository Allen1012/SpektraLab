# 12 构建、测试与发布

> 用途：从干净的检出到跑起应用、跑对测试、截出能当证据的图、打出发布包的全部步骤，以及每一步最容易骗人的地方。引擎的一致性校验单独见 [16](./16-parity.md)。

## 1. 环境

| 项 | 要求 |
|---|---|
| 硬件与系统 | Apple 芯片，macOS 15+ |
| Xcode | 26.6 |
| Python | 只给 `Tools/*.py` 生成器用，标准库即可；**本仓库没有虚拟环境，运行时没有 Python** |
| 上游参考实现 | 只在跑一致性校验或重新烘焙资源时需要，路径约定为 `~/Documents/Summer 2026/spektrafilm`（`AGENTS.md`「Environment」） |
| 测试图片 | 通过 git 忽略的 `tests` 符号链接引入（见第 4.3 节） |

## 2. 构建

### 2.1 最短路径

```bash
engine/build.sh bundle                 # 编译着色器、同步引擎资源进应用
cd modern_UI/Spektrafilm
xcodebuild -project Spektrafilm.xcodeproj -scheme Spektrafilm \
           -derivedDataPath build/DerivedData build
```

`engine/resources/` 改了就要重新跑 `engine/build.sh bundle`。如果 Xcode 突然找不到 `metal`，清理构建目录（⇧⌘K）：Metal 工具链的挂载路径在缓存的构建下变了（`README.md`）。

### 2.2 `engine/build.sh` 子命令

| 子命令 | 做什么 |
|---|---|
| `metallib` | 用 `-fmetal-math-mode=safe -fmetal-math-fp32-functions=precise -mmacos-version-min=15.0 -Werror` 编译所有 `src/shaders/*.metal`，链接成 `spektrafilm.metallib`，检查 macOS 平台标记，拷到 `resources/` |
| `lib` | metallib，然后 `libspektrafilm_engine.a` |
| `dylib` | metallib，然后 `libspektrafilm_engine.dylib`（`ctypes` 校验脚本加载的就是它） |
| `tests` | 编译 `dump_setup`、`dump_json`、`gpu_smoke` 三个 C++ 驱动；不编 metallib |
| `bundle` | metallib，然后 `rsync --delete resources/` 到 `modern_UI/Spektrafilm/Spektrafilm/Resources/engine`，再拷入 `resources_product/profiles/*.json` 和 `NOTICE.md`（改名 `PRODUCT_PROFILES_NOTICE.md`） |
| `all`（默认） | metallib、lib、dylib、tests、bundle |

- C++ 用 `-std=c++20 -O2`，只编 `src/core`、`src/gpu`、`src/pipeline`。
- **着色器由 `build.sh` 编译，不由 Xcode 编译**：应用目标为画布设了 `MTL_FAST_MATH = YES`，沿用它会让 `exp` 和 fma 收缩漂移超过 float32 容差且无声无息。引擎启动时的快速数学探测会拒绝快速数学编译的 metallib（[05](./05-engine-boundary.md) 第 7 节）。**不要删掉这两个安全数学参数，也不要把内核挪进 Xcode 目标**（`AGENTS.md`「Do not」）。
- `bundle` 是 rsync：没跑时留下的是**陈旧**的资源而不是空目录（陷阱 14）。
- `build.sh dylib` **不会重建 C++ 驱动**；改了引擎后要 `build.sh tests`，否则有三个校验脚本会用旧引擎给出"通过"（`ARCHITECTURE.md` §8.6）。

### 2.3 Xcode 工程由脚本生成

```bash
cd modern_UI/Spektrafilm
python3 Tools/gen-project.py          # 增删任何源文件后必须重跑
python3 Tools/gen-project.py --check  # 只检查工程是否过期
```

- `project.pbxproj` 由文件系统生成，也列出引擎的 C++ 编译单元。**新增 `engine/src/**/*.cpp` 也要重跑**：漏了的话这个文件根本不会被编译，报的是"缺符号"的链接错误，不会指向文件本身。漏了 `.swift` 报 `cannot find X in scope`，看起来像少了 import。
- 对象 id 是文件**相对于工程**路径的 sha1，所以两份检出生成的字节相同。以前用绝对路径，git 工作树和主检出生成的文件只有 1400 个 id 不同，任何合并都会在双方都没改的地方冲突（`AGENTS.md`「The app」）。
- 版本号只在这里定义：`MARKETING_VERSION`（第 83 行）、`BUILD_NUMBER`（第 84 行）。不是发布的修复不改版本号。

### 2.4 其他构建脚本（`modern_UI/Spektrafilm/Tools/`）

| 脚本 | 作用 |
|---|---|
| `gen-catalog.py` | 从 `engine/resources/profiles`、`engine/resources_product/profiles`（标 `monochrome`）、`print_luts.json`、`modern_UI/film_covers`，以及卡片数据 `modern_UI/stock_guide.json`、`modern_UI/stock_traits.json`、`modern_UI/stock_art/` 生成 `Resources/StockCatalog.json`、`FilmCovers/` 和 `StockArt/`；未知的场景标签直接报错 |
| `engine/tests/stock_traits.py` | 测量每款胶片和相纸的反差、饱和度、宽容度、颗粒，写 `modern_UI/stock_traits.json`；只需要 `engine/build.sh dylib`，不需要 Python 参考实现。之后要重跑 `gen-catalog.py` |
| `bundle-licenses.sh` | 把 GPL-3.0、CC BY-SA 4.0、Apache-2.0 文本拷进 `Resources/Licenses` |
| `check-bundle-resources.sh` | 应用目标的构建前阶段，也可单独运行：引擎资源或许可证文本缺失时让构建失败 |
| `make-smoke.py` | 生成 1 MP 的线性 ProPhoto 冒烟测试图 |
| `render-icon.swift` | 从构建好的 `.app` 渲染图标 PNG |
| `compare-layout.py`、`measure-layout.swift`、`compare-design.swift` | 截图与设计稿的尺寸、像素对比 |
| `snapshot.sh`、`capture-live.sh`、`live-window.swift` | 截图，见第 5 节 |
| `package.sh` | 打包，见第 6 节 |

许可证文本**不是装饰**：应用包里有 CC BY-SA 配置和 GPL 二进制，`LicensingTests` 断言文本存在且能通过「关于」窗口用的同一个访问器读到。

### 2.5 持续集成

`.github/workflows/build.yml`（macos-26，Xcode 26.6）只回答"干净检出能不能构建"：`engine/build.sh bundle` + Debug 构建，**刻意不跑测试**。`desktop.yml` 属于 Linux/Windows，不在本知识库范围内。

## 3. 测试目标

| 方案（scheme） | 内容 | 耗时 |
|---|---|---|
| `SpektrafilmTests` | 完整测试：60 个文件、67 个测试类、561 个测试方法（`func test` 计数） | 有测试图片时约 6–7 分钟 |
| `SpektrafilmFrontend` | 除真实底片类以外的全部 | 约 7 s（`ARCHITECTURE.md` §9） |
| `engine/tests/` | 一致性校验、`gpu_smoke`、`check_math_guard.sh` 等 | 见 [16](./16-parity.md) |

```bash
xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmTests \
    -configuration Debug -derivedDataPath build/DerivedData test
xcodebuild … test -only-testing:SpektrafilmTests/<类名>     # 只跑某个类
```

测试目标是独立的（没有 TEST_HOST），把应用源码和引擎源码一起编译进来。`EngineClientTests` 从 Swift 侧覆盖 C 接口边界。

> 与英文文档的出入：完整套件的规模和耗时在各文档里不一致：README 约 550 个、约 6 分钟；`ARCHITECTURE.md` §9 约 550 个、约 350 s；`AGENTS.md` 约 430 个、约 420 s（陷阱 26 里实测 375 s）。代码里现在是 561 个测试方法。耗时没有在本次重新测量。

## 4. 测试纪律

### 4.1 分级（`AGENTS.md`「Test gates」）

- **开发中**：只构建受影响的目标，只跑覆盖改动的类（`-only-testing:`）。新回归测试要先在旧行为或故意弄坏的行为上**红**，再变绿。
- **一组连贯提交之后、合并或推送之前**：完整跑一次 `SpektrafilmTests`。
- **引擎一致性校验**只在引擎输入、内核、资源或渲染边界改变时跑；纯界面提交不付这个代价。
- 提交信息里记下跑了哪一级。

### 4.2 什么测试结果不能信

| 情况 | 现象 | 出处 |
|---|---|---|
| 测试图片缺失 | 跳过 25 个用例，约 18–20 s 跑完，**同样报 0 失败** | 陷阱 26 |
| 测试二进制陈旧 | `xcodebuild test` 直接管道给 `grep` 时可能报上一次构建的失败；看起来不可能的失败先再跑一次 | `AGENTS.md`「The app」 |
| 依赖共享设置 | 前一个测试类写进 `UserDefaults.standard` 的值决定后一个类的结果，失败指向错误的文件 | 陷阱 24 |
| 栈溢出 | 是崩溃不是失败，测试运行会重启（"Restarting after unexpected exit"），要读成"有测试没跑完" | 陷阱 25 |
| 守卫只在禁用被守对象的配置下被测试 | 测试通过但什么都没检查 | 陷阱 16 |
| 单元都对、界面不对 | 导航器曾显示未裁切的照片而所有测试都绿 | 陷阱 33 |

### 4.3 测试图片与 `tests` 符号链接

- 相机测试图片不在本仓库，在上游 `spektrafilm` 仓库里；`tests/Test_image/` 在这里被 git 忽略。
- 每份检出通过一个 `tests` 符号链接拿到它们，**而这个链接在每份检出里正确的目标都不同**：git 工作树指向主检出，主检出指向 `../spektrafilm`（`ln -s ../spektrafilm/tests tests`）。所以它被忽略而不是仅仅未跟踪。它曾被 `git add -A` 提交过一次，结果在主检出里指向了自己。
- 自检：`git check-ignore -v tests` 应输出 `.gitignore:/tests`；`ls tests/Test_image/A7m3` 应列出 ARW 文件。
- **看耗时，不看失败数**：完整运行几分钟，不到一分钟说明图片不在。

### 4.4 写测试的规矩（`AGENTS.md`「Conventions」）

- **测试拥有自己的输入**：给需要持久设置的代码注入一个临时 `UserDefaults` 套件（`Session.previewEdge(in:)`、`PanelWidthStore` 都支持），不要读共享存储；打开测试图片前先复制（冲洗会写 sidecar）。
- **任何显示画面的界面都要在 `SurfaceAgreementTests` 里加一个用例**：给帧加一个裁切和一次 90° 旋转，读这个界面，与画布比较（陷阱 33）。已知缺陷用 `XCTExpectFailure(strict: true)` 固定，修好那天测试会变红，提醒去掉标记。
- **任何代替用户改变当前帧的操作都要检查 `batchExporting`**（陷阱 34）。
- **守卫必须被看到触发过**：测试脚本级的检查要带一个不加修复就能复现 bug 的对照（`TypingKeyGuardTests`、`check_math_guard.sh`）。
- **在变化过程中判断**：前后都对的画布，中间也可能显示错的东西（重新解码时裸解码盖在胶片画布上）。这类测试在变化**期间**采样画布（`testTheFilmCanvasStaysUpWhileItsFrameIsDecodedAgain`）。

## 5. 截图与运行时观测

| 工具 | 用法 | 盲区 |
|---|---|---|
| `Tools/snapshot.sh [image.NEF]` | 离屏截图，三种窗口尺寸；底层是 `--snapshot` 启动参数 | 经 `cacheDisplay` 渲染，**看不到 `CAMetalLayer`**，用离屏渲染的画布代替。曾因此漏掉一个 `CAMetalLayer` 拒绝的像素格式（应用启动即崩）和一次没到达视图的重绘（画布空白、数字正确）。也不能裁判界面颜色（陷阱 27） |
| `Tools/capture-live.sh [image.NEF]` | 通过 window server 拍**真实窗口** | 唯一能证明画布真的在画的截图；需要有图形界面的会话，`CGWindowListCopyWindowInfo` 几乎没有窗口时是环境问题。**会强制退出所有正在运行的 SpektraLab** |
| 进程内测试 | — | **看不到卡顿**：没有 display link，所以没有东西会被饿死。真实窗口里 113 ms 卡住的折叠动画，在测试进程里 174–181 ms 顺利跑完 |
| `SPEKTRAFILM_CANVAS_LOG=1` | 每次绘制一行，外加打开路径各阶段耗时 | 主线程被饿死时日志里会出现绘制行的空白：空白里没有绘制说明布局本身贵，绘制还在跳说明布局让画布做了更多事 |

打开路径的日志样例（`AGENTS.md`「The app」，请勿删除 `Session.LoadClock` 这个计量器）：

```
session: open path (ms): decode 76 · preview-texture 195 · linear-tiff 51
         · service.open 1613 · solve 30 · reprint 44 · TOTAL 2011
         · core=native-metal
session: full render requested for DSC03710.ARW
session: full render <w>x<h> landed in <n> ms
```

- **先看 `core=native-metal`**，这是唯一可能的值；不是它就说明没在跑这个引擎。
- `service.open` 沿用旧名，现在量的是 Core Image 把线性解码渲染成浮点位图再上传，24 MP RAW 上它占大头。
- `full render … landed` 表示原分辨率的帧已上画布，画布右上角 `full` 标记是同一件事。渲染太慢时这一行永远不出现（结果因代数变化被丢弃），应用看起来像从没显示过原分辨率。

截图的辅助参数：`--zoom`、`--geometry`、`--mask`、`--compare`、`--pair-layer`、`--pair-zoom` 等（[06](./06-api-reference.md) 第 6 节）。截图是**它自己那个窗口**的：场景里的窗口也有一个离屏替身，必须不绘制（`snapshotCapture`），否则截到的是另一个缩放下的空白画布（`ARCHITECTURE.md` §9）。

`screenshots/` 必须与当前界面一致，改了就在提交里说明。截图来自运行中的应用而不是截图脚本；1:1 颗粒图永远不要重采样；主截图是用户自己拍的，替换前先问（`AGENTS.md`「Conventions」）。

## 6. 发布

| 项 | 现状 | 出处 |
|---|---|---|
| 签名 | 强化运行时、空权限、**ad-hoc 签名**。发布是 GitHub 预发布的 zip，说明里附 `xattr` 去隔离命令。这是用户的决定（不用 Developer ID，**不要再提议**） | `ARCHITECTURE.md` §5、`AGENTS.md`「Conventions」 |
| 最低系统版本 | 在产物上检查：`LSMinimumSystemVersion` 15.0，每个 Mach-O 都是 arm64 且 `minos` ≤ 15，每个 metallib ≤ 15。0.3 版曾发出过一个按主机系统标记的 metallib | `ARCHITECTURE.md` §5 |
| 打包脚本 | `Tools/package.sh [--dry-run]`：归档 → 导出 → 验签 → 检查最低版本 → DMG → 公证 → staple → `spctl` | `Tools/package.sh` 文件头 |
| 打包所需凭据 | 环境变量 `SPEKTRAFILM_SIGN_IDENTITY`、`SPEKTRAFILM_TEAM_ID`、`SPEKTRAFILM_NOTARY_PROFILE` | 同上 |
| 更新提示 | 设置 ▸ General 按需检查 GitHub 最新发布（RFC-021）；应用不联系任何别的地方 | `ARCHITECTURE.md` §5 |

> 与英文文档的出入：`ARCHITECTURE.md` §5 说 `package.sh` 没有 Developer ID 时以退出码 1 结束；脚本文件头注释说没有凭据时仍会归档、导出、生成 DMG，最后大声说明结果是 ad-hoc 签名。本次未运行脚本核实。
