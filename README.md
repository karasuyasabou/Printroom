# Printroom

macOS 原生负片调色工具。一个文件夹是一卷底片：读取 16-bit 线性 RGB TIFF，进行卷级片基校准和逐张调色，使用 Kodak 2383 D65 LUT 预览，导出带正确 ICC 的单张 16-bit TIFF。

**当前版本：0.1.0 整卷调色可用版。** 本轮交付算法、单张闭环与整卷操作；批量导出、多输出色彩空间、最终性能优化留到下一轮。

## 运行

打开构建产物 `output/Printroom-0.1.0.app`。这是本地 Apple Silicon 应用，附带 ICC/LUT，无需 Photoshop、Python 或额外运行库。代码与原始资源没有上传远端。

从源码构建：

```sh
scripts/build-app.sh Printroom-0.1.0
```

脚本使用 SwiftPM release 构建并组装 `.app`，复制原始 ICC/LUT、校验运行时资产身份，使用本地 ad-hoc 签名。省略参数时生成 `output/Printroom.app`。可在 Xcode 打开 `Package.swift` 阅读和开发；工程没有 `.xcodeproj`，不依赖在线 Swift 包。

实测环境：Apple M4，macOS 26.6.2，Xcode 26.6，Swift 6.3.3。部署目标 macOS 14+、arm64；macOS 14 实机兼容性和 Intel 未验证。

## 简短验收

1. 打开一张原始线性 TIFF 或胶卷文件夹，底部应出现同目录照片。
2. 点“框选片基”，在未曝光底片边缘拖一个矩形；确认整卷显示“已校准 · 95 CV”。可切换 Identity / LED Light Source。
3. 调整当前照片 Timing 与 RGB Contrast。点“复制参数”，在 Filmstrip 用 ⌘点击多选或 Shift 点击连选，再点“应用到 N 张”。⌘Z 一次恢复该组选片原来的参数。
4. 切换照片、关闭并重开胶卷，确认片基和每张调色恢复。复制快照与撤销历史只保留在当前会话。
5. 点“导出当前照片”，得到完整尺寸、3×16-bit、嵌入 P3 D65 Gamma 2.6 ICC 的 TIFF。导出始终走 Final，不受当前诊断阶段选择影响。

预览：拖动平移，触控板捏合或 ⌘/Option+滚动缩放，双击或“适应窗口”复位；单击读取原始像素对应的阶段值。片基采样使用原始分辨率，不使用缩略图。

Timing 字母快捷键在预览/面板编辑焦点生效，不截获文本输入或 ⌘ 组合。按用户最新定义，**W、S 都是 Master +1 CV**。Filmstrip 获得焦点后 ⌘A 全选。复制/应用也可用 ⇧⌘C / ⇧⌘V。

## 保存与恢复

设置自动保存在卷目录的 `.printroom.json`，缩略图位于 `.printroom-cache/`。原始 TIFF 不改写。只选中多张并拖动滑块仍只编辑当前预览帧，批量覆盖必须点击“应用”。

保存失败时保留内存中的调色及撤销能力。错误框提供“另存设置副本”和明确放弃未保存修改后重新载入的入口；File 菜单可恢复本卷的 JSON 设置副本。外部修改冲突不会自动覆盖。缺失帧保留参数，原文件名重新出现后可重开胶卷恢复；手动重连到不同文件名的界面尚未提供。

## 已实现与边界

- Float32 CPU 参考与 Metal 预览/导出、原始 LED 矩阵、1024 密度归一化、95 CV 校准、470 CV pivot。
- 保留输入通道数值；参考 TIFF 内嵌 ProPhoto RGB Linear，按项目约定解释为 P3-D65 Linear，界面明确显示差异。
- 全阶段预览、RGB/CV 读数、片基零值/饱和比例、卷级校准、逐帧 Timing/Contrast、参数快照和整组撤销。
- 全尺寸单张 TIFF 输出使用**无压缩**格式，约 196 MB/张（7008×4672），ICC 字节与原始 profile 完全一致；同名生成后缀，原文件不能覆盖。
- 输入支持 classic TIFF 的 RGB UInt16 条带、无压缩/Deflate、大小端、水平预测和八种 orientation；暂不支持 BigTIFF、tile、多页、alpha 或其他位深/通道格式。
- 预览长边 1600 像素，片基与导出为原始分辨率；首版没有全分辨率 1:1 锐度检查或帧率承诺。
- 不宣称与未提供的第三方软件逐像素一致，LUT 的精确扫描标定仍保留文档中的验证边界。

## 验证与工程入口

```sh
scripts/test.sh          # 常规算法、GPU、模型、文件和交互集成
scripts/test.sh --full   # 额外读取十张参考 TIFF、完整尺寸导出和真实照片管线
shasum -a 256 -c assets/SHA256SUMS
```

Metal 验收需要本机 GPU 权限，受限沙盒可能无法创建上下文；测试不会把 GPU 不可用当作通过。实际图片验证需要本地 `TEST/`，缺失时明确不能完成完整验收。所有临时项目/输出位于 `scratch/` 或系统临时目录；原始资产只读。

| 文件 | 内容 |
| --- | --- |
| [AGENTS.md](AGENTS.md) | 代理规则与当前授权 |
| [产品规范](docs/product.md) | 定位和范围 |
| [算法管线](docs/pipeline.md) | 单位、矩阵、校准与色彩管理 |
| [架构](docs/architecture.md) | 模块、项目存储和错误处理 |
| [交互](docs/interaction.md) | 选择、复制/应用、撤销和快捷键 |
| [验收计划](docs/validation.md) | 验收项目和证据边界 |
| [本版验收记录](docs/acceptance-0.1.0.md) | 实际执行结果与简短检查步骤 |
| [阶段计划](docs/roadmap.md) | 已交付和下一轮范围 |
| [决策记录](docs/decisions.md) | 用户确认、默认与待验证项 |
| [资产清单](assets/manifest.json) | 原始文件大小、哈希和元信息 |

目录：`Sources/PrintroomCore` 是 CPU/Metal、TIFF 和项目模型，`Sources/PrintroomApp` 是 SwiftUI 编辑器，`Tests/` 是数值与集成验收，`scripts/` 是构建/测试入口。本地 Git 忽略原始参考 TIFF、构建、应用包、缓存与导出；只跟踪源码、规范和原始 ICC/LUT。
