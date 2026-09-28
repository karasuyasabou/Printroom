# 0.3.57 原生 Toolbar 与中性浅色

日期：2026-09-19。交付固定 `output/Printroom.app`，版本0.3.57 / 1，应用标识保持。

## 变更

- 内容区原65pt主工具栏迁入系统 SwiftUI Toolbar；navigation 品牌、principal 弹性空间、primaryAction 操作。主窗口 hiddenTitleBar + unified，红黄绿为系统原生按钮，未自行绘制或重定位，不再显示重复系统标题行。
- 保留文字和图标、动作/确认/禁用条件及关闭保存检查。加载期间品牌和窗口按钮可见，主操作禁用。macOS15+全屏主 Toolbar 显式可见，macOS14使用系统默认；辅助窗口保持。
- 按用户给定Light色值替换语义色板，变量结构与全部Dark色值保持。Canvas保留中性灰。普通顶部动作使用neutral control/hover与文字，不再使用金色浅棕底；金色保留品牌和选中语义。
- 图像算法、ICC、原始资产及用户胶卷未修改；保留开始任务时已有的未提交工作。

## 验证

- `bash scripts/editor-window-qa.sh --release --window-chrome`：以NSHostingController驱动真实系统Toolbar，浅→深→浅，简易/RGB/裁切/主页，截图包含AppKit窗口框架及真实红黄绿。1060宽度完整显示品牌、全部文字操作按钮，原独立标题行消失。宽窗口及全屏返回布局检查。
- 窗口脚本检查native close/minimize/zoom存在、标题隐藏、可移动/可调整尺寸；实际执行调整大小、最小化/恢复、全屏进出。最小窗口框架1060×772，宽窗口因屏幕可用范围限制为1360×856，全屏1470×923；不将请求尺寸当作实际尺寸。
- `scripts/test.sh --build-system native -c release --filter 'EditorWindowCloseTests|EditorKeyboardRoutingTests'`：10项通过，包括正常关闭路由、退出取消保留窗口、只安装在主窗口，以及文本焦点/失焦/快捷键路由。
- `scripts/build-app.sh`：release构建、ICC/LUT及五种输出profile、Metal Apple M4冒烟、SDR UInt16与ad-hoc签名验证成功后替换固定应用。
- 全屏补验：Toolbar被AppKit移入独立窗口，`isVisible=true`，frame `(0, 871, 1470, 52)`；额外捕获并检查 `unified-fullscreen-toolbar.png`，品牌和全部主操作仍可见。
- `git diff --check`通过。既有weak capture及try?结果未用警告仍存在，本轮未修改其逻辑。

日志：`/tmp/printroom-unified-{qa,tests,build}.log`。截图：`scratch/editor-ui-qa/theme-{light,dark}-{editor,rgb,crop,home}.png`、`unified-{large,fullscreen,restored}.png`。

## 验收边界

真实鼠标拖窗、绿钮悬停菜单、其他macOS/显示器及用户照片主观观感待人工验收；拖动沿用AppKit原生标题栏空白区域，没有自定义拖动事件。全屏时系统可能把标题栏移入独立窗口，主窗口离屏截图不一定包含该窗口。未将窗口脚本测试视为完整人工交互验收。
