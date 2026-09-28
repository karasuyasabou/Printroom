# 0.3.50 整卷自动调色验收

日期：2026-09-19。交付 `output/Printroom.app`，版本0.3.50、构建1；应用标识保持studio.printroom.local.v3.3。

## 交付内容

整卷共享RGB Timing，曝光P95对齐685 CV；色偏以整卷稳健灰世界估计。需有效片基对齐，只分析已提交裁后画面。TIMING魔棒直接分析，完成后仅显示默认未勾选的“保留已调色”和取消/应用。应用整组一次撤销、保存和重做；用户继续逐张精调。数值、事务和交互契约分别见pipeline.md、architecture.md、interaction.md末节。

## 已执行

- `scripts/test.sh --filter 'RollTiming|NeutralTimingTests|AutoCropEditingTests|MatrixEditingTests'`：XCTest 21项，20通过、1跳过；Swift Testing 17项全部通过，合计37通过、1跳过。日志 `/tmp/printroom-roll-validation.log`。
- 本轮新增11项测试：P95与高于参考白样本、已知共同色偏恢复、整数曝光误差、非法/超范围、裁后采样、统一覆盖与持久化/撤销/重做、保留已调色、取消/过期、校准门槛、源变化、实际合成TIFF裁切及旧调色无关性。
- 初次沙盒测试因Metal上下文不可用失败；沙盒外重跑通过。既有真实TIFF吸管测试因本地参考文件不存在跳过，不计通过。
- `bash scripts/editor-window-qa.sh --release --skip-build --roll-timing --appearance`：1060×720最小窗口入口、分析与结果视图离屏渲染完成并目视检查，文本和按钮无裁切，结果勾选默认关闭。图像在`scratch/editor-ui-qa/roll-timing-{entry,progress,result}.png`，日志`/tmp/printroom-roll-ui-final.log`。实际sheet存在性已检查；sheet自身的系统合成面不能完整离屏截图，因此使用同一SwiftUI视图在独立窗口、不透明背景下渲染检查内容。
- 系统窗口截图首次失败（could not create image from window），未据此声称实际屏幕截图验证成功。QA重复运行的临时文件重名已改为UUID隔离目录。
- `scripts/build-app.sh`：release构建、打包ICC/LUT及五输出profile验证、Metal渲染验证、ad-hoc签名及严格签名校验通过；成功后替换固定应用路径。最终日志 `/tmp/printroom-roll-build-final.log`。
- `git diff --check`通过。
- 资产基线检查：原ICC与两份原LUT哈希通过；清单中的10份TEST/TIFF均已缺失，完整基线无法完成。本轮未修改原资产。

## 待验收/限制

真实胶卷调色观感、题材单一胶卷的误校色程度、超长卷耗时仍需试用。灰世界、降权和修剪比例是工程默认，不保证真实光源中性或全局最优。P95规则不识别真正90%漫反射白，也不承诺5%的高光都不会被LUT剪切。现有缺失参考TIFF未补造，未做真实胶卷图像结果验收。

## 构建2：恢复结果数值

用户要求完成窗口显示“分析完成”、整卷RGB Timing及带符号的三个整数，下方补“保留已调色”（默认不勾选），按钮为取消/应用到整卷。仅增加求解结果的只读展示，不改变算法或应用逻辑。

已执行release构建、资源/Metal/签名验证，覆盖output/Printroom.app（0.3.50构建2）；日志`/tmp/printroom-roll-result-build.log`。既有窗口脚本以`--release --skip-build --roll-timing --appearance`渲染并目视检查入口、进度及完成视图，RGB单行、复选框和按钮均完整；日志`/tmp/printroom-roll-result-ui.log`。本轮为展示调整，未重复运行上一构建的数值测试；真实窗口人工操作及真实胶卷观感仍待用户确认。
