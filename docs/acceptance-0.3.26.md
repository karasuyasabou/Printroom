# 0.3.26 直方图精简验收

日期：2026-09-12；Apple M4，本机 macOS。交付 output/Printroom.app，版本 0.3.26，构建 1，标识 studio.printroom.local.v3.3。基于已有未提交工作区修改，未创建提交。

移除信息按钮及统计弹窗；右上角收起／展开；Density / Final 独立切换，默认 Final，固定 RGB 叠加。Density 映射与统计契约见 pipeline.md，交互见 interaction.md。算法版本、项目 schema 与原始资产保持。

## 已执行

- `scripts/test.sh --filter 'HistogramDisplayScaleTests|OrientationHistogramTests|EditingV2Tests|EditorRefinementTests|AdjustmentSchedulingTests'`：11 项 XCTest、29 项 Swift Testing，全通过。覆盖分布/纵轴、整图统计、快速切帧与阶段切换、独立直方图阶段、连续调色与图像统计同步发布、预览像素参考比较、方向和 1:1 统计隔离。日志 scratch/histogram-0.3.26-tests-unrestricted.log。
- 首次沙箱内运行 AppAssets 无法初始化，沙箱外重跑后恢复；发现并更新一处旧阶段跟随断言，再次全部通过。
- `scripts/build-app.sh`：release 成功，资源/四输出 profile/Metal Apple M4/SDR 预览格式/ad-hoc 签名验证通过，成功后替换固定应用。日志 scratch/histogram-0.3.26-build.log。
- `bash scripts/editor-window-qa.sh --release --skip-build --histogram`：1060×720 自有窗口，生成并检查 Density、Final、收起和重新展开截图。位于 scratch/editor-ui-qa/23-histogram-night-rgb.png、24-histogram-night-density.png、25-histogram-collapsed.png、26-histogram-expanded-final.png。无信息按钮和旧通道选项，箭头右对齐，标签无截断。

## 边界

窗口 QA 使用内存合成数据和程序设置状态，未执行真实鼠标点击回归；ViewportWindowQA 已更新切换目标，本轮未运行。未重新执行全套真实 TIFF/RAW 导出或跨显示器外观验收。本轮需求已实现，实际照片观感待用户试用。
