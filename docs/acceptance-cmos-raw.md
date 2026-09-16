# Sony CMOS 与 RAW 标定验收（2026-09-09）

用户要求：将 calibration_matrix.npy 加为只读 Sony A7C II 内置 CMOS；三张标定照片接入既有 RAW 接口。系数来源与兼容编码见 decisions.md、architecture.md，输入数值契约见 pipeline.md。

已执行：

- `PRINTROOM_CMOS_RAW_TEST=1 scripts/test.sh -c release --filter 'MatrixTests|MatrixEditingTests|RAWSourceServiceTests'`：26 项 XCTest 与 3 项应用测试通过，无失败或跳过。
- 真实 DSC07119.ARW 中心标定均值与全尺寸线性数据独立求均值、TIFF 写出回读取样一致（1e-12）；使用已有 Adobe/LibRaw 缓存链路。测试临时 TIFF 自动清理，原始输入未改写。
- NPY 九个 Float64 系数逐项核对；Sony Float32 系数、旧结构快照读取、只读保护、本机库拒绝覆盖、分类列表通过。
- Sony 应用后 Gain/offset 冻结，撤销/重做/保存重开一致；只有显式重新框片基才校准。补充分类与删除/保存保护后单独重跑 3 项 MatrixEditingTests 通过。
- CPU/Metal 阶段、TIFF 三图求解、L1 导出回读与 RAW 服务身份、失败、取消回归通过。

边界：现有 RAW 是负片扫描样片，尚无三张真实 RGB 单光源标定照片；真实制作矩阵的光学校正效果仍待用户实拍验收。RAW 当前支持 ARW，需本机安装 Adobe DNG Converter。未宣称新机型兼容或视觉颜色已验收。

- `bash scripts/matrix-window-qa.sh` 通过并检查截图：Sony 只读内置、九系数完整显示、TIFF / RAW 入口、双矩阵面板正常。
- `scripts/test.sh -c release --filter 'MatrixTests.testRAWCMOSExportRequests|MatrixTests.testCMOSOnlyExport'`：2 项通过，单张/整卷 RAW 请求保留源保护与机型快照，L1 TIFF 输出回读正确。
- `git diff --check` 通过。统一应用由并行 RAW 任务通过标准 build-app.sh 打包完成：0.3.7/1，固定 output/Printroom.app；ICC/LUT、Metal Apple M4、SDR 冒烟、签名与 LibRaw 资源验证通过，日志 scratch/raw-four-build-app.log。

- `PRINTROOM_CMOS_RAW_TEST=1 scripts/test.sh -c release --filter MatrixTests.testRealRAWCalibration`：1 项通过（含中心均值与真实 RAW Sony L1 全尺寸导出）。回读尺寸保持、按独立 L1 系数计算跨图像采样点 UInt16 完全一致，故意设置的 Gain/Timing/旋转未进入输出。临时输出自动清理。
