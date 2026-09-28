# 0.3.68 裁剪预览验收

日期：2026-09-28。管线预览左侧新增默认勾选的裁剪预览；关闭显示完整画面、隐藏裁剪微调角度，保留独立方向和调色。直方图仍使用保存的裁剪范围，开关不修改项目或导出设置。交互、结构与像素范围分别见 interaction.md、architecture.md、pipeline.md。

## 已执行

- `scripts/test.sh --build-system native --filter 'SelectionCropTests|EditorRefinementTests|EditingV2Tests|CropEditingTests'`：运行49项测试（过滤同时匹配AutoCropEditingTests），46项通过，3项旧测试因仍假定Identity默认矩阵或已移除的原生P3输出而失败。将校准参考改为当前矩阵；导出快照测试明确指定Display P3，并按对应ICC转换比较输出。
- `scripts/test.sh --build-system native --filter 'displayedSamplingMapsToOriginalAfterRotationAndFlip|cropHistogramAndDetailRemainCroppedWhileBaseSamplingTemporarilyShowsFullSource|exportWhileEditingUsesCapturedTargetsDirectionAdjustmentsAndProfile'`：上述3项修正后全部通过。两次合计49项均有通过结果；日志在 `/tmp/printroom-0.3.68-tests.log` 和 `/tmp/printroom-0.3.68-retest.log`。
- 新增测试覆盖全部八种D4方向、三种显示阶段、带微调角度的裁剪：关闭时全图像素与无裁剪参考相同，直方图与开启时相同。模型覆盖Final/Density统计、默认勾选、新实例默认、切帧保持、100%细节、进入/取消/完成裁剪、快速开关与继续调色；检查照片设置、校准、导出偏好与撤销状态不因开关变化。
- `bash scripts/editor-window-qa.sh --skip-build --crop-preview`：生成1060宽最小窗口深浅色、勾选/未勾选四张截图，目视检查复选框、工具栏文字和相邻按钮完整可见。位于 `scratch/editor-ui-qa/crop-preview-*.png`；此脚本使用内存合成画面，只验证布局，裁剪行为由上述临时TIFF测试验证。
- `scripts/build-app.sh`：release构建、ICC/LUT、五项输出profile、Apple M4 Metal、SDR预览和ad-hoc签名验证通过，成功覆盖 `output/Printroom.app`，版本0.3.68、构建1。
- `git diff --check`通过。

## 边界

未执行真实RAW胶卷人工点击或性能测量；未改动原始TEST/ICC/LUT资产与用户胶卷。项目格式和图像算法版本保持。
