# 0.3.9 矩阵联动片基验收

日期：2026-09-09。基于 Git `00cce05` 的已有工作区继续修改；工作区原有多项未提交变更均保留。环境：Apple M4、macOS 26.6.2、Swift 6.3.3。算法仍为 `printroom-density-v3`、schema 5、几何版本 2。

## 变更

应用卷级矩阵时按 pipeline.md §6 自动重新对齐。CMOS 沿原始片基选区重新读取并计算，密度矩阵保留 Gain 重算 offset；旧项目若 CMOS 与采样快照不同则重新取样。已存设置在成功前保持，成功后矩阵与校准一起提交及撤销。逐帧调色保持。库保存/删除不联动卷，加载旧项目不主动改变画面。

## 实际执行

- `scripts/test.sh --filter 'MatrixEditingTests|MatrixTests|RollProjectTests'`：XCTest 37 通过、1 跳过；Swift Testing 4 通过。验证合成 TIFF 片基 95 CV（误差 <0.01 CV）、CMOS Gain 更新、密度 Gain 保持、采样快照、撤销重做、保存重开、连续 CMOS/密度请求合并、取消、负片基失败、原图修改/丢失失败及帧参数保持。首轮沙箱内因 macOS 文件协调及资源访问失败，随后授权在沙箱外执行通过。
- `scripts/test.sh --filter 'AdjustmentSchedulingTests|PipelineTests|MetalTests'`：XCTest 27、Swift Testing 5 均通过。Metal 检查 4099 像素 × 2 矩阵 × 3 调色 × 8 阶段，最大误差 3.8146973e-06；预览调度、卷级缩略图刷新与撤销回归通过。
- `shasum -a 256 -c assets/SHA256SUMS`：全部 12 项原始 TIFF/ICC/LUT 通过。
- `scripts/build-app.sh`：release 构建成功，打包资源与四种输出 profile、Metal 渲染及 UInt16 预览验证成功，ad-hoc 严格签名验证通过。交付唯一 `output/Printroom.app`，0.3.9 build 1，标识保持 `studio.printroom.local.v3.3`。
- `git diff --check`：通过。

合计 73 项测试通过、1 项跳过。测试文件均使用临时目录，不修改原始资产及用户矩阵库。

## 本轮未执行

真实 RAW 标定测试需要显式环境开关，本轮跳过；未重新执行真实 RAW 全尺寸链路、全套实际 TIFF 导出回读或窗口视觉验收。旧项目 CMOS 快照不一致的重新采样分支已实现，本轮没有单独的旧项目端到端用例。数值测试不代表用户色彩外观验收。
