# 0.3.10 界面与图标验收

2026-09-09；Git 基点 `00cce05`，共享工作区含既有未提交修改，均保留。macOS 26.6.2 (25G83)、Apple M4、Swift 6.3.3。

交付 `output/Printroom.app`，版本 0.3.10 / 1，固定应用名称及标识。删除欢迎页指定两行说明；照片画布使用显式 sRGB 145/255 三通道；深灰香槟金相纸图标打包为 ICNS。规范见 interaction.md。算法/schema 不变，未改原始输入。

已执行：

- AppKit 图标生成与 `iconutil` 转换成功；检查 1024 px 预览，包内 ICNS 与源资源 `cmp` 一致，Info.plist 图标引用及 `plutil -lint` 通过。
- `scripts/build-app.sh` release 编译、ICC/LUT 与四输出 profile、Metal M4 冒烟渲染、UInt16 SDR 展示和 ad-hoc 签名验证全部通过后替换旧包。
- `bash scripts/editor-window-qa.sh --release --skip-build --appearance` 使用合成图像和真实 EditorView，AppKit 离屏绘制 1060×720 布局成功。检查 `scratch/editor-ui-qa/10-gray-preview.png` 和 `09-empty-state.png`，确认照片周围灰底、欢迎页两行文案消失且打开按钮保留。此模式仅验证布局，不代表实际屏幕色彩验收；测试模型由有图状态清空，残留计数/尺寸不是新会话状态。
- `git diff --check` 通过。

限制及未执行：系统 `screencapture` 返回 “could not create image from window”，实际屏幕截图未完成。首次图标生成受默认模块缓存权限影响，改为工作区缓存；沙盒内 iconutil 拒绝有效 iconset，获工具批准后在沙盒外成功。未重跑无关算法、真实 TIFF/RAW、导出及性能全套历史验收；Dock/Finder 实际呈现及用户视觉验收待执行。


## 构建 2：深灰底色试用

用户明确改用 `#484848`，不需要切换功能。主预览画布改为显式 sRGB 72/255 三通道。`scripts/build-app.sh` release 编译、包内 ICC/LUT 与四输出 profile、Metal M4 渲染、UInt16 SDR 预览及签名验证通过后覆盖 `output/Printroom.app`（0.3.10 / 2）；`git diff --check` 通过。本轮未重跑截图或无关算法回归，视觉效果由用户试用确认。
