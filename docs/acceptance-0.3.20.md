# 0.3.20 Cineon Log LUT 验收

日期：2026-09-11。本机 Apple M4 / macOS，交付 `output/Printroom.app`，0.3.20 构建 1，应用标识保持 `studio.printroom.local.v3.3`。

## 范围

调色面板末尾新增 Cineon Log LUT，逐帧选择 Fujifilm 3513DI / Kodak 2383，默认 Kodak。同步拆成 RGB Timing、RGB Contrast、Cineon Log LUT、裁剪，每次打开全不勾选、整组一次撤销。复制/粘贴和重置包括 LUT。schema 6 保存选择；旧 schema 默认 2383，首次覆盖保留原字节备份。规范分别见 pipeline.md §8、interaction.md 和 architecture.md 的 0.3.20 节。

## 已执行

- `scripts/test.sh`：XCTest 186 项，8 项按环境条件跳过、0 失败；Swift Testing 108 项通过。该次执行之后新增 LUT 专项，并收敛同步内部字段，随后运行下列直接相关回归。
- `scripts/test.sh --filter 'CineonLUTTests|CropEditingTests|RAWGeometryTests'`：最终 16 项通过。覆盖七种调色组合、未勾选字段保持、来源保持、撤销/重做、保存重开、复制/重置、旧 schema 5 缺失 LUT 默认值与备份字节一致、未知值拒绝。裁剪组合与异步 RAW 几何回归通过。
- 专项使用两份真实 LUT 与合成 TIFF：两张不同 LUT 的同批 GPU 导出逐张回读，每通道相对 CPU 参考量化差不超过 2 个 UInt16 码值；Metal 预览相对 CPU 的单点误差小于 3e-5；固定请求后修改项目不改变导出快照。两份 LUT 的参考结果不同。
- `bash scripts/editor-window-qa.sh --skip-build`：1060×720 真实窗口截图成功，滚动到底部可见完整 05 面板；同步浮层四项完整、默认未选。图像为合成预览，不代表底片外观验收。截图：`scratch/editor-ui-qa/22-cineon-log-lut.png`、`06-sync-minimum-window.png`、`07-sync-popover-25830.png`。非激活窗口截图中原生 Picker 有短暂深色文字；浮层打开后的截图呈正常浅色文字。
- `scripts/build-app.sh`：release 构建成功，打包资源解析/ICC/Metal/SDR 冒烟及 ad-hoc 签名验证通过，最后覆盖统一交付路径。两份包内 LUT 的 SHA-256 与原始文件一致；Fujifilm 为 `415227d60acfc17fba778901f385a140a26ecb9ca7b3eba636c3f49a96d926b7`，Kodak 沿用资产基线。原始 TIFF/ICC/LUT 未修改。
- `git diff --check` 通过。

测试最初在受限沙箱内缺少 Metal 上下文和部分临时目录访问，随后在允许访问的本机环境运行上述正式测试；迁移专项的修改时间参数在测试夹具中修正后通过，不将早期失败计为通过。

## 未执行与边界

本轮未重跑十张参考 TIFF 全尺寸批导、真实 Adobe RAW 转换或所有历史窗口操作；本轮新 LUT 的物理 Cineon 标定、跨显示器色彩外观及用户审美验收仍待执行。吸管选择对应 LUT 的接线已检查，沿用原求解算法与失败条件；本轮未新增 Fujifilm 实际底片中性点取样验收。旧版应用不支持 schema 6；旧项目第一次保存前有原始设置备份。
