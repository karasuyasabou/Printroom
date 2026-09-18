# 0.3.42 编辑器滚动条验收

日期：2026-09-18。交付：`output/Printroom.app`，0.3.42 / 1；应用标识保持。

## 变更

Filmstrip 与右侧调色面板使用自动隐藏的 AppKit overlay 滚动条。Filmstrip 改为标题自然高度加独立缩略图区，防止卡片上下被裁切。规范见 interaction.md。保留工作区既有 Neutral LUT 等修改。

## 已执行

- `bash scripts/editor-window-qa.sh --release --scrollbars`：macOS 27.0（26A428）、Xcode 27.0（27A266a）、Apple M4，40张内存合成缩略图。进程参数模拟 AppleShowScrollBars=Always，不修改全局偏好，不打开用户胶卷。
- 实际内容尺寸1060×720和1440×824（请求900高被屏幕约束）：两处 NSScrollView 均为 overlay 且 autohidesScrollers=true；Filmstrip document/clip 均高112点；横向滚动偏移成功改变。调色面板滚至末尾，截图确认 LUT 可达。
- 查看 `scratch/editor-ui-qa/scrollbars-idle-1060.png` 和 `scrollbars-1440.png`：闲置时无常驻滚动条，完整卡片顶部、底部、文件名和边框可见。视口左右端部分卡片被截断属于正常横向边界。
- 窗口验证脚本明确使用 native 构建方式，保持独立QA对象文件链接布局，兼容新Xcode默认构建方式改变。
- `scripts/build-app.sh`：release构建、包内ICC/LUT及四种输出profile、Metal Apple M4渲染、sdr-uint16-v1预览、严格签名验证通过，成功后覆盖固定应用。
- `git diff --check` 通过。

首次沙盒内dSYM生成和Metal上下文创建受限；在已授权的沙盒外重跑成功，失败期间旧应用保留。构建仍有既有EditorModel捕获警告及native构建方式弃用提示。

## 边界

未重复无关算法和导出全量测试。旧macOS、外接显示器、实际鼠标/触控板淡入淡出手感及运行中切换系统滚动条偏好尚未验证；不声明macOS 27是旧版裁剪问题的唯一原因。
