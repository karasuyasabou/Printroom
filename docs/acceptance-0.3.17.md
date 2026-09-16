# 0.3.17 移除独立 CMOS 导出（2026-09-11）

用户要求不再提供“导出 CMOS 矫正 TIFF”。移除导出子菜单、目录面板与 ExportMode/L1 输出分支；正常 Final 导出继续使用矩阵、片基、调色、裁剪/方向及 ICC。原始资产、项目格式和算法版本保持。

原独立 L1 导出回读测试随功能移除；RAW 请求快照测试改为验证正常导出，保留源保护与 CMOS 快照断言，真实 RAW 标定测试保留代理取样部分。历史验收文件保留原记录。

验证：

- `scripts/test.sh -c release --filter 'ExportColorTests|MatrixTests|MatrixEditingTests|CropTests|OrientationHistogramTests|EditingV2Tests.exportWhileEditing'`：50 项 XCTest 中 49 项通过、1 项真实 RAW 标定按环境开关跳过；10 项 Swift Testing 全部通过。覆盖四 ICC/两压缩回读、单张/批量快照、裁剪/方向、取消、重名竞争与源保护，以及矩阵/片基和编辑中导出。
- 首次沙箱执行无法创建 Metal 上下文，相关界面测试失败；允许访问本机 Metal 后按上述命令重跑通过。日志 `scratch/cmos-removal-tests.log` 为通过的重跑结果。
- `git diff --check` 通过；Sources/Tests 中不存在 `ExportMode`、`cmosLinear` 或 `exportCMOS` 引用。
- `scripts/build-app.sh` 成功：包内 ICC/LUT、四输出 profile、Apple M4 Metal 和 SDR 预览冒烟通过，严格签名验证通过；已覆盖 `output/Printroom.app`，版本 0.3.17 / 构建 1，固定标识保持。日志 `scratch/cmos-removal-build.log`。

边界：本轮不重跑真实 RAW 全尺寸转换和全套原始 TIFF；未进行真实菜单点击或窗口视觉验收。


## 构建 2：缩放按钮统一为 100%（2026-09-11）

TIFF 和 RAW 的预览缩放按钮均固定显示“100%”；仅替换标签，保留原有点击动作、选中状态与悬停说明。

- `scripts/build-app.sh` 通过 release 构建、ICC/LUT/四输出 profile、Apple M4 Metal、SDR 预览及严格签名验证，覆盖 `output/Printroom.app`，版本 0.3.17 / 构建 2。日志 `scratch/zoom-label-build.log`。首次沙箱运行因 Metal 上下文不可用停止，旧应用保留；授权使用本机 Metal 后重跑成功。
- `git diff --check` 通过；源码确认标签为不含条件分支的 `Text("100%")`。
- 纯文案调整，未新增或重跑图像算法测试，未进行真实窗口视觉验收。
