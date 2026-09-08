# Printroom 0.3.3 验收记录

日期：2026-09-08。本机 Apple M4、macOS 26.6.2（25G83）、Swift 6.3.3、arm64。独立 `output/Printroom-0.3.3.app`，构建号 1，bundle ID `studio.printroom.local.v3.3`。本轮基于 `e5ce052`，包含已提交的快捷键与直方图更新；本轮提交可通过 `git log --oneline` 查阅。

## 交付

吸管以实际 2383 LUT 后 Final 为目标，后台反求现有整数 RGB Timing，尽量保持最终亮度。数值定义、容差、求解上限与无解行为的唯一来源见 [pipeline.md §15](pipeline.md#15-033-final-中性点吸管)。保留 I/Esc、工具指针、原片邻域、裁剪/方向坐标及一次撤销；过期、取消和失败不写入参数。

`printroom-density-v2`、schema 3、几何版本 2、显示格式、原始 LUT/ICC 均保持；旧项目不自动重算。新包包含 ⌘C/⌘V 参数复制应用和整图均匀取样直方图随画面同步发布。原有旧版应用继续保留，无远端、推送或发布。

## 已执行

| 命令与日志 | 结果 |
| --- | --- |
| `scripts/test.sh -c release`；`scratch/final-neutral-release-tests-final.log` | 核心发现 137 项，134 项通过、3 项完整资产/全尺寸验证跳过；应用发现 79 项，75 项通过、4 项完整导出/性能量测跳过。共 209 项实际执行测试通过，零失败 |
| 同一回归中的 15 项 `NeutralTimingTests` | 实际 LUT、独立解析合成逆解、ICC/Lab、整数邻域、LED/校准/反差、颗粒/偶数中位数、剪切、不可达/精度失败、非法输入和取消通过 |
| 实际 `TEST/DSC07079.tiff` ROI | 原片 x=3500、y=2300、11×11，默认校准与调色；只读，不写旁存项目。结果和计时见下文 |
| 新参数 CPU/Metal 与四输出 | 同一 11 像素样本 CPU/Metal 通道误差满足原容差；四个输出 ICC × 无压缩/Deflate TIFF 共八种结果写入临时目录，UInt16 回读及原始 ICC 字节存在检查通过。固定 ICC 解析和 TIFF 结构的独立既有测试同时通过 |
| `scripts/build-app.sh`；`scratch/final-neutral-build.log` | release 编译、资源打包、ad-hoc 签名及应用实际运行 `--verify-resources` 全部通过，验证原始 ICC/LUT、四输出 profile、Apple M4 Metal 与 UInt16 展示 |
| `codesign --verify --deep --strict --verbose=2 output/Printroom-0.3.3.app`；`scratch/final-neutral-signature.log`；`plutil -lint` | 签名、plist 通过，独立 bundle ID 和构建号已核对 |
| `shasum -a 256 -c assets/SHA256SUMS`；`scratch/final-neutral-assets.log` | 原始 TIFF/ICC/LUT 共 12/12 通过 |
| 构建脚本旧版保护、shell 语法与 `git diff --check` | 通过；旧版本及其试用包名称在构建前拒绝覆盖 |

数值/图像及应用测试在可访问 Metal、系统文件协调服务的本机权限下运行。没有上传参考 TIFF。

## 数值证据

实际 LUT 的八个等值 D3 输入点 256、320、384、470、512、600、685、768 CV 均通过 Final 中性与亮度检查，重复标定保持相同参数。例如：

| 原 D3 | 新 RGB Timing（CV） | Final 编码 RGB | Final C*ab |
| --- | --- | --- | --- |
| 470 / 470 / 470 | −7 / +10 / −33 | 0.463279 / 0.462667 / 0.462787 | 约 0.092 |
| 685 / 685 / 685 | −33 / +31 / −34 | 0.842580 / 0.842856 / 0.843130 | 约 0.060 |

实际 TIFF ROI：Timing 由 0/0/0 变为 −294/+289/−199，Master 保持 0；代表色 Lab 从 `(91.435759, 13.994730, −9.213763)` 变为 `(90.947935, 0.191758, −0.058588)`。已加载 LUT/ICC 后，仅求解约 **2.515 ms**；不含磁盘读取、预览重绘或 UI 完整响应，不宣称通用性能上限。

独立合成测试用有通道耦合的线性 3D LUT，直接解析矩阵逆及所需 Timing，并枚举整数邻域比较误差。ICC 测试参考使用独立 Python 解码提取的固定 colorants/TRC 与 Double CIE 公式，不调用生产测量辅助类。实际 LUT 的中性判断、线性亮度和 CPU/Metal 检查均为数值证据，不代表硬件色度或审美验收。

## 边界与首次回归发现

实际 LUT 所有格点的绿色最大值为 0.932183；三线性输出不能超过格点全局最大值。等值 896 CV 对应同亮度中性编码约 0.939155，因此该高光目标不可能严格达到。首次测试把该点和偏高曝光的真实 ROI 当作必然可解，已根据数值证据拆为明确的高光失败测试，实际 ROI 使用默认参数验证。没有改变 LUT 或放宽成功容差。

首轮完整应用回归发现旧画布测试的浅色原始样本经 LUT 后接近黑色，已处于 Final 中性容差内；旧测试仍要求参数一定改变。将测试样本改为 Final 有明显色偏的中间调后，真实画布点击、缩放坐标、窗外释放及后续片基框选均通过。对已在容差内的样本仍保持幂等、不制造无意义撤销。

## 实际窗口与未执行项目

`bash scripts/editor-window-qa.sh --release --skip-build --keyboard` 已从本轮源码编译测试程序；日志 `scratch/final-neutral-window-qa.log` 检测到 `frontmost=loginwindow locked=true`，因此 **未激活窗口、未发送真实键鼠事件，窗口键鼠复验未通过执行阶段**。解锁后可按同一命令复跑。原有窗口 QA 目录已备份到 `scratch/editor-ui-qa-0.3.2-preserved`；本轮不把旧截图当作新证据。

实际点击/视觉效果与用户试用仍待验。自动化已覆盖真实 NSWindow/Canvas 事件路由、Final 取样结果、后台隔离与取消、等待切帧/调参、求解期间源修改、失败不增加撤销、原片裁剪方向映射、一次 Undo/Redo 和保存重开。

本轮未运行十张 TIFF 的完整独立解码、三项全尺寸导出（核心两项、应用一项）和三项既有性能量测；上述七项明确跳过。更多 macOS、Intel 和显示设备未实机验收。未使用 Photoshop。
