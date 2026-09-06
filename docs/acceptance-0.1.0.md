# Printroom 0.1.0 验收记录

日期：2026-09-07。验证对象是本次本地交付的源码与 `output/Printroom-0.1.0.app`；对应提交可用 `git log -1` 查询。算法 `printroom-density-v1`，项目 schema 1。设备 Apple M4、macOS 26.6.2、Xcode 26.6、Swift 6.3.3。

## 初版交付结果（预览修正前）

**release 完整验收 71 项通过，0 失败：64 项 XCTest 核心测试 + 7 项 Swift Testing 应用集成测试。**

```sh
scripts/test.sh --full -c release
scripts/build-app.sh Printroom-0.1.0
codesign --verify --strict --verbose=2 output/Printroom-0.1.0.app
shasum -a 256 -c assets/SHA256SUMS
```

详细本机日志：`scratch/acceptance-tests.log`（不纳入 Git）。GPU 测试使用本机 Metal 权限；受限执行环境无法创建 GPU 上下文时，不能把该错误当作测试通过。

| 验证项 | 实际结果 |
| --- | --- |
| CPU 算法 | 26 项通过；密度/CV、LED 原始系数与 RGB 方向、中位数、校准、Timing、Contrast、LUT 插值/边界和非法值 |
| 项目与选择 | 26 项通过；稳定 ID、发现/重开/整卷移动、原子保存、损坏/未来版本/冲突/只读保护、多选、快照覆盖 |
| TIFF | 11 项通过；大小端、Deflate、水平预测、八种 orientation、位深/profile 保留、条带写入、取消清理、目标竞争保护 |
| CPU/Metal | 4099 样本 × 2 矩阵 × 3 组调色 × 7 阶段；最大绝对误差 3.8146973e-6，满足各阶段与 Final 的误差预算 |
| 原始参考 TIFF | 10 张各 98,224,128 个 UInt16 通道样本，与独立 Python/zlib 解码的完整样本 SHA-256 一致 |
| 全尺寸文件写入 | 7008×4672、98,224,128 样本全部精确回读；无压缩输出 196,450,226 字节 |
| 实际完整管线导出 | DSC07079、记录的原始片基 ROI、LED 矩阵与非默认调色；7008×4672 回读，CPU 抽样最大误差 7.748604e-6（含最终量化） |
| ICC | 全尺寸和小图回读均为正确 P3 D65 Gamma 2.6；嵌入 bytes 与工作 ICC 完全一致 |
| 应用集成 | 7 项通过；完整管线、快照/批量 Undo/Redo/重开、滑块单组撤销、W/S 均 +1、显示源 ICC/数值、保存冲突恢复、同路径换图的缓存失效 |
| 原始资产完整性 | 12/12 个原始文件 SHA-256 与 M0 清单一致 |
| 应用包 | arm64、约 2.6 MB、本地 ad-hoc 签名通过；从 `/private/tmp` 调用包内 `--verify-resources` 成功校验 ICC/LUT 并运行 Metal |

实际照片导出计时为 0.858 秒，**计时前已载入源图**，测量包括管线计算与 TIFF 写入，不包含首次读取、用户操作或输出回读；单次本机测量不代表通用性能承诺。最终性能优化和跨设备基准仍在下一轮。

## 实际窗口检查

所有代理操作使用 `scratch/QA Roll` 内的原图副本，没有在 `TEST/` 写入项目、缓存或输出。

- 打开包含 10 张 TIFF 的文件夹，显示正确文件名、尺寸与 Filmstrip。
- 在 DSC07079 未曝光边缘框选，落到原图 ROI `(x:359, y:604, width:79, height:494)`；整卷 gain/offset 更新，实际照片由未校准偏色画面转为正片外观。
- 第一张设置 Master=30，复制后选择全部 10 张并点击应用；读取旁存 JSON，10 张均为 30。
- 一次 ⌘Z 后旁存 JSON 恢复第一张 30、其余 9 张 0，证明整组恢复了各自原值。
- 关闭并重新打开应用/胶卷，片基、逐帧参数与缩略图恢复。
- 主预览、片基框选、数值输入、选择数量、复制来源提示与自动保存状态可操作。

用户随后开始试用该开发窗口。最终应用包另存为 `Printroom-0.1.0.app`，保留现有窗口及其测试卷调色，没有为验收清空用户正在试用的设置。完整尺寸导出使用与界面相同的 ImageService 进行自动化验证；没有宣称完成实际显示器硬件色度测量。

## 简短复核步骤

1. 打开最终应用包，选取自己的线性 TIFF 或胶卷文件夹。
2. 框选片基，调好一张照片后复制参数。
3. ⌘点击/Shift 点击选择多张，点击“应用到 N 张”；检查 ⌘Z/⇧⌘Z。
4. 重开胶卷确认设置恢复，再导出当前照片，检查完整尺寸、16-bit 和 P3 D65 Gamma 2.6 ICC。

## 保留边界

- 本轮不含批量导出、多输出 profile 或最终性能优化。
- 输出为无压缩 classic TIFF。BigTIFF、tile、多页、其他通道/位深与压缩输出尚不支持，输入会明确拒绝。
- 未注入真正的磁盘耗尽、系统断电或 GPU 硬件故障。已测试取消、权限错误、损坏文件和目标文件竞争，但不把这些等同于所有失败场景。
- 预览长边 1600，尚无全分辨率 1:1 细节检查。没有旧版 macOS 实机、Intel、多显示器切换或独立色度仪测量结果。
- 文件按原名重现可恢复参数；改名后的手动重新定位 UI、缓存清理、完整域外计数 UI 尚未提供。
- Cineon 1024 归一化、输入指定策略与 LUT Gamma 语义按已版本化契约实现；没有第三方参考，因此不声称匹配某个未提供的 Photoshop/Resolve 工程。

## 2026-09-07 · SDR 预览修正（build 2）

用户报告白框接近 1 的内部数值在屏幕上低于 200。隔离诊断确认原 Float32 大图窗口呈现异常；仅将显示副本改为 UInt16、保留原始 ICC 后，同一白框与同值参考块一致。实际截图对照及结论边界见 [pipeline.md §9](pipeline.md#9-预览导出与中间阶段诊断)。正式工程采用该展示方案，独立缓存标识为 `sdr-uint16-v1`；算法和项目 schema 不变。

本次基于 `d744f60` 的本地修正工作区执行以下命令，输出仍为 `output/Printroom-0.1.0.app`，版本 0.1.0、构建号 2：

```sh
scripts/test.sh -c release
scripts/build-app.sh Printroom-0.1.0
codesign --verify --strict --verbose=2 output/Printroom-0.1.0.app
output/Printroom-0.1.0.app/Contents/MacOS/Printroom --verify-resources
```

| 验证 | 本次实际结果 |
| --- | --- |
| 常规回归 | 73 项中 70 项通过、3 项完整资产测试按条件跳过、0 失败：XCTest 64 项含 2 项跳过；Swift Testing 9 项含 1 项跳过 |
| 显示格式与数值 | 16-bit/component、64-bit/pixel、小端整数 RGBA、原始 ICC 字节一致；无额外 Gamma，显示量化误差满足管线契约；输入 Float32 buffer 不变 |
| 诊断与非法输入 | 显示副本裁切、原始超界读数保留；非有限 RGB 与尺寸不匹配返回错误，不触发整数转换崩溃 |
| 大图离屏绘制 | 1600×1066 色块缩小至 696×464，经实际 NSImage 绘制到 sRGB；LUT 白端、纯白、灰阶和黑端与预期相差不超过 1 个 8-bit 级别 |
| CPU/Metal | Apple M4，4099 样本 × 2 矩阵 × 3 组调色 × 7 阶段；最大绝对误差仍为 3.8146973e-6 |
| 单张文件回归 | 常规小图完整管线导出及 ICC 回读通过；全分辨率和十张原图独立解码本次未重复执行，保留上文历史证据 |
| 应用包 | release 构建、ad-hoc 签名验证通过；包内 ICC/LUT SHA-256 与原资产一致；从 `/private/tmp` 执行包内命令行自检，输出 `sdr-uint16-v1 preview verified` |

日志：`scratch/preview-sdr-tests.log`、`scratch/preview-sdr-build.log`。此次新增的离屏绘制测试不替代真实窗口验证：真实窗口证据来自修复前已完成的隔离对照。用户随后明确禁止继续使用 Computer Use，因此正式打包后仅执行自动化和命令行验证，未重新进行桌面操作或硬件色度测量。

## 2026-09-07 预览视口越界修复验收

本次工作区承接此前未提交的 SDR 显示修正，未覆盖这些修改。修复只涉及预览视口的布局、绘制裁切、鼠标边界与统一复位；算法、项目 schema、展示 ICC 和导出格式不变。

- SwiftUI 使用 GeometryReader 分配固定视口尺寸并裁切；Canvas 无图像固有尺寸，NSView `clipsToBounds`、layer `masksToBounds` 与 CGContext `clip(bounds)` 同时约束图像及选区。
- 窗外按下/缩放/滚动不改变图像；拖出暂停，重入不累计窗外平移量，窗外松开不提交像素或片基取样。resize/fit/双击清除临时手势，取样仍逆映射完整 imageRect 到原始尺寸。
- 常规 `scripts/test.sh`：XCTest 64 项、2 项完整资产测试按开关跳过、0 失败；Swift Testing 15 项通过（含 6 个预览测试），另一个全尺寸管线测试按开关禁用。本次未重复 `--full` 全尺寸导出验收。
- 预览测试逐像素检查 30 种横/纵图像、0.25/1/16×、四向 pan 与超大 overlay 组合，窗外污染像素为 0；测试 NSHostingView 中三个窗口尺寸的固定面板空间、窗外事件和缩略预览到原分辨率坐标。TIFF 测试还精确覆盖 8 种 orientation 的 96 个解码组合。随后扩展并重跑预览套件 6/6 通过：4× 缩放/pan 后实际提交 `PixelRect(50,35,16,11)`，原图 120×80、采样 176 像素和来源帧记录正确；窗外释放不改变校准。
- `scripts/build-app.sh Printroom-0.1.0` 成功；`codesign --verify --deep --strict` 成功；应用 `--verify-resources` 通过 Apple M4 Metal、原始 ICC/LUT 身份和 UInt16 预览格式检查。`shasum -a 256 -c assets/SHA256SUMS` 12/12 通过。

### 真实窗口截图

验收 harness 使用正式 `EditorView`、`CanvasView` 和 `EditorModel` 源码，创建实际可见 NSWindow，通过 `/usr/sbin/screencapture -l` 读取 WindowServer 窗口截图；不是离屏渲染或示意图。源照片为 `DSC07079.tiff` 的 scratch 副本，仅在副本追加 orientation IFD，图像条带样本保持原字节。运行入口为 `scripts/viewport-window-qa.sh`；本次按其中的同一准备、编译与运行命令执行。未使用 Computer Use。

本地证据在 `scratch/viewport-qa/`（不提交参考照片或截图）：

| 截图 | 实际操作及观察 |
| --- | --- |
| `01-fit`、`02-small`、`03-zoom16` | 居中 fit、0.25×、16×；视口始终 893×496 pt，图像未覆盖工具栏/读数/面板/Filmstrip |
| `04-left` 至 `07-bottom` | 16× 下连续四次分别向四边拖动；同尺寸截图的工具栏、读数和调色面板区域与 `03` 逐像素相同 |
| `08-selection-outside-drag`、`09-overlay-clip-stress` | 贴边选区后拖到窗格外；另直接注入超出视口 500 pt 的 overlay 验证绘图裁切，均未越界 |
| `10-doubleclick-fit`、`11-resize-small-fit`、`12-resize-large-zoom` | 双击复位、1060×720 内容尺寸、扩大窗口后再次 16×；图像居中复位，面板空间保持，窗口实际可用尺寸受屏幕限制 |
| `13-rotate90` / `-fit`、`14-mirror` / `-fit` | 90° 旋转、水平镜像 TIFF 输入分别组合 16×、平移、贴边选区与 fit；图像及选区均受相同视口约束 |
| `15-controls-at-zoom`、`16-filmstrip-and-fit` | 鼠标事件经 NSApplication/NSWindow 实际命中“适应窗口”、片基开/关按钮及 Filmstrip；放大后按钮可响应，fit/切帧恢复 zoom=1、pan=0 |

共 18 张窗口截图，已逐组视觉检查；完整几何记录与通过断言见 `scratch/viewport-qa/window-qa.log`。旋转/翻转覆盖当前已支持的 TIFF 方向输入；应用仍无独立手动旋转/翻转命令。不同 macOS/显示设备及真实触控板硬件手势未在本轮扩展验收，捏合事件路径由自动测试覆盖。
