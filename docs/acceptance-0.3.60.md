# 0.3.60 调色面板验收

2026-09-19，构建1。交付 `output/Printroom.app`。

- 缩小管理矩阵、框选片基、简易/RGB及矩阵/LUT控件文字；增加01标题与矩阵行间距、02上下留白。具体规格见 interaction.md。
- 矩阵使用原生 NSPopUpButton，共享选择器列宽，保留预设与本卷快照标签、选择回调及禁用语义。
- `bash scripts/editor-window-qa.sh --release --skip-build --themes` 通过浅→深→浅同窗口渲染；已查看浅色简易、深色RGB截图，无标题重叠，两个矩阵可见边界一致。截图 `scratch/editor-ui-qa/theme-{light-editor,dark-rgb}.png`，日志 `/tmp/printroom-0360-ui.log`。
- `scratch/editor-ui-qa/window-qa --timing --appearance` 通过：矩阵控件各200点宽、左边对齐、菜单项目及选中项有效；简易/RGB分别7/8个滑杆、Contrast位置固定、照片参数保持。日志 `/tmp/printroom-0360-timing.log`。可复现命令为 `bash scripts/editor-window-qa.sh --release --timing --appearance`。
- `scripts/build-app.sh` release、ICC/LUT/五输出空间、Metal渲染及签名验证通过，成功替换固定应用。日志 `/tmp/printroom-0360-build.log`。首次沙盒内窗口脚本遇SwiftUI宏插件限制，最终在沙盒外验证。
- `git diff --check` 通过。仅UI布局变更，未重跑图像数值算法测试；真实菜单点击、用户主观观感与旧系统尚未验收。最小窗口下末尾LUT通过面板滚动访问。
