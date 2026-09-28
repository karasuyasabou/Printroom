# Printroom

macOS 原生负片调色工具。一个文件夹是一卷底片；支持 16-bit TIFF / Sony ARW、卷级双矩阵与片基校准、逐帧 Timing / Contrast、裁剪和 Cineon Log LUT，以及 TIFF / JPG 导出。

当前版本 **0.3.69（构建 1）**：清理历史入口与重复职责，保持既有图像算法、项目格式和界面流程。验证范围见 [本版验收](docs/acceptance-0.3.69.md)；历史版本与用户确认见 [roadmap](docs/roadmap.md)。

## 运行与构建

固定交付 [output/Printroom.app](output/Printroom.app)。使用 `scripts/build-app.sh` 构建，资源与签名验证成功后替换上次应用；名称与 bundle identifier 保持固定。

```sh
scripts/build-app.sh              # release 构建、资源打包、ad-hoc 签名
scripts/test.sh --no-parallel     # 算法、模型、TIFF、输出、异步 UI 集成
scripts/test.sh --full --no-parallel # 十张实际 TIFF / 全尺寸导出 / Metal
scripts/measure-performance.sh    # release 预览性能与内存记录
scripts/measure-adjustments.sh    # release 调参准备耗时、连续出图与最终收敛
scripts/measure-performance.sh --export # 两帧全尺寸批导性能
scripts/measure-export-concurrency.sh ROLL NEW_OUTPUT CONCURRENCY FIRST_FRAME COUNT # 真实卷1/4路对比
scripts/viewport-window-qa.sh --release # 真实窗口的视口回归
bash scripts/crop-window-qa.sh --release # 裁剪窗口/快捷键/多选同步截图回归
bash scripts/editor-window-qa.sh --release --window-chrome # 原生窗口顶部、主题及全屏/最小化往返
bash scripts/editor-window-qa.sh --release # 最小窗口、D3刻度、吸管与编辑器布局截图
bash scripts/editor-window-qa.sh --release --skip-build --keyboard # 自有窗口键鼠回归
bash scripts/editor-window-qa.sh --release --timing # 两种Timing最小窗口与固定布局
bash scripts/editor-window-qa.sh --release --scrollbars # 浮动滚动条与Filmstrip高度
bash scripts/matrix-window-qa.sh # 双矩阵、分类管理浮层与弹窗截图
shasum -a 256 -c assets/SHA256SUMS
```

默认回归串行执行，避免多个 AppKit/Metal 集成套件争用主线程造成预览超时。`--full` 需要本机原始 `TEST/TIFF/` 十张参考照片；当前工作区未提供这些照片，相关实片验证未完成，不能以默认测试通过替代。

SwiftPM 项目，可在 Xcode 打开 `Package.swift`。部署目标 macOS 14+、arm64；当前实测 Apple M4 / macOS 26.6.2 / Xcode 26.6 / Swift 6.3.3。旧系统、Intel、更多显示器仍未实机验收。窗口截图需要本机图形会话与系统截图权限。

## RAW 依赖

ARW 依赖本机 `/Applications/Adobe DNG Converter.app`。Adobe 去马赛克后由静态构建的 LibRaw 读取线性 DNG，日常编辑使用代理，导出重新处理全尺寸；缺失或失败明确报错。TIFF 不依赖 Adobe，不按嵌入 ICC 转换原始样本。

应用不需要 Python、Go、rawpy 或其他照片应用。LibRaw 的 CDDL 源码和许可证随包保留。RAW 验证命令与输入约束见 [验证规范](docs/validation.md)及 [RAW 验收](docs/acceptance-0.3.6.md)。

## 简短验收

1. 从主页打开包含 TIFF / ARW 的底片文件夹。框选未曝光片基，完成整卷片基校准；调节 Color Timing / Contrast，切换 Identity / LED 矩阵。
2. ⌘C 复制当前参数，⌘/Shift 多选并用 ⌘V 应用；⌘Z 一次恢复整组。**W 为 Master +1 CV，S 为 −1 CV**。Timing 单击 1、Shift 单击 10，长按 0.4 秒后固定 25 CV/秒，一次长按一次撤销；范围 ±512。复制包含 Timing、Contrast 和 Cineon Log LUT。
3. 点击预览工具栏的四个方向图标旋转/翻转，再撤销/重做；重开胶卷检查恢复。水平/垂直翻转以当前画面为准，重置只清除用户追加方向。
4. 点击顶部“自动裁剪”打开设置，选择画幅比例（默认3:2，也可自定义或交换宽高）；默认不保留已有裁剪、每边内收1%；可勾选保留，内收可选0～5%。分析进度留在对话框中；完成后若有待检查照片，会自动进入仅看待检查的裁剪模式。待检查数量、筛选和“确认并下一张”显示在裁剪栏，清零后隐藏。无需先框片基，结果支持整组撤销。按 R 或点击“裁剪”，在单行裁剪栏选择自由/固定比例、横竖和角度，拖边角调整或在框内移动。Enter/完成提交当前帧，Esc 取消，重置草稿可恢复全图。裁剪过程中用 ⌘/Shift 扩选目标，当前照片、范围锚点和草稿保持；普通点击或左右方向键切换照片后保持裁剪模式，保存上一张裁剪并载入新照片自己的裁剪。完成裁剪后从 Filmstrip 上方“同步…”勾选裁剪，向其余所选照片应用同一原片范围，保留各帧旋转/翻转；一次撤销恢复每帧原状态。菜单“复制调色 / 粘贴调色”及 ⌘C/⌘V 保留调色快照。
5. 预览右上角直方图独立切换 Density / Final，默认 Final，始终叠加 RGB。右上角箭头收起，再点“直方图”展开；无统计详情弹窗。统计完整裁后降采样预览，Density 为 D3 密度，Final 为显示器转换前 P3 编码值。
6. 点“100%”检查原始分辨率，拖动平移。片基框选显示十字，会临时恢复完整原片，结束后返回裁后画面；适应窗口/双击复位。按 I 或点击 Color Timing 右上角吸管进入取样，预览指针变吸管；I/Esc 取消。取原片邻域，使 LUT 后 Final 代表色接近中性并尽量保持最终亮度，一次撤销恢复。无论查看哪个阶段，吸管都以 Final 为目标。过亮、剪切、参数范围或整数精度导致无法达标时直接结束取样，不弹窗，原参数保留。顶部重置只恢复当前帧调色。
7. 导出菜单选择当前、所选或整卷，再在导出对话框中选择16-bit TIFF或8-bit JPG、sRGB IEC61966-2.1、Display P3、Adobe RGB (1998)、ProPhoto RGB 或 Rec. 2020，以及 ZIP 压缩复选框（初始勾选，仅 TIFF），填写文件名前缀；应用裁剪初始勾选，关闭则导出完整画面并忽略裁剪微调角度，保留独立旋转/翻转；后缀自动使用胶卷原编号。确认才保存选择；取消对话框不改变输出偏好。导出期间继续调色，不改变已固定的任务。取消任务保留已完成文件，结果逐张列出失败。
8. 缺失照片在 Filmstrip 右键“重新定位”，选择卷内改名后的 TIFF，保留 ID、调色和方向。File → 管理缓存可查看总用量、设置 GB 上限及 3/7/30 天或永不删除。

## 保存与资源

设置旁存在卷内 `.printroom.json`，当前 schema8 / geometry2；结构、旧项目迁移、首次覆盖备份和外部修改保护以 [架构规范](docs/architecture.md) 为准。保存失败保留内存编辑，可另存或恢复设置副本。

原始 `TEST/`、`ICC/`、`LUT/` 是不可变输入。运行 LUT 使用 `assets/DerivedLUTs/diffuse-white-v1`；原始 LUT 保留在仓库，不重复打入应用包。输入、密度、矩阵、取样、ICC 与输出公式只维护在 [pipeline.md](docs/pipeline.md)。

测试项目、缓存、导出及截图写入 `scratch/`、`output/` 或临时目录，不在原始资产目录写入。窗口 QA 共用 `scripts/build-window-qa.sh`；一次性白点项目补偿源码归档于 [scripts/archive/white-compensation](scripts/archive/white-compensation/README.md)，不属于当前运行入口。

## 规范

- [交互](docs/interaction.md)、[架构与迁移](docs/architecture.md)、[算法与色彩](docs/pipeline.md)。
- [验证](docs/validation.md)、[决策](docs/decisions.md)、[阶段及历史验收](docs/roadmap.md)。
- [原始资产清单](assets/manifest.json)与 [资产说明](assets/README.md)。

历史验收记录保留当时的证据与未测边界。0.3.68 的用户手动确认不追溯改写旧版工程测试，也不替代本轮回归。
