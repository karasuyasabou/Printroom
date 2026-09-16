# 0.3.5 双矩阵验收

日期：2026-09-09。交付 `output/Printroom.app`，版本 0.3.5 / 构建 1，固定标识 `studio.printroom.local.v3.3`。本记录只覆盖矩阵版 TIFF 流程；共享工作区正在并行接入的 RAW 不纳入本次交付与验收。

## 实现范围

- 01 矩阵矫正：左 CMOS、右密度，标题右侧管理浮层，再进入对应管理弹窗。
- CMOS 三张 TIFF 中心 ROI 识别/求解；密度手动九项及粘贴。内置只读，自定义命名、编辑或重新制作、复制、删除。
- 电脑本地矩阵库、文件冲突与损坏保护、每卷完整快照；库编辑/删除不改变既有胶卷。
- L0→CMOS→L1→Gain→L2；CPU/Metal、八阶段、直方图、缓存、取样及导出接入。
- 切换/编辑矩阵不重做片基；显式框选才产生新的 base/gain/offset 与采样矩阵快照。撤销及重开均保留该语义。
- 独立 CMOS 校正线性 TIFF 输出；schema 4 / 算法 v3，旧 v2 补 Identity CMOS 保持画面，首次覆盖备份原 JSON。

公式、阈值及输出规则仅引用 [pipeline.md §16](pipeline.md#16-035-cmos-标定与双矩阵)，管理语义见 interaction.md，存储见 architecture.md。

## 验证环境与隔离

本机 Apple M4 / arm64。并行 RAW 任务正在修改 Package.swift 和项目字段，为避免半完成源码混入交付，本轮在 `scratch/matrix-validation` 使用矩阵 TIFF 快照验证和打包：Package.swift 为原 TIFF 工程配置，RollProject 为加入本次矩阵字段的 schema 4，其余功能源为本轮实现。快照源码 SHA-256 保存于 `scratch/matrix-validation/verified-source-sha256.json`。

该目录的 `TEST` 只读链接到当前原片目录 `TEST/TIFF`，ICC/LUT 只读引用原目录；冻结原资产清单供旧测试路径使用。没有修改、重编码或移动原片。本次应用包仍由 `scripts/build-app.sh` 生成；隔离目录 `output` 链接到唯一交付目录，因此实际替换 `output/Printroom.app`。

## 实际执行

以下命令的工作目录为 `scratch/matrix-validation`：

```sh
scripts/test.sh --filter 'MatrixTests|MatrixEditingTests'
scripts/test.sh --full -c release
bash scripts/matrix-window-qa.sh --skip-build
shasum -a 256 -c assets/SHA256SUMS
scripts/build-app.sh
```

- 新增针对性验证：9 项核心矩阵测试、3 项应用矩阵测试通过。
- 最终完整 release：**146 项 XCTest 核心测试通过；80 项应用测试通过**。Swift Testing 总计列出 83 项，其中 3 项 opt-in 性能量测跳过。最终日志 `full-tests-final.log`，退出码 0。
- 覆盖十张真实 TIFF 独立 Python/zlib 全样本解码、7008×4672 TIFF 输出、实际整图 Final 导出及裁剪导出回读。实际裁剪为 5124×4392、3.17°、sRGB Deflate，8 个独立解析位置最大误差 0 UInt16；实际整图导出回读 CPU 比较最大误差 `7.748604e-06`，ICC 字节一致。
- 既有两内置矩阵的 Metal 对照为 4099 像素 × 2 矩阵 × 3 组调色 × 8 阶段。L0/L1/L2 最大误差 0；D3 最大 `3.8146973e-06`；Final 最大 `1.2516975e-06`。新增自定义 CMOS 与密度矩阵的八阶段 CPU/Metal 对照、负值/上界、非有限中间值及 D1 缓存失效也通过原误差预算。
- 新增 CMOS TIFF 测试实际写入并读取三张合成光源 TIFF，验证中心区域取样、角色识别、原文件字节不变；求解另以解耦列向量、中性不变和曝光比例不变校验。独立 L1 导出回读精确匹配预期 UInt16，排除 Gain、密度、调色与用户方向。
- 146 项核心、80 项应用通过包含矩阵冻结校准、显式重新采样、撤销/重做、保存/重开、本机库重读/编辑/删除、卷内快照、旧 schema 迁移与原 JSON 备份、非法值/损坏/冲突拒绝。
- 原始资产 **12/12 哈希通过**，日志 `asset-check.log`。
- 窗口 QA：1060×720 主编辑器、分类管理浮层、密度管理和 CMOS 管理弹窗已实际截图并检查；只读系数保持可读并允许复制文本。截图在 `scratch/matrix-ui-qa/`，包含 `01-matrices-minimum.png`、`03-management-popover.png`、`05-density-sheet.png`、`07-cmos-sheet.png`。退出码 0，日志 `matrix-window.log`。
- release 打包、包内 ICC/LUT 与四输出 profile、Metal Apple M4 渲染、UInt16 预览格式及 ad-hoc 签名验证通过后替换旧包。日志 `build-app.log`，退出码 0；交付 plist 已回读为 0.3.5 和固定应用标识。
- 工作区 `git diff --check` 通过。保留其他任务和用户原有修改，没有创建远端或推送。

## 过程中修正与边界

初期共享构建夹入尚未完整的 RAW target，因此改用隔离快照。回归发现历史 MetalTests 硬编码七阶段、旧校准测试仍把“当前密度矩阵改变”判为损坏；已改为按实际阶段计数，并校验上次采样矩阵快照。迁移夹具去除旧 schema 未定义字段，补对应预期采样快照。并行资产路径变更曾使隔离 Python 对照找不到原片，冻结隔离资产清单后最终完整回归通过。失败的中间运行不计入通过结论。

未进行用户实际三张光源标定照片的色彩外观验收；现有真实 TIFF 为日常负片参考，不能替代专门光源标定。新的系统文件选择对话框与管理弹窗未完成端到端人工键鼠操作，已执行源代码窗口截图、模型及数值测试。RAW 制作入口、旧 macOS/Intel/更多显示器、三项性能量测不在本轮完成范围。
