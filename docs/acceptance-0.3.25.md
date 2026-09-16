# 0.3.25 直方图自动纵轴

日期：2026-09-12。固定交付 output/Printroom.app，版本 0.3.25 / 1。算法 v4、schema 6、几何版本 2 保持。保留此前工作区修改，未提交 Git。

- 自动纵轴允许异常高峰截顶，未截顶部分保持线性比例；RGB共用尺度，无新增切换按钮。显示公式以pipeline.md §12为准，交互见interaction.md。
- `scripts/test.sh --filter 'HistogramDisplayScaleTests|OrientationHistogramTests'`：11项既有统计/方向测试与4项新显示测试全部通过。覆盖90%黑色背景、跨16个bin的大峰、样本倍增、横轴反转、RGB比例、空/纯色/稀少样本下限，以及原端点/域外/非有限值统计。
- 合成90,000黑色样本和100个各100样本的中间调bin：上限125，主体高度80%，原最大值缩放仅约0.11%；黑峰截顶，真实计数保持。
- `scripts/build-app.sh`：首次沙盒运行无法创建Metal上下文，旧包保留；本机重跑通过release、ICC/LUT、四输出profile、Metal Apple M4、UInt16预览和签名验证，成功替换固定包。
- `bash scripts/editor-window-qa.sh --release --skip-build --histogram`：1060×720真实测试窗口截图成功，已目视检查RGB叠加、密度单通道、主体高度、左端高峰与CV刻度。使用内存合成统计，背景沿用布局夹具，不作为真实照片/直方图配对验收。
- 日志：scratch/histogram-scale/tests.log、build.log、build-native.log、window.log。截图：scratch/editor-ui-qa/23-histogram-night-rgb.png、24-histogram-night-density-red.png。
- `git diff --check`通过。本轮只修改直方图展示和相关文档/验证入口，原始TIFF、ICC、LUT未修改。
- 未执行真实夜景照片观感验收、全套图像与导出回归；不宣称复刻LR内部算法。阈值为工程默认，实际夜景效果待用户试用。

## 构建2：提高上限（2026-09-12）

用户反馈截顶过多，按要求把候选纵轴上限与样本比例下限提高为首版两倍；保留实际最高峰上界。公式见pipeline.md。合成夜景主体高度由80%变为40%，200计数的峰由截顶变为80%高度；极高暗峰仍可截顶。

- `scripts/test.sh --filter HistogramDisplayScaleTests`：4项通过，包含新的主体高度、200计数峰完整显示、样本倍增、RGB共用尺度及空/纯色边界。
- `scripts/build-app.sh`：release、ICC/LUT、四输出profile、Metal Apple M4、UInt16预览与签名验证通过；固定应用包已替换为0.3.25 / 2。
- 日志：scratch/histogram-scale/tests-build2.log、build2.log。`git diff --check`通过。
- 本次仅调整显示阈值，未重跑窗口截图及图像导出测试；真实照片效果待用户试用。

## 构建3：P90 × 4（2026-09-12）

按用户要求将P90系数从2.5改为4，样本比例下限保持0.2%，实际最高峰上界保持。合成夜景的100计数主体高度为25%，200计数峰高度为50%。

- `scripts/test.sh --filter HistogramDisplayScaleTests`：4项通过，日志scratch/histogram-scale/tests-build3.log。
- `scripts/build-app.sh`：release、资源、Metal Apple M4、UInt16预览与签名验证通过，已替换固定output/Printroom.app，版本0.3.25 / 3；日志scratch/histogram-scale/build3.log。
- `git diff --check`通过。仅调整显示系数，未重跑窗口截图和图像导出回归；真实照片观感待用户试用。
