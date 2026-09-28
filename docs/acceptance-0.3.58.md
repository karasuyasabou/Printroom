# 0.3.58 界面布局验收

2026-09-19，构建1。交付 `output/Printroom.app`。

- 直方图背景半透明，绘图区域四边细框；矩阵上下两行。
- RGB Timing / Contrast显示Master、Red、Green、Blue；简易与RGB统一标签列、滑杆端点和数值框。具体规范见interaction.md。
- `scripts/build-app.sh`通过release构建、ICC/LUT及五输出profile资源检查、Apple M4 Metal渲染与签名验证。首次沙盒内资源验证无法创建Metal上下文，未替换旧包；沙盒外重跑通过后交付。
- `bash scripts/editor-window-qa.sh --release --skip-build --themes --timing --histogram`实际执行themes分支，深浅往返截图通过。已查看light RGB和dark简易截图，确认矩阵两行、标签完整、滑杆/数字框对齐和直方图背景透出图像、四边框可见。
- 分别执行 `scratch/editor-ui-qa/window-qa --appearance --timing` 和 `--appearance --histogram`：7/8条滑杆、Contrast位置固定、模式切换不改变照片参数通过；Final/Density、收起展开、悬停标记与面板指针排除通过。
- 日志：`/tmp/printroom-0358-{build,ui,timing,histogram}.log`；截图：`scratch/editor-ui-qa/`。`git diff --check`通过。

未完成：真实照片上透明度的主观观感待用户确认；未重跑全套算法测试（本轮仅展示变更）。

## 构建2：浅色明度微调

按用户最新指定更新浅色panel、secondaryPanel和canvas，window保持指定原值；唯一色值表见interaction.md，其他颜色及深色不变。release构建、资源/Metal/签名通过，已替换固定应用。`bash scripts/editor-window-qa.sh --release --skip-build --themes`深浅往返完成，已查看浅色编辑器截图确认浅灰Canvas与面板层级；`git diff --check`通过。日志：`/tmp/printroom-light-tune-{build,qa}.log`。本轮仅色值修改，未重跑功能测试，实际照片主观观感待用户确认。
