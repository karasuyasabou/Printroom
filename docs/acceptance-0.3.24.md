# 0.3.24 简易整数显示与长按减速

日期：2026-09-12。固定交付 output/Printroom.app，版本 0.3.24 / 1。算法 v4、schema 6、几何版本 2 保持。保留工作区此前修改，未提交 Git。

- 简易曝光/色温/色调显示整数，底层分数余量保持；Timing 与 Contrast 长按速度减半，帮助文案同步。行为以 interaction.md 为准。
- `scripts/test.sh --filter 'SimpleTiming|TimingKeyboardTests|EditorKeyboardRoutingTests'`：15 项测试、3 个 suite 通过，覆盖连续速率边界、单击与 Shift、停止/撤销、模式与按键路由。首次沙盒运行因 Metal 资产初始化失败出现一项失败，本机重跑全部通过。
- `scripts/build-app.sh`：release 构建、ICC/LUT、四输出 profile、Metal Apple M4、UInt16 预览与签名验证通过，成功覆盖固定应用包。
- 日志：scratch/simple-display-keyboard-tests.log、scratch/simple-display-keyboard-build.log。
- 未执行真实窗口视觉与长按手感验收；未重跑全套图像/导出测试。原始 TIFF、ICC、LUT 未修改。
