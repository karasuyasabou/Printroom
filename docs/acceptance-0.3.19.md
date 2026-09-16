# 0.3.19 简易 Timing 验收

日期：2026-09-11；macOS 26.6.2、Apple M4。Git基线00cce05，工作区包含历史未提交内容，本轮未重置或提交其他修改。

## 变更

Timing标题行新增简易/RGB切换，简易曝光、色温、色调三个滑杆。本机记忆模式；切图、切卷、重启保持。切换不改照片、不产生撤销；Contrast位置固定。简易Timing快捷键W/S、Q/E、A/D按用户指定路由，Z/C无动作；所有Option反差快捷键始终保留。帮助窗口已更新。

映射、范围和旧RGB分数余量以pipeline.md的0.3.19节为准。简易模式直接编辑既有整数参数；不增加图像处理阶段或自行更改算法版本。

## 已执行

- `scripts/test.sh --filter 'SimpleTiming|TimingKeyboardTests|EditorKeyboardRoutingTests|PipelineTests|MetalTests|EditorIntegrationTests|EditingV2Tests'`：最终31项XCTest通过；Swift Testing共36项，其中35项通过、1项全分辨率参考导出条件未启用而跳过。合计66项通过、1项跳过。
- 覆盖独立解析坐标与反解、已有分数坐标不漂移、81组边界初始状态×三轴×四种步进的整数合法性/非活动轴保持/整轴限幅；真实2383 LUT中间调的亮/暖/洋红方向。
- 模式反复切换不改参数或撤销栈、切图和新模型恢复偏好；切换终止长按；三组正反Timing按键、Shift与系统repeat、Z/C空操作、两种模式全部反差按键；原生滑杆继承半步时步进正确，达到整轴边界时回显真实值。
- 拖动整组撤销、JSON回读、复制/应用及撤销；现有CPU/Metal一致性、项目保存重开和快照导出回归。最终日志 `scratch/timing-test.log`。
- `bash scripts/editor-window-qa.sh --timing`：1060×720真实测试窗口截图；简易7条滑杆（3 Timing+4 Contrast）、RGB8条滑杆，Contrast位置差<1点，模式切换前后照片参数完全相同。已人工查看两张截图，标题切换/吸管/数值没有重叠。日志 `scratch/timing-ui.log`，截图 `scratch/editor-ui-qa/20-timing-simple.png`、`21-timing-rgb.png`。
- 初次沙盒测试无法创建Metal上下文；在本机权限下重跑后上述Metal检查通过。测试夹具曾缺少合法ICC，已修正后通过，不属于正式功能失败。

## 打包与并行工作

0.3.19已通过release构建、ICC/LUT及四输出profile校验、Apple M4 Metal出图、SDR预览和签名验证，交付固定output/Printroom.app。随后补充滑杆在边界无参数变化时立即回显真实值，相关最终测试已通过；再次打包时同目录“添加 Cineon Log LUT 面板”任务正在修改公共代码（升级0.3.20），曾因其跨模块校验调用访问权限错误而失败。脚本保留已有可用包，未清除另一任务的改动。最终合并打包结果在下方补记。

## 验证边界

未重新运行全分辨率真实参考TIFF导出、其他机型/系统或全部RAW测试。窗口检查采用合成渐变与内存项目；真实照片的调节灵敏度和视觉外观仍待用户试用确认。默认LUT方向测试不代表所有像素或所有RGB反差设置下严格保持亮度/色相。未上传原片、创建远端或发布。

## 最终合并交付补记

同目录LUT任务修正公共代码后，重新执行 `scripts/test.sh --filter 'SimpleTiming|TimingKeyboardTests|EditorKeyboardRoutingTests'`，4项核心测试与15项界面/键盘测试全部通过（`scratch/timing-merged-test.log`）。`scripts/build-app.sh`最终成功构建并覆盖 **output/Printroom.app，0.3.20（1）**，包含本轮全部Timing改动及并行LUT功能；ICC/LUT、四输出profile、Apple M4 Metal、SDR及签名校验通过（`scratch/timing-build.log`）。

`bash scripts/editor-window-qa.sh --release --skip-build --timing` 对最终合并release版本再次通过7/8滑杆、固定Contrast位置和参数不变检查，截图已更新至上述路径。`shasum -a 256 -c assets/SHA256SUMS`全部13项通过（包含新登记的Fujifilm LUT）；原始参考TIFF、ICC和LUT字节保持。
