# 0.3.16 原位裁剪验收

日期：2026-09-10。交付：`output/Printroom.app`，0.3.16 / build 1；固定标识`studio.printroom.local.v3.3`。基于工作区现有改动，Git HEAD `00cce05`（非本轮独立提交）。本机Apple M4、macOS 26.6.2、Swift 6.3.3。

## 变更

裁剪工具栏原位替换，复用同一CanvasView和固定预览区域。进入、完成、取消期间持续保留旧图及其几何、角度与已有细节图，新图就绪后一起替换并复位视口。等待中的旧图不参与画布手势/精确取样。交互规范见interaction.md，展示状态生命周期见architecture.md。未改算法、项目schema、几何版本及输出管线；保留工作区已有缩略图系统缓存更新。

## 已执行

- `scripts/test.sh --filter 'CropEditingTests|PreviewCanvasTests|SelectionCropTests|RAWGeometryTests|CropCanvasTests'`：32项/5套全部通过。包含新增旧图/几何配对、裁剪重新进入/取消、同一画布身份与固定边界，以及已有快速裁剪切图、选择同步、方向、Undo/Redo、保存、原始样本保护和线性插值回归。日志：`scratch/crop-transition-tests.log`。
- `bash scripts/crop-window-qa.sh --transition-only`：真实EditorView、参考TIFF的scratch副本，R/Enter/Esc、角点拖动、重新进入与取消通过。1060×720窗口中画布全程753×462点，同一对象、同一位置。四张截图位于`scratch/crop-qa/transition-*.png`，已查看普通预览、裁剪、提交截图：单行控件完整，预览不挤动。日志：`scratch/crop-transition-window.log`。
- `scripts/build-app.sh`：release成功；随包ICC/LUT、四种输出profile、Metal Apple M4渲染、UInt16展示验证通过，ad-hoc签名验证通过后覆盖统一应用。日志：`scratch/crop-transition-build.log`。
- 本轮相关源码、测试及脚本的`git diff --check`通过。

首次沙箱内测试因资源/系统临时目录访问失败未通过；同一测试在本机权限下重跑通过。旧布局测试的顶部143点已按原位工具栏更新为104点；脚本debug优化参数改为显式-Onone，修复macOS Bash空数组报错。

## 验证边界

截图和模型/窗口断言验证布局与展示状态连续性，未做高帧率录屏或帧时间量测。已裁剪/放大画面仍会在目标图就绪时调整构图；用户实际手感待试用确认。本轮未重复全尺寸导出、真实RAW解码、跨显示器与旧系统验收，历史结论保持原范围。原始参考资产未修改，测试项目仅写scratch/临时目录。
