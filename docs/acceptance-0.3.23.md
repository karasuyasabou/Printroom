# 0.3.23 切图保留裁剪模式

日期：2026-09-11。固定交付 output/Printroom.app，版本 0.3.23 / 1。算法 v4、schema 6、几何版本 2 保持。工作区含此前修改，本轮未提交 Git。

- 切图行为以 interaction.md 为准；增加加载期间的编辑/提交保护，快捷键帮助同步更新。
- 本机执行 `scripts/test.sh --filter 'CropEditingTests|PreviewCanvasTests|SelectionCropTests|RAWGeometryTests|CropCanvasTests|TimingKeyboardTests'`：40 项测试、6 个 suite 全部通过。涵盖目标扩选、已保存裁剪载入、快速连续切图、加载中取消/提交保护、裁剪画布和 RAW 几何回归。
- 初次沙盒运行无法完整初始化 Metal 资产，且新增防护曾阻止合成画布测试；改为按加载状态与源尺寸保护并在本机重跑。旧选择测试等待普通直方图与新裁剪模式不符，改为等待裁剪预览就绪后全部通过。
- `scripts/build-app.sh`：release 构建、包内资源、四输出 ICC、Metal Apple M4、UInt16 展示与签名验证通过，成功覆盖固定应用。
- 日志：scratch/crop-switch-tests.log、scratch/crop-switch-build.log（临时产物可清理）。
- 未执行真实窗口手动切图验收及全套数值/导出回归；不把模型与画布测试等同于用户实际手感验收。原始 TIFF、ICC、LUT 未修改。
