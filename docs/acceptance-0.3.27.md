# 0.3.27 移除白点校正与两卷补偿

2026-09-12，Apple M4。统一交付 `output/Printroom.app` 0.3.27 / 1，标识 `studio.printroom.local.v3.3`；算法v5、schema6、几何2。

## 变更

按用户要求删除运行时白点求解器、CubeLUT偏移字段和CPU/Metal/吸管的偏移采样，AppAssets恢复原始cube读取。D3直接进入LUT，685反差pivot保持。其他旧项目仅迁移算法，不自动补偿Timing；旧算法首次覆盖前沿用原字节备份。

用户另指定以下两卷，已在各自原目录完成一次性调色补偿：

- `2026-09-01-1/RAW`，项目 `8AF277FF-1951-4115-82F4-E5EC607CC06E`：36张，全部Fujifilm。
- `2026-09-01-2/RAW`，项目 `D8333AD0-51B4-43F4-B26F-83B3D354A7F5`：40张，39张Kodak、1张Fujifilm。

路径均位于 `/Users/bao/Library/CloudStorage/SynologyDrive-BaoNAS/Photos/Film/`。只修改RGB Timing、算法版本和更新时间；Master、反差、片基、矩阵、LUT选择、裁剪、方向及其他JSON字段经结构对比确认保留。补偿公式以pipeline.md为准，不引入隐藏运行时参数。

## 原设置备份

正常退出应用、确认源SHA未变后，在NSFileCoordinator写协调中先备份再原子替换：

- 第一卷：`.printroom-before-white-removal-829E9D7A-B753-4036-BD91-D111937224C0.json`
- 第二卷：`.printroom-before-white-removal-3C2ABCBF-7477-4700-8B50-F4B51371C0C1.json`

正式ProjectStore重新打开两卷成功，76帧和校准与候选一致，备份SHA与补偿前原文件完全相同。应用已重新打开。

## 验证

```sh
scripts/test.sh --filter 'DirectLUTTests|CineonLUTTests|NeutralTimingTests|PivotMigrationTests|PipelineTests|MetalTests|CropTests|RollProjectTests'
scripts/build-app.sh
shasum -a 256 -c assets/SHA256SUMS
```

88项XCTest + 9项Swift Testing通过，0失败；覆盖CPU/Metal直接LUT采样、正式资源/预览/双LUT混合导出回读、吸管、反差、裁剪和项目迁移。Release构建、资源/四输出profile、实际Metal/UInt16预览和签名验证成功后替换固定应用包。13项原始资产哈希通过。

独立 `scripts/white-removal-compensation.sh prepare|apply|verify scratch/white-removal <卷1> <卷2>` 已依次执行；prepare只写工作区，apply仅对指定两卷写入，verify用正式项目加载器检查。最初脚本链接通配符包含已删除源文件的旧对象，改用SwiftPM当前sources对象列表后运行成功，未因此写入原项目。

使用已有RAW代理，按长边320读取全画幅取样（不重做RAW转换、不改原片）；每张对比v4原偏移输出与v5补偿输出。总计5,180,160像素，逐帧报告见 `white-removal-2026-09-12.json`。

| 胶卷 | 最大D3舍入残差CV | 最大RGB编码误差 | 单帧最大RMS | 最大CPU/Metal误差 |
| --- | ---: | ---: | ---: | ---: |
| 09-01-1 | 0.4605675 | 0.0030719042 | 0.0005562784 | 3.8743e-7 |
| 09-01-2 | 0.5275993 | 0.0032476336 | 0.0006562198 | 4.7684e-7 |

整数Timing无法完全表示历史浮点偏移，因此近似保留原调色，不能宣称逐像素一致。上述RGB差异属于P3 Gamma2.6编码域，不等于色差或显示器测量。未做两卷全分辨率重新导出和视觉逐帧验收；实际外观待用户试用。临时计划、日志位于scratch/white-removal，可清理；原目录备份与本验收报告保留。


## 构建2：直方图指针与 Filmstrip（2026-09-12）

按用户反馈，直方图浮层以实际 NSView 布局边界排除画布光标和空白处拖动/滚动，避免 SwiftUI 背景命中穿透；标题与图表恢复普通箭头。Filmstrip 移除额外黑底，fit 留白透明，保持选中背景、编号和比例。未改图像算法或用户项目。

- `scripts/test.sh --filter 'PreviewCanvasTests|CropCanvasTests'`：最终14项通过；日志 scratch/pointer-filmstrip-tests.log。
- `bash scripts/editor-window-qa.sh --release --histogram`：移动系统鼠标至自有窗口画布、图表及标题，投递 mouseMoved 并调用生产 refreshCursor，断言手形→箭头→手形。首次验证发现 SwiftUI 命中穿透及共享 NSGraphicsView 命中，改用浮层实际边界后通过。日志 scratch/pointer-filmstrip-window.log。
- 窗口截图检查横幅和竖幅缩略图，竖幅两侧与 Filmstrip 底色一致，无黑色衬底。截图 scratch/editor-ui-qa/23-histogram-night-rgb.png；另覆盖 Density、收起与重新展开布局。
- `scripts/build-app.sh`：最终release、资源、Metal Apple M4、SDR格式及签名通过，覆盖 output/Printroom.app（0.3.27/2）。日志 scratch/pointer-filmstrip-build.log。

本轮未执行所有真实照片、全套导出和其他设备验证；原资产保持。真实日常鼠标操作手感仍可由用户试用确认。
