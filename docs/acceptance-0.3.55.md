# 0.3.55 深浅外观验收（2026-09-19）

交互规范见 [interaction.md](interaction.md#0355-深浅外观)。应用标识不变，输出仍为 `output/Printroom.app`，构建1。保留任务开始时已有的工作区修改。

## 已执行

- native debug 编译通过，日志 `/tmp/printroom-theme-build.log`。
- `bash scripts/editor-window-qa.sh --skip-build --themes`：同一1060×720窗口浅→深→浅及主页截图通过，日志 `/tmp/printroom-theme-qa.log`。人工查看浅色编辑器/主页、深色编辑器渲染图，工具栏、文字、滑杆、选中边框及直方图可辨；浅色照片画布白色、深色灰色。
- 截图位于 `scratch/editor-ui-qa/theme-{light,dark}-{editor,home}.png`，仅自有窗口合成渐变输入。首次 QA 因沙盒阻止 SwiftUI 宏失败，沙盒外重新编译与运行成功。主页夹具补充清除预览后重跑通过。
- `scripts/build-app.sh` 成功：release、随包 ICC/LUT、五输出空间与 Metal Apple M4 冒烟检查、SDR UInt16 预览验证、ad-hoc 签名验证均通过；随后替换正式包。日志 `/tmp/printroom-theme-package.log`。
- `git diff --check` 通过。

## 边界

本轮没有重跑图像算法全套测试。菜单人工点击、退出重启偏好恢复、辅助窗口与每个弹窗的逐项观感尚未人工验收；主窗口验证直接调用同一应用级外观入口，不冒充菜单点击验证。主题使用本机 AppStorage，未修改项目结构或图像计算。
