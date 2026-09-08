# Printroom 0.2.0 验收记录

## 界面精简补记（2026-09-07，build 2）

**交付状态：用户人工验收通过，本轮 UI 修改已完成。** 2026-09-07 用户明确反馈“验收我人工验收了，已通过”。不再追加验收；以下自动检查的执行记录保留原状。

本次按用户截图精简调色面板，统一 Color Timing / Contrast 四色滑杆及右侧数值，将直方图移至预览右上角半透明浮层，输出 ICC/压缩移至系统导出对话框。交互以 interaction.md 为准；算法与 schema 不变。

已完成 release 应用包、资源冒烟与签名校验；12 项原始资产哈希一致。宿主常规回归为 93 个 XCTest（2 项按需跳过）及 33 个 Swift Testing（3 项按需跳过），无失败；受限沙盒首次因 Metal 不可用而失败，没有记作通过。原有真实窗口视口回归通过；追加检查通过八个原生滑杆轨道点击、单次撤销、方向键步长、滑杆焦点下 Q 快捷键及浮层 RGB/R 点击不误触取样。合成拖动事件未能稳定驱动原生滑块，因此追加窗口检查只记轨道点击，不记真实连续拖动通过。

单张/所选/整卷三种真实导出对话框均已验证选项默认显示、四 ICC 与两压缩选择、取消保留项目字节且不产生导出；截图已查看。用户随后要求停止验收，本轮新增的确认导出及回读验收未完成，不作通过声明。此前版本的导出数值证据仍见下文。没有继续追加测试。

本次日志：scratch/test-ui-refresh-host.log、scratch/window-ui-refresh.log、scratch/window-ui-refresh-controls-passed.log、scratch/build-ui-refresh-final.log、scratch/assets-ui-refresh.log；导出对话框记录在 scratch/export-panel-qa/。窗口样片使用 scratch 副本，新增导出面板使用合成 TIFF。

日期：2026-09-07。本记录与交付源码一起保存在本地提交（`git log -1 --oneline`）；起始提交 `d744f60`，保留了任务开始时尚未提交的 0.1.0 显示与视口修正。无远端、无推送、无发布。

交付：`output/Printroom-0.2.0.app`，约 3.3 MiB，arm64，版本 0.2.0 / build 1，独立 identifier `studio.printroom.local.v2`。旧 `Printroom-0.1.0.app` 未被替换，旧偏好未修改。开始时未发现运行中的 Printroom 进程。schema 2，算法仍为 `printroom-density-v1`。

## 环境与可执行命令

Apple M4、macOS 26.6.2 (25G83)、Xcode 26.6、Swift 6.3.3；部署目标 macOS 14。GPU 与 NSFileCoordinator 测试使用宿主权限；最初受限沙盒的 Metal/文件协调失败没有记作通过。窗口验收在本机图形会话执行，无 Photoshop。

```sh
scripts/test.sh --full
scripts/test.sh --filter 'MetalTests|ExportColorTests|TIFFCodecTests'
scripts/measure-performance.sh
scripts/measure-performance.sh --export
scripts/viewport-window-qa.sh --release
scripts/build-app.sh
codesign --verify --deep --strict --verbose=2 output/Printroom-0.2.0.app
shasum -a 256 -c assets/SHA256SUMS
```

实际日志均在被忽略的 `scratch/`：`test-v2-full.log`、`test-v2-final-edges.log`、`performance/*.log`、`window-v2-release-final.log`、`build-v2.log`、`runtime-v2-isolated.log`、`assets-v2.log`。窗口 PNG 位于 `scratch/viewport-qa/`。测试来源均为只读参考或临时副本，原始 `TEST/ICC/LUT` 不写入项目或测试产物。

## 实际结果

| 验收项 | 执行结果 |
| --- | --- |
| 完整自动验收 | 93 个 XCTest + 31 个应用测试通过，0 失败。另两个按需性能入口在普通 full 中按开关跳过，随后单独实际执行通过 |
| 最后导出边界修正回归 | Metal、11 个输出测试、9 个基础 TIFF 测试通过；此次未开 full 的两个 TIFF 大文件测试已在前述 full 中通过 |
| schema 1→2 | 读取时不写盘；ID、校准、Timing/Contrast不变，默认 identity/P3/无压缩；保存/重开恢复；损坏/未来字段拒绝 |
| 用户方向 | 八状态全组合、整像素及半开ROI逆映射；Undo/Redo/重开；复制只含Timing/Contrast；原TIFF方向与用户方向分别验证 |
| 直方图 | 合成 bins、0/1端点、域外、NaN/Inf、单位与取消；快速切帧/阶段/调参只发布最新结果；1:1局部不替换整图统计 |
| ICC与编码 | 四profile × 两压缩，3×16-bit、orientation=1；TIFFCodec与独立ImageIO回读样本一致、ICC字节一致 |
| 批量与单张 | 八方向的单张/批量输出字节一致；任务开始后改目标/参数/方向/profile不改变已固定任务；取消、缺失失败继续、重名、源保护、目标竞争重试通过 |
| 重新定位 | 实际TIFF预校验；稳定ID、调色和方向保留；默认占位帧合并、已有编辑冲突拒绝、片基来源复核；Undo/Redo后的实际选择与重开一致 |
| 缓存与取消 | 6项服务测试通过：条带ROI、TIFF八方向、原文件替换、LRU限额、取消、16-bit PNG/ICC、磁盘TTL/限额/陌生文件及symlink保护 |
| 真实参考 | 十张7008×4672 TIFF完整样本与独立Python/zlib解码一致；完整尺寸P3管线导出回读通过 |
| 原始资产 | 12/12 SHA-256一致 |
| 打包 | release构建、ad-hoc签名、deep/strict签名校验、Metal/四输出profile/展示格式冒烟通过 |
| 独立运行资源 | 将.app复制到系统临时目录，禁止读取工作区 `.build`、原始 `ICC/` 和 `LUT/`，从卷外运行 `--verify-resources` 成功；未依赖源码树资源 |

异步审查实际发现并修复了：同卷重新载入后的过期采样写回、旧帧读数错误弹到新帧、加载失败后spinner不结束、方向改变时旧图使用新几何、重连撤销后的lastActive不一致。均有回归测试。

## 数值证据

CPU/Metal：4099像素（固定种子及边界）×2矩阵×3调色配置×7阶段。最大绝对误差 `3.8146973e-6`；各阶段最差运行 RMS 如下，全部在规范预算内。

| 阶段 | 最大绝对误差 | 最差运行 RMS |
| --- | ---: | ---: |
| L0 / L1 | 0 | 0 |
| D0 | 1.1920929e-7 | 1.1294116e-8 |
| D1 | 2.3841858e-7 | 1.3525171e-8 |
| D2 | 2.3841858e-7 | 1.5455389e-8 |
| D3 | 3.8146973e-6 | 2.4693898e-7 |
| Final | 1.3709068e-6 | 3.3107147e-8 |

实际 `DSC07079.tiff`：片基ROI `(359,604,79,494)`，LED矩阵，Timing `(30,5,-3,7)`，Contrast `(1.05,.95,1.02,1.1)`；全尺寸导出与CPU抽样最大差 `7.748604e-6`（包含16-bit量化），原P3 ICC精确一致。debug全管线导出24.81秒，仅作为正确性执行记录；release性能另列。

ICC真实转换按固定profile的matrix/TRC、D50 PCS计算；源/目标曲线取自ICC，未对Final重复Gamma编码。公开原色+独立Bradford/transfer参考最大误差：sRGB `2.01957e-4`、Adobe RGB `9.84460e-5`、ProPhoto `7.09138e-5`，包含ICC定点精度和标准白点差异。正常域与CoreGraphics参考最大差分别 `1.19925e-4`、`1.33663e-4`、`5.96046e-8`；P3直接输出差0。

暗部解析检查实际发现系统CMM的附加线性段：P3中性 `.02` → ProPhoto，标准ICC结果 `.00061205094`，系统Float32路径约 `.01999999955`。因此生产输出使用固定ICC的matrix/TRC求值，Double计算后统一量化。另为ProPhoto使用正确D50和编码域`1/32`断点的新profile；系统ROMM的断点不采用。原始ICC、LUT和密度算法均未修改，详细契约见 pipeline §11 和资源PROVENANCE。

## 窗口与性能

实际 EditorView 窗口验证了0.25–16倍缩放、四向拖动、视口外选区、大小窗口、原TIFF旋转/镜像、用户追加方向、1:1、RGB与密度直方图及已校准真实参考图。鼠标事件经NSApplication/NSWindow派发到真实Fit、框选、Filmstrip、1:1控件。发现附加空contextMenu使Filmstrip点击不可靠，改为可用帧原生Button、缺失帧单独contextMenu后回归通过。

最终截图 `21-v2-calibrated-reference.png` 已人工查看：主预览、方向和缩略图符合当前模型，白边、皮肤及衣物可辨，画面和选区无越界，直方图单位可读。该观察不替代用户调色审美或硬件色度验收。

下表为release、独立进程、温热文件系统缓存的本机测量；没有强制清空系统缓存。对照“完整解码策略”也使用修复后的底层读取，不能当作0.1.0二进制的完整性能对比。

| 场景 | 条带/按需策略 | 完整解码策略 |
| --- | ---: | ---: |
| 首次1600预览解码 | 0.394秒 | 0.404秒 |
| 首次解码阶段峰值RSS | 77.81MiB | 255.50MiB |
| 十张240缩略图 | 0.813秒 | 4.042秒 |
| 十张连续切图解码 | 3.687秒 | 4.067秒 |
| 最近帧缓存命中 | 0.095毫秒 | 388.6毫秒 |
| 整个测量流程峰值RSS | 403.28MiB | 529.17MiB |

20次串行调参GPU+UInt16显示准备：平均12.71毫秒、最大16.07毫秒；不是滑杆端到端延迟或FPS。2048×1536原始区域读取0.171秒；当前参考条带布局的中途解码取消约0.483毫秒。源LRU为54,579,200bytes/2项，低于64MiB预算。

实际release窗口连续30次调参：20毫秒计时请求，实到中位27.81毫秒、P95 29.55毫秒、最大32.72毫秒；包含事件循环、SwiftUI和绘制竞争。debug对应约200毫秒，交付使用release。

两张实际全尺寸照片，第二张顺时针90°；LED及调色参数同上：

| 输出 | 两张耗时 | 峰值RSS | 文件大小（字节） |
| --- | ---: | ---: | --- |
| P3 / 无压缩 | 1.720695秒 | 252.78MiB | 196450226 / 196450810 |
| ProPhoto / Deflate | 11.496380秒 | 257.86MiB | 171394236 / 168656587 |

回读尺寸分别7008×4672、4672×7008，正确profile及原生8×8区域解码通过。第二帧峰值未累加完整原图；总体低于初始RSS+单张UInt16原图+128MiB工作空间预算。初次性能测试错误要求malloc立即将释放页归还OS，断言失败；随后改用跨帧峰值增长和总预算检查，原失败日志保留 `export-p3-rss-assumption.log`，没有把RSS常驻直接等同于Swift对象泄漏。

本机后续回归目标（工程默认，非跨设备承诺）：预览解码≤0.75秒、10缩略图≤1.5秒、20次串行GPU/显示平均≤25毫秒、窗口20毫秒计时P95≤50毫秒、上述预览测量流程峰值≤512MiB；两帧P3≤3秒、ProPhoto Deflate≤20秒、导出峰值≤初始RSS+单图+128MiB。均由以上实测制定，不以降低数值精度实现。

## 简短操作与剩余限制

打开新版 → 打开胶卷副本 → 框选片基 → 调Timing/Contrast → 方向菜单旋转/翻转及撤销 → 点1:1和平移 → 看RGB/单通道及阶段直方图 → 选择输出ICC/压缩 → 导出当前/所选/整卷 → 导出中继续编辑或取消 → 查看逐张结果 → 重开确认恢复。缺失帧右键重新定位；输出面板可清理缓存。

- schema2被新版保存后，0.1.0会明确拒绝新结构；算法和默认画面保持不变，避免两个版本同时编辑同一卷。
- 当前只支持classic RGB UInt16条带TIFF，不支持BigTIFF、tile、多页、alpha等扩展；导出只提供四个已验证的固定ICC。
- 1:1单区域最多8,388,608像素；超大窗口超限会报错，不降精度。巨大压缩条带仍需整条解压，内存/取消延迟可能高于当前参考文件。
- 手动重连限定卷内直接子文件；内存中保留全卷缩略图展示副本，但不会常驻整卷全尺寸原图。本次10张卷之外的超大卷可用性未实测。
- 未执行真实磁盘写满、进程强杀时文件系统耐久性、旧macOS/Intel/更多显示设备或硬件色度仪验收。写入失败/竞争/取消的可控注入已验证，未将其等同于上述全部场景。
- LUT的精确扫描标定、Cineon物理衔接及用户最终色彩外观验收继续保留边界；不宣称与未提供的第三方软件逐像素相同。

## 2026-09-07 快捷键修正验证

在本机Apple M4的当前工作区执行（包含尚未提交的界面精简改动）：

- `scripts/test.sh --filter EditorIntegrationTests`：10项通过，全尺寸参考导出1项按条件跳过。新增/更新验证W +1、S −1、撤销、上下限、左右切图跳过缺失帧、首尾不循环及单选。
- `scripts/viewport-window-qa.sh --release --controls-only`：真实EditorView窗口事件通过；8个滑杆点击/撤销、获得焦点后的左右切图及上下键不改参数、W/S、英文和中文方括号旋转、⌘F水平翻转/撤销、文本输入时不旋转/翻转/切图。截图位于`scratch/viewport-qa/21-*.png`至`23-*.png`。未重新执行完整视口流程。
- `scripts/build-app.sh`：release构建、ad-hoc签名、四输出profile及Metal资源冒烟检查通过，更新`output/Printroom-0.2.0.app`。

首次沙盒内集成测试受Metal不可用影响，窗口测试受图形会话访问限制超时；随后在本机权限环境重跑上述检查并通过。原始TIFF/ICC/LUT未写入，本次不改算法和项目schema。弹窗排除由窗口/模态状态守卫实现，本轮未注入弹窗按键自动验证。

## Timing 长按与范围更新（2026-09-07，构建号 3）

按用户确认：单击 1 CV、Shift 单击 10 CV，按住 0.4 秒后固定 120 CV/秒；规则见 interaction.md。应用按单调时钟累计 CV，以约 20 Hz 提交参数；系统重复事件不再额外累加。松手、换键、切帧、失焦、弹窗终止或重新开始对应手势，一次长按合并为一次撤销。四控件扩展至 ±512，公式和算法/schema 版本不变；超出旧范围的项目会被旧版拒绝。

验证：`scripts/test.sh` 在可访问 Metal 的环境通过，XCTest 93 项（2 项完整资产检查按默认模式跳过），Swift Testing 38 项通过。新增计时契约、系统重复抑制、Shift、松手停止、整次撤销/重做、换键/失焦/切帧测试；扩展 ±512 数值及 JSON 往返、±513 拒绝、合成偏移不二次裁切和 Metal 极值测试。初次沙盒执行无法创建 Metal 上下文，已在非沙盒环境重跑通过。异步速率测试不假设任务在指定 sleep 时间精确唤醒，固定速率由独立时间点断言验证。

用户实际长按手感及旧系统/其它键盘输入法仍待人工体验；本次未重跑十张 TIFF 全尺寸输出与原始资产完整哈希。

交付：`scripts/build-app.sh` 完成 release 编译和 ad-hoc 签名；其沙盒内资源校验因 Metal 不可用退出后，单独在非沙盒运行 `output/Printroom-0.2.0.app/Contents/MacOS/Printroom --verify-resources` 通过（Apple M4、ICC/LUT、四输出 profile、UInt16 预览）。`codesign --verify --deep --strict output/Printroom-0.2.0.app` 通过。

### 构建号 4：长按降至 50 CV/秒

用户试用后要求降低速度；现固定 50 CV/秒，其余交互不变。`scripts/test.sh --filter TimingKeyboardTests` 4 项通过，覆盖速率时间点、停止、Shift、系统重复、撤销及切帧。release 构建完成；沙盒资源检查因 Metal 不可用退出，非沙盒单独 `--verify-resources` 通过，签名严格校验通过。新版位于 `output/Printroom-0.2.0.app`；50 CV/秒手感待用户试用。

### 反差控件上限 2（2026-09-07）

按用户要求，Master/R/G/B 反差滑杆及数值输入范围改为 0.25–2，步长保持 0.01。旧项目参数仍按原数值读取和计算，不自动裁切；兼容范围见 pipeline.md。检查共享 AdjustmentRow 的滑杆和数值输入均使用同一范围限制。release 构建、严格签名校验、非沙盒 Metal/资源校验通过；沙盒内资源检查因 Metal 不可用退出后已单独重跑。此次简单控件范围调整未新增测试或重跑完整算法测试。独立试用包：`output/Printroom-0.2.0-Contrast2.app`。


## 调参性能优化（2026-09-07，构建号 5 隔离验证；构建号 6 集成）

用户确认实施连续预览调度、GPU 缓冲复用、D1 缓存、直方图及缩略图减少重复更新。行为与缓存失效以 architecture.md 为准；下方隔离对照保持 `printroom-density-v1`、schema 2、1600 预览、Float32 和 `sdr-uint16-v1`。此轮不缓存 1:1 原始区域。保留之前提交的 Timing 50 CV/秒规则。

本机 Apple M4 / macOS 26.6.2，release，固定 `DSC07079.tiff` 1600×1066 预览、片基 ROI `(359,604,79,494)`、LED。优化前使用实施前保存的源码快照，优化后使用构建号 5 源码；旧快照与当前版本的其他键盘设置差异不参与测量。两种路径使用相同测试入口、温热文件系统缓存、独立进程，未强制清系统缓存。原始日志位于 `scratch/adjustment-performance/before.log`、`after.log`。

| 首轮测量 | 优化前 | 优化后 |
| --- | ---: | ---: |
| 30 次 Timing 的 GPU＋显示准备平均 | 12.699 ms | 8.908 ms |
| 30 次 Contrast 的 GPU＋显示准备平均 | 12.648 ms | 12.089 ms |
| 120 次连续输入跨度 | 1398.859 ms | 1423.106 ms |
| 连续输入期间 / 总预览发布数 | 0 / 1 | 108 / 110 |
| 首次输入 → 首次预览发布 | 1459.450 ms | 17.917 ms |
| 最后输入 → 最终预览发布 | 60.590 ms | 17.134 ms |
| 最后输入 → 最终直方图就绪（含轮询） | 81.121 ms | 164.514 ms |
| renderer 进程峰值 RSS | 237.05 MiB | 184.56 MiB |
| editor 进程峰值 RSS | 258.62 MiB | 299.00 MiB |

预览发布是 Combine 观测到模型交付 CGImage，未测屏幕合成或物理显示时刻，不能当作屏幕 FPS。完整最终 UInt16 图像在计时结束后与不启用源/D1缓存的 Metal 完整路径逐字节比较，通过后才记录收敛。直方图延后是主动让出连续交互计算，停止后统计最终参数；editor 峰值增加约 40 MiB，是此次缓存与持续出图的实测代价，不能从单次 RSS 推断所有场景的内存变化。

首轮尾延迟存在波动，因此追加三组交错的优化前/后 renderer 测量，每组各 30 次 Timing 与 30 次 Contrast，不挑选最好的一次。原始日志 `renderer-{before,after}-repeat{1,2,3}.log`：

| 轮次 | 前 Timing / Contrast 平均 ms | 后 Timing / Contrast 平均 ms |
| --- | ---: | ---: |
| 1 | 32.350 / 20.350 | 9.619 / 9.906 |
| 2 | 14.956 / 14.374 | 10.696 / 9.109 |
| 3 | 14.880 / 14.284 | 9.874 / 10.540 |

新增 `scripts/measure-adjustments.sh` 可执行同一入口；`--legacy-renderer` 用于无 inputIdentity API 的旧源码。三轮优化后共 180 次热调参的平均准备时间约 9.96 ms。系统调度噪声可明显影响结果，不把这些本机数值推广为跨设备承诺。

已执行验证：

- `scripts/test.sh --full -c release`：99 项 XCTest、44 项应用 Swift Testing 通过，0 失败；3 个 opt-in 测量入口在 full 中跳过，新的调参测量另行执行通过。完整日志 `full-release.log`。
- 新增 6 项 Metal 复用测试和 5 项应用调度测试：真实 LUT、全阶段、两矩阵、参数极值、gain/matrix/source/尺寸/LUT 失效、nil 身份、并发 lane、超预算 buffer 释放、连续输入、切帧/阶段/方向、差量缩略图、批量/Undo/整卷失效及未完成待办保留。缓存与完整 Metal 数组完全相同；CPU 数值契约通过。
- 十张 TIFF 的完整原样本与独立 Python/zlib 解码一致。真实 7008×4672 管线导出回读最大抽样 CPU 差 `7.748604e-6`（含 UInt16 量化），ICC 字节一致；全尺寸 writer 全样本回读通过。四 ICC 转换与批量快照/取消/无覆盖回归通过。
- `shasum -a 256 -c assets/SHA256SUMS`：12/12 原始资产通过。`scripts/build-app.sh`：release 构建、ad-hoc 签名、四输出 ICC/LUT、Metal 和 UInt16 预览资源检查通过；严格签名验证通过。交付 `output/Printroom-0.2.0.app`，构建号 5，保留 0.1.0。

过程中一次并行测试文件写入使 Swift 编译中止、一次新增测试嵌套宏编译失败，均修正后完整重跑；测量脚本初次受 macOS Bash 空数组与 nounset 组合影响，改为非空参数数组后正式测量通过。旧基线初次校准引用了错误的临时 frameID，修正后正式对照通过。失败日志保留，没有把这些尝试算作通过。首次真实窗口完整流程已通过预览/视口/方向/1:1/直方图检查，但后续快捷键 QA 仅合成 keyDown 并等待 450ms，触发新 400ms 长按导致单击断言失败；QA 已修正为 keyDown+keyUp。集成重跑结果随后补充。

### Cineon 白点 pivot（2026-09-07）

用户指定 pivot 改为 685 CV，并选择旧项目也采用新白点且保留原设置备份。算法 v2，schema 2，完整规则见 pipeline.md §13。CPU/Metal 共享白点常量，快照身份与缓存算法标识同步更新。

` scripts/test.sh ` 非沙盒完整回归通过：XCTest 102 项（2 项完整资产测试按默认模式跳过），Swift Testing 44 项。解析测试证明 685 CV 在反差极值下不动、470 CV 按新 pivot 移动及合成反差不裁切；4099 像素×2 矩阵×3 组参数×7 阶段 CPU/Metal 比较，最大阶段误差 3.8146973e-6、Final 最大 1.3113022e-6、Final RMS 3.2846768e-8。迁移测试覆盖 schema 1/2、参数保留、首存原字节备份、重复保存不重复备份、时间/ID 冲突不覆盖、旧快照和未知算法拒绝。

` scripts/build-app.sh Printroom-0.2.0-WhitePoint `、包内资源/Metal 校验和严格签名验证通过。交付 `output/Printroom-0.2.0-WhitePoint.app`。未重跑十张参考 TIFF 全尺寸验收与完整资产哈希，实际白点反差外观待用户体验。


### 构建号 6：性能与白点 v2 集成

在白点任务提交 `1318dfe` 后复测，避免把原 v1 的隔离性能验证冒充最终算法的验收。`scripts/test.sh --full -c release` 再次通过：102 项 XCTest、44 项应用测试，0 失败；十张原始 TIFF 独立解码、7008×4672 全尺寸输出与白点迁移均执行，完整导出抽样 CPU 最大差 `7.748604e-6`，原 ICC 字节一致。日志 `scratch/adjustment-performance/integrated-full-release.log`。

集成版另跑 `scripts/measure-adjustments.sh`，日志 `integrated-performance.log`：Timing/Contrast 准备平均 8.748/9.962 ms；120 次输入跨度 1436.101 ms，期间 103 次预览发布、总 105 次。首输入→首发布 19.264 ms，末输入→最终发布 29.058 ms；最终直方图含轮询 177.532 ms。最终完整显示字节与 v2 完整 Metal 路径一致。editor 峰值 RSS 297.89 MiB。这些为另一轮系统调度下的集成复核，不把与 v1 数值外观的不同归因于性能优化，也不当作屏幕 FPS。


最终 `scripts/build-app.sh` 和 `scripts/build-app.sh Printroom-0.2.0-WhitePoint` 均成功；两个包的可执行文件逐字节相同，Info.plist 构建号均为 6，分别通过严格签名校验。日志 `integrated-build.log`。常规包与白点包现在均含性能优化和已确认的 685 CV 算法；0.1.0 包保持。

最终窗口验收边界：`integrated-window-qa.log` 在截图阶段被系统 `screencapture` 的 “could not create image from window” 中止；`--controls-only` 重跑同样无法截图。新增显式 `--no-screenshots` 可保留事件断言而不冒充视觉验收；此模式完整流程在首个排队控件断言中止。随后增加活动窗口前置检查，`--controls-only --no-screenshots` 明确记录 `active=false, key=false, visible=true`，无法可靠执行排队的控件事件（`integrated-controls-events.log`）。因此最终完整窗口截图/事件验收未通过，不把此前 v1 部分窗口通过或数值测试当作最终窗口通过。已查看本次前段成功的 `01-fit.png`，仅确认默认适应窗口布局和浮层边界；不作为最终调色外观验收。146 项最终自动测试覆盖的原生宿主视图、连续调度、全部阶段及图像字节一致性仍有效。


## 2026-09-08 双指平移方向修正（构建号 7）

修正主预览对水平、垂直滚动位移的额外反转，遵循系统自然滚动设置。更新既有事件方向断言；算法与项目结构不变。

`scripts/test.sh --filter PreviewCanvasTests` 在可访问 Metal 的环境中 6 项通过，覆盖平移方向、视口边界、缩放、复位和原始坐标取样。首次沙盒执行 5 项通过，取样测试因 Metal 资源初始化失败；非沙盒重跑全部通过。`scripts/build-app.sh` 完成 release 构建和签名，沙盒内资源校验因 Metal 不可用失败；随后应用 `--verify-resources` 非沙盒校验通过，`codesign --verify --deep --strict` 通过。应用位于 `output/Printroom-0.2.0.app`，实际双指手感待用户试用。
