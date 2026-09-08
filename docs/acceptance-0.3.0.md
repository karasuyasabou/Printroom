# Printroom 0.3.0 验收记录

日期：2026-09-08。交付版本 0.3.0 / build 1；源码由本验收记录所在的本地提交确定（实现起点 `cc1b497`）。密度算法 `printroom-density-v2` / 685 CV，裁剪 `geometryVersion=1`，项目 schema 3。Apple M4、arm64、macOS 26.6.2 (25G83)、Swift 6.3.3；本地 ad-hoc 签名，无远端或发布。

## 已交付

- 帧级裁剪：3:2、4:3、1:1、7:6 及横竖切换，±10°滑杆、0.1°按钮、0.01°输入；自动收边、网格、四角四边与框内拖动。R 进入，Enter 完成、Esc 取消，重置全图，整次提交一次撤销。
- 多选同步：草稿直接提交到所选，或完成后从“同步”菜单应用当前裁剪。按相对位置/大小适配不同尺寸，保留目标方向与调色；全目标预校验，覆盖不累加，整组撤销，支持同步全图状态。
- 主预览、Filmstrip、直方图、1:1 与 TIFF 输出使用已提交裁剪；片基取样临时恢复完整原图。裁剪、阶段、方向和切帧均有异步过期防护。
- schema 1/2 明确迁移无裁剪，首次覆盖前保留原 JSON 备份；设置副本恢复包含裁剪；损坏/未来几何不无声回退。零角保留整数原样本，精细角度在原线性输入上一次插值，算法公式和 ICC 规则以 pipeline.md 为准。

## 执行结果

| 命令/证据 | 实际结果 |
| --- | --- |
| `scripts/test.sh`（本机环境） | 中间集成版常规回归通过；核心 112 项中 2 个实际资产专项默认跳过，应用性能量测与实际资产项按开关跳过；包括新增几何、导出、Canvas、多选事务与采样。日志 `scratch/crop-tests-local.log`。 |
| `scripts/test.sh --full -c release` | 最终核心 **115 项全部通过，无跳过**，含十张参考 TIFF 的独立 Python/zlib 样本对照、原尺寸输出、全部 D4 与新裁剪导出。日志 `scratch/crop-tests-release-full.log`。同轮应用的两个读数测试因新增“原片”文字前缀而失败；坐标前缀恢复后按下一行重跑全部应用测试。 |
| `scripts/test.sh -c release --filter PrintroomAppTests` | 最终应用 **53 项执行通过**，6.814 秒，含 7 项裁剪集成与 6 项 Canvas；另外 3 项性能量测及 1 项实际资产专项按开关跳过。该实际资产专项已在上一行 full 运行通过，因此本轮共覆盖 54 项应用功能测试。设置副本恢复/Undo/Redo、新旧几何与读数标签通过。日志 `scratch/crop-tests-release-app-final.log`。 |
| `bash scripts/crop-window-qa.sh --release` | 真实 EditorView 窗口的 queued R/Enter/Esc、拖动、实际同步按钮、整组撤销、当前帧提交、文本焦点排除与片基全图通过。1060×720 与 1200×820 截图检查通过。最终日志 `scratch/crop-window-qa-final.log`，截图 `scratch/crop-qa/01-before.png` 至 `08-final.png`。 |
| `scripts/build-app.sh` | 生成独立 `output/Printroom-0.3.0.app`，Metal Apple M4 冒烟、内嵌 LUT/四 ICC 与 UInt16 SDR 展示格式通过。日志 `scratch/crop-build-app.log`。 |
| `codesign --verify --deep --strict --verbose=2 output/Printroom-0.3.0.app` | valid on disk / satisfies its Designated Requirement。 |
| `shasum -a 256 -c assets/SHA256SUMS` | 12/12 原始资产全部匹配，包含十张 TIFF；日志 `scratch/crop-assets-sha.log`。 |

最初沙箱内的系统服务无法创建 Metal 上下文或使用 NSFileCoordinator，相关测试未能执行断言；上述正式结果均在同一本机图形/文件协调环境运行取得。没有把沙箱失败当成功，也没有扩大数值容差处理错误。

## 裁剪数值与实际导出

`CropTests` 包含独立解析旋转/线性渐变、四比例和横竖的整数样本、全 D4 跟随、±10°四角有效边界、点映射往返、ROI 邻点与整图一致、精确 8M ROI 无多读，以及迁移/损坏拒绝。CPU/Metal 密度路径继续运行原有一致性测试；几何由共同的原线性输入采样器提供。

合成 TIFF 对 **0°、6.73° × 四种 ICC × 两种压缩** 共 16 种导出组合进行独立解析样本回读，校验嵌入 ICC、方向、输出尺寸、量化与快照固定。

实际 `TEST/DSC07079.tiff`（7008×4672）只读，按 7:6、3.17°、相对宽度 0.75 输出 **5124×4392 sRGB Deflate 16-bit TIFF**，正式 ExportEngine 耗时 **5.287 秒**，文件 **129,015,490 bytes**。8 个独立检查点覆盖四角、中部及 31/32 行边界，按 Float64 源坐标与 UInt16 邻点权重计算再走 CPU 调色，与导出回读最大差异 **0 个 UInt16 阶**。这是稀疏解析检查，不宣称全图逐像素等价；源 SHA256 前后相同。测试文件在临时目录，结束后清除。

## 视觉检查与边界

已查看真实窗口的裁剪遮罩、网格、细旋转、最小窗口两排工具、同步结果和 Filmstrip；裁剪框与最终内容对应，控件可见无溢出。测试输入为 scratch 下未改写的参考 TIFF 副本，保留默认未校准外观；这次视觉检查验证几何和布局，不等同于色彩审美验收。

未完成/不宣称：用户日常拖动与角度微调手感验收、其他显示器/旧 macOS/Intel 实机、严苛缩放下的更高质量重采样对比、持续内存性能新基准。裁剪编辑构图图为完整低分辨率展示旋转，提交后按线性采样契约重新生成；裁后普通预览仍基于有界全图低分辨率输入，细节用按需 1:1。任意角度插值不是逐像素无损，原始文件始终完整；1:1 的输出区域及必要源包围区域继续受 8,388,608 像素预算限制。画线拉直、自动识别边框不在用户确认范围。
