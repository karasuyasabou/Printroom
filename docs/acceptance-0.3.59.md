# 0.3.59 方向图标验收

2026-09-19，构建1。交付 `output/Printroom.app`。

- 预览工具栏移除“方向”菜单，改为左旋90°、右旋90°、水平翻转、垂直翻转四个图标，沿用当前帧操作并提供悬停提示和辅助功能名称。
- 按追加要求移除系统“方向”菜单及旋转、翻转、重置方向入口；原始分辨率1:1移至显示菜单，保留⌘1。Filmstrip右键批量操作与现有快捷键保持。
- `bash scripts/editor-window-qa.sh --release --skip-build --themes`通过同窗口浅/深/浅主题往返；已查看两种主题的编辑器截图，四个图标完整、工具栏无重叠。截图位于 `scratch/editor-ui-qa/theme-{light,dark}-editor.png`，日志 `/tmp/printroom-0359-ui.log`。
- 最终 `scripts/build-app.sh` release构建、资源、Metal及签名验证通过，已替换固定应用；日志见 `/tmp/printroom-0359-build.log`。首次沙盒内验证无法创建Metal上下文，旧包保留；沙盒外重新验证。
- 仅更改入口与展示，未重跑数值算法测试；四个按钮真实照片点击、系统显示菜单人工验收待执行。
