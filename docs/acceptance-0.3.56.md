# 0.3.56 UI 语义色板验收

日期：2026-09-19。固定交付 `output/Printroom.app`，版本 0.3.56 / 1，标识继续为 `studio.printroom.local.v3.3`。

## 变更

从现有 0.3.55 工作区出发，保留此前未提交改动。`AppAppearance.swift / InterfaceColors` 集中管理 window、两级 panel、control、hover、selected、accent、三级文字、边界、直方图与独立 AppKit canvas。具体色值与规则以 interaction.md 为准。

浅色采用暖灰 UI，中性灰 Canvas；深色保留暖金与 #484848 Canvas。顶部、预览工具栏、Inspector、Filmstrip、直方图、近期胶卷与矩阵选择接入共享角色；浅色 RGB 通道加深，Inspector 内部分隔线减弱，Filmstrip 增加同体系悬停底色。保留原生输入框、按钮、下拉、分段和滑杆的尺寸、焦点、禁用与操作行为。布局、字体、算法、ICC、项目结构未修改。

## 已执行

- `bash scripts/editor-window-qa.sh --release --themes`：同一 1060×720 窗口按浅→深→浅切换，生成简易编辑器、RGB、裁切和主页共 12 次离屏渲染（最终保留 8 张）。读取并检查浅/深编辑器、RGB、裁切与主页截图，主体分区、Canvas、金色选中与文字层次清楚，布局保持。截图为内存合成渐变与隔离偏好，不写入用户胶卷。
- 额外检查活动窗口状态：QA 将自身窗口设为 key，避免原生控件失焦时统一变灰影响颜色评估。PreviewToolLabel 和 Filmstrip hover 通过共享色板及代码路径检查；真实鼠标悬停尚未逐项录制。
- `scripts/build-app.sh`：release 编译、ICC/LUT 与五种输出 profile 验证、Apple M4 Metal 冒烟、SDR UInt16 预览验证、ad-hoc 签名及严格验证成功，再替换固定应用。
- `git diff --check` 通过。本轮仅颜色与视觉状态，未新增算法测试，也未将历史数值验收视为本轮重跑。

截图：`scratch/editor-ui-qa/theme-{light,dark}-{editor,rgb,crop,home}.png`。构建与 QA 日志：`/tmp/printroom-theme-build.log`、`/tmp/printroom-theme-qa.log`。

沙盒内 SwiftPM release 编译成功，但独立 QA 编译被 SwiftUI 宏的 sandbox 限制阻止；在沙盒外复验成功。既有 EditorModel 的 weak capture 警告仍存在，本轮未改其任务逻辑。

## 边界

用户实际照片的主观观感、其他 macOS/显示器、逐项真实鼠标 hover / 展开菜单 / 数值编辑焦点，仍待人工验收。离屏截图不等同于全套交互测试或图像数值验收。原生控件的具体绘制随 macOS 和窗口活动状态变化。
