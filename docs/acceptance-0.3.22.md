# 0.3.22 LUT 参考白中性校正验收

2026-09-11，Apple M4。交付 `output/Printroom.app` 0.3.22 / 1，标识保持 `studio.printroom.local.v3.3`。算法 v4，schema6，几何2。公式唯一来源为 pipeline.md 文末；项目备份规则见 architecture.md。

## 实现

所有当前可选 LUT 在资源加载时经同一求解入口准备；原cube不变，派生浮点RGB密度偏移在反差后、LUT前应用一次。保持等值685 CV原输出的ICC线性Y，使RGB相等。可见Timing/Contrast及D3诊断不变；吸管初始测量、连续拟合、格点起点与最终整数验证均包含校正。旧项目保留参数，首次保存备份原JSON后迁移算法；缩略图随算法身份失效。

## 实测

| LUT | RGB偏移（CV） | 685输出RGB（各通道约） | 原线性Y | 校正后线性Y |
| --- | --- | --- | --- | --- |
| Kodak 2383 | −32.822400, +30.846088, −34.341156 | 0.8427819 | 0.6410015041 | 0.6410016146 |
| Fujifilm 3513DI | −22.539433, +39.858635, −73.517510 | 0.8400562 | 0.6356253645 | 0.6356254177 |

Y验证使用独立的固定ICC Y行和TRC常量，不调用生产目标计算函数。每份LUT以1331个色阶组合及非单位RGB反差/Timing验证CPU/Metal：Kodak最大误差2.5332e-7，RMS3.2203e-8；Fuji最大误差1.7881e-7，RMS3.2794e-8。

实际命令：

```sh
scripts/test.sh --filter 'LUTWhiteBalanceTests|CineonLUTTests|NeutralTimingTests|PivotMigrationTests|PipelineTests|MetalTests|CropTests|RollProjectTests'
scripts/build-app.sh
shasum -a 256 -c assets/SHA256SUMS
```

- 89项XCTest + 8项Swift Testing通过，0失败、0跳过；包括正式AppAssets双LUT预览、混合LUT导出回读、吸管、反差固定点、原格点与重复准备、Identity和不可达LUT、旧项目原字节备份及保存重开。
- 原有schema1迁移测试的输出期望显式固定为历史无压缩，避免上一版ZIP默认值使测试错误地要求改变旧项目输出设置。
- Release构建、随包资源/四输出profile校验、Metal实际渲染、UInt16预览和ad-hoc签名验证成功后覆盖固定应用包。
- 13项原始资产哈希通过，包括两份cube、ICC和十张TIFF。
- 初次沙箱运行无法访问Metal和macOS文件协调；以授权沙箱外本地运行完成上述验证。首轮还发现旧schema1测试默认压缩期望过时，修正后完整重跑上述相关集合。

本轮未做实际窗口截图、全卷全分辨率批导或跨显示器外观验收。校正仅保证参考白点保持亮度和中性，不能据此宣称全图亮度不变或整条灰阶中性；照片外观待用户试用。日志位于可清理的scratch/white-tests.log和scratch/white-build.log。
