# 验收计划与当前证据

状态：本轮 0.3.3 验证契约见 K 节，实际执行状态记录于 [acceptance-0.3.3.md](acceptance-0.3.3.md)。0.1.0 至 0.3.0 的历史证据保留在各版本验收记录。**下列清单是验收契约，不代表测试、失败注入或硬件验证已经完成；未执行的新版条目继续待验证。** 无需 Photoshop 参考。

## A. 已完成的资产基线检查

- 登记 1 个 ICC、1 个 33³ LUT、10 张 TIFF，共 12 个原始文件的大小和 SHA-256。
- TIFF 第一 IFD：均为 7008×4672、3×16-bit、RGB、chunky、Deflate（compression=8）；sample format 与 orientation 缺省时按 TIFF 规范为 unsigned integer / top-left。
- 10 张 TIFF 均嵌入相同 `ProPhoto RGB Linear` ICC，三个 TRC 均 Gamma 1.0。元数据不等于扫描仪物理线性标定已经验证。
- 独立 ICC 描述为 P3 D65 Gamma 2.6，三个 parametric TRC 的 Gamma 约 2.6000061。
- LUT 数据行数 35937=33³，域 [0,1]，文件中输出最小 0、最大 0.999996；未进行完整视觉验收。
- 清单见 [manifest.json](../assets/manifest.json)，可在仓库根目录执行 `shasum -a 256 -c assets/SHA256SUMS` 复核原始资产。

2026-09-07 工程检查结果：12/12 个资产 `shasum -a 256 -c` 通过；所有文档本地链接存在、代码围栏成对；manifest 文件大小与数量一致；35937 行与 33³ 一致；没有 Swift/Metal/Xcode 应用文件；Git 忽略规则正确排除 `TEST/`、`.DS_Store`、临时项目与导出目录。本次检查基于 README 所列本地工具链，记录将随初始 Git 提交保存。

以上是 M0 资产检查的历史范围；M1/M2 应用验证已另行执行，不把资产元信息检查替代为应用测试。

## B. 数值验收（M1）

按 `printroom-density-v1` 公式，以独立双精度计算生成期望值，生产参考用 Float32。基准输入使用合成样本，小数据可纳入未来测试，不能只测试复制粘贴的实现本身。

| 编号 | 验收内容 | 必须证明 |
| --- | --- | --- |
| N01 | UInt16 导入 | 0、1、32768、65535 等样本精确保留后除以 65535；嵌入 profile 不改样本 |
| N02 | 中位数 | 奇/偶数量、通道独立、灰尘离群值、图像 orientation、选区边界；不取缩略图值 |
| N03 | Linear Gain | base=(0.2,0.4,0.6) 时 gain=(3.75,1.875,1.25)，baseL1 各通道为 0.75 |
| N04 | 密度 | T=1 时 N=0；T=0.1 时 N=0.48828125；T>1 时允许负值；零值走 epsilon |
| N05 | CV 换算 | +1 CV 恰对应 +1/1024 归一化密度与 +0.002 实际密度；浮点偏移不取整 |
| N06 | 矩阵 | Identity 不变；LED 对三个基向量返回原矩阵三列，排除转置；一般彩色向量与独立计算一致 |
| N07 | 片基校准 | 两矩阵下 offset 都将片基映射至目标；切矩阵重算 offset、保留用户 Timing |
| N08 | Timing | Master 与通道相加，正负步进正确；合成偏移不被控件范围二次裁切 |
| N09 | Contrast | 1 时不变；pivot 处任何有效反差均不变；Master×通道；685 不作为 pivot |
| N10 | 边界与非法值 | 域外密度仅在 LUT 入口裁切；NaN/Inf 明确报错；异常片基不破坏旧校准 |
| N11 | LUT | 合成 identity/轴向着色 LUT 验证索引方向、8 角点插值、端点与边界；再测真实 LUT |

独立计算的片基解析参考（T=0.75）：

```text
physicalDensity = 0.12493873660829995
normalizedDensity = 0.06100524248452146
CV = 62.469368304149974
Identity offsetCV = (32.530631695850026, 同左, 同左)
LED offsetCV = (30.013116153192783, 31.406183066375327, 38.483962495235524)
```

基础 CPU 阶段绝对误差目标 ≤1e-6（归一化单位）；校准目标误差 ≤0.01 CV。大值边界测试同时报告绝对/相对误差，不能因特殊样本失败直接扩大普通样本容差。

## C. CPU/Metal 一致性（M1，M3 优化后复验）

使用固定种子合成数据、LUT 格点/边缘/中点、参数范围极值，以及实际 TIFF 像素块。分别比较 L1、D0、D1、D2、D3 与 Final；记录设备、工具链、样本规模、最大和 RMS 误差。

工程验收目标：L1–D3 使用 `absError <= 2e-5 + 2e-5*abs(reference)`；Final [0,1] 最大通道绝对误差 ≤2e-4、RMS ≤2e-5。CPU/GPU 不能共同产生 NaN 并被当作一致。绝对最大值与失败样本必须保留，不能只报告平均值。

若目标未达到，先定位坐标、精度、乘法顺序和编译选项，不自动放宽容差。后续 Float16/硬件采样优化重新跑该验收。低分辨率预览只与同一输入像素/分辨率的 CPU 路径比较，不能把重采样差异算作算法误差。

## D. 实际 TIFF、显示与输出（M1/M3）

| 编号 | 验收内容 |
| --- | --- |
| F01 | 10 张参考 TIFF 均能按原位深解码；样本与独立解码路径逐点一致；原始 SHA-256 不变 |
| F02 | 片基矩形在缩放/平移后仍对应原始像素；实际采样区域在测试记录中保存 |
| F03 | 全阶段切换有明确单位；读数来自未裁切内部值，Final 与诊断画面互不污染 |
| F04 | P3 默认导出回读为 3×16-bit TIFF，ICC 字节哈希与原 ICC 一致；未转换通道误差 ≤0.5/65535（舍入容差另加机器误差） |
| F05 | 中性色阶、RGB 轴和饱和色块检查显示管线；明确源 profile 与显示器 profile，证明没有遗漏或重复 transfer 处理 |
| F06 | 导出覆盖源路径、重名、磁盘满、权限失败和取消时，不损坏原文件或留下看似成功的半文件 |
| F07 | M3：Adobe RGB/sRGB/ProPhoto 实际转换与独立矩阵/TRC解析值比较，正常域加系统CMM参考，记录意图、黑点补偿与 profile；ProPhoto 检查 D50 色适应 |
| F08 | 真实样片检查高光/阴影、裁切比例、明显偏色、渐变连续性；记录主观观察，不把无 PS 参考等同于无需视觉检查 |

完整管线 Cineon 衔接及 LUT 输出语义未独立证明。M1 需记录渐变、参考 CV 点及实际照片表现；如发现系统性异常，沿单位/ICC/LUT 解释排查，不擅自调整矩阵。使用原有合同完成工程结果可以验收，但不得宣称与未提供的第三方软件像素一致。

## E. 项目、复制/应用与交互（M2）

- 打开指定帧后选择正确；自然排序、扩展名大小写、缺失/新增帧和整卷移动行为明确。
- 保存/重开恢复卷级 base/gain/offset/matrix、每帧 Timing/Contrast、输出偏好；保持 frameID，不串帧。
- 损坏/未来版本 JSON、只读目录、外部写入冲突均不无声覆盖。
- 复制 A 后再修改 A，应用到 B/C 得到复制时快照；A 不在目标时不变，卷级参数不变。
- 单选/⌘/Shift/⌘Shift/全选与 active/anchor 不变量符合交互规范；空集合禁用应用。
- 连续应用不会累加，完全相同结果不增加 Undo；含不同参数的多张照片一次 Undo 各自恢复，一次 Redo 各自重用快照。
- 多选时手动控件只改 active；应用捕获点击时目标；执行失败整组不改。
- 来源帧丢失后快照仍有效；切卷清空快照；不兼容快照明确拒绝。
- ⌘Z/⌘A 与文本编辑不被 Timing 字母快捷键截获。
- 自动保存失败保留 dirty 状态；快速切图不显示旧帧结果；校准修改使整卷缓存失效。

## F. 性能与执行记录

当前不承诺帧率。M1 在实测设备记录预览分辨率、首次打开时间、调参延迟、全尺寸导出时间和峰值内存；M3 按基线优化。至少验证连续切换这 10 张图不会无限增长内存，导出有进度并可取消。

每次验证记录：日期、Git 提交、算法/项目版本、设备/系统/工具链、输入哈希、参数、命令、期望与实际结果、失败和跳过项。测试输出写入 `scratch/` 或临时目录；必要的简明结论保留在阶段交付文档，不能把个人原图提交进 Git。

## G. 0.2.0 扩展验收

- schema 1 → 2 的显式默认迁移与损坏/未来版本拒绝；方向/输出重开、Undo/Redo、复制排除方向。
- 八种用户方向、全部组合和像素/ROI正逆映射；与原始TIFF八orientation分离；导出宽高和实际样本/orientation=1。
- 合成直方图256 bins、精确端点、域外/NaN/Inf、阶段单位；快速切图/调参只显示最新请求，1:1局部不改变整图统计。
- 四输出ICC的真实转换、D50色适应、嵌入字节、16bit TIFF无压缩/Deflate独立回读；单张/批量像素一致。
- 快照编辑不变、取消前/中/后、成功保留/临时清理、重复命名、发布竞争、源覆盖拒绝、缺失/无权限项不阻断队列。
- 条带preview/ROI与完整原图参考一致，缓存替换失效、LRU内存限制、磁盘TTL/限额/清理安全、缺失改名手动重连。
- 全套CPU/Metal和十张参考TIFF回归、原始资产哈希、release性能测量、真实EditorView窗口与控件操作。

实际结果、命令、测量规模和未测项只记录于 [acceptance-0.2.0.md](acceptance-0.2.0.md)，不由清单推定通过。


## H. 0.3.0 裁剪验收

- 无裁剪保持八种 D4 原样本；零角四比例横竖均为精确整数样本；非零角以独立仿射线性场解析验证插值位置和调色前后顺序。
- ±10°、角落中心、四比例与全部方向的裁框四角在原图内；正逆映射、D4 后续旋转/翻转/重置跟随原内容。
- 1:1 源包围区域覆盖必要邻点并保持输出原分辨率，整图与 ROI 一致；8M 区域预算不被无用邻点扩大。
- 草稿取消/重置、单帧提交、一次 Undo/Redo、schema 3 重开与 JSON 设置副本恢复裁剪；schema 1/2 无裁剪迁移、备份、冲突保护及损坏字段拒绝。
- 多选规范化同步适配不同尺寸，保留各帧方向与调色；幂等、整组撤销、最后一个目标丢失时整组不改，完整原图也可同步。
- 主预览/Filmstrip/直方图使用裁后范围；片基暂时全图、原始读数映射；裁剪/切图异步过期防护与几何复位。
- 0°与非零角四ICC×无压缩/Deflate独立解析回读，快照冻结；实际TIFF原尺寸角度裁剪导出回读与原始资产哈希。
- 真实 EditorView 的 R/Enter/Esc、边角/移动、多选同步按钮、1060×720窗口与文本焦点；截图只取测试窗口，输入用 scratch 副本。

执行结果记录于 [acceptance-0.3.0.md](acceptance-0.3.0.md)，未执行项目保持待验证。

## I. 0.3.1 原片裁剪与固定当前帧多选验收

以下为本轮验收清单，具体通过、受阻及未执行项只在版本验收记录中登记。

- 同尺寸非对称照片覆盖八种 D4，包含同步来源已旋转或反射的情况；同步后各帧 geometryVersion 2 裁剪值相同，完整输出像素等价于原片裁剪后分别执行 D4，方向与调色不变。
- 不同原始尺寸的目标按原片坐标拟合；目标方向不影响拟合，90° 输出宽高交换，角度及横竖的显示转换与存储值区分。角度零值、非零值、边缘范围与四比例沿用数值要求。
- 裁剪过程中 ⌘/Shift/⌘Shift 扩选或移除非当前目标，保持 active、anchor、原片尺寸、预览、视口和草稿；⌘ 当前帧不改变选择，active 始终在集合中。普通点击换帧取消草稿并设新 anchor，随后 Shift 范围从该 anchor 计算。
- 反射方向下显示角度反号，90°交换显示比例横竖与宽度基准；编辑显示值后保存为原片版本 2。重置全图后重新调比例或角度仍使用正确显示基准。
- schema 3 几何版本 1 项目按原始尺寸与旧方向转换，完整像素和输出尺寸保持；读取不改旁存文件，首次成功覆盖前 `.printroom-geometry-v1-UUID.json` 与原 JSON 字节一致，常规后续保存不重复备份。
- 缺失或不可读源保留几何版本 1，重现/重连后转换；混合几何项目、JSON 设置副本恢复、保存冲突、备份失败与未知几何版本拒绝均不得丢失原设置。
- 保持同步草稿/重置的整组原子性、幂等与 Undo/Redo；主预览、Filmstrip、直方图、原始 ROI/1:1、导出快照和缓存不混用两种几何或旧上下文。
- 真实 EditorView 验证单行裁剪栏、仅栏内同步、没有输出尺寸/常驻说明；边裁剪边扩选保持来源和草稿，R/Enter/Esc、数值焦点、最小窗口布局与八方向构图可用。
- 构建独立 0.3.1 应用并检查资源、签名；按变更选择 CPU/Metal、TIFF 输出回读与资产哈希回归，保留原应用与原始 TIFF/ICC/LUT。

本轮命令、输入、数值误差、截图、失败与未测项记录于 [acceptance-0.3.1.md](acceptance-0.3.1.md)。历史验收不自动计入本轮结果。


## J. 0.3.2 中性点、快捷键与展示验收

- D3 与独立 Double 解析值：不同有效反差、LED/校准、Master 保留、整数误差、颗粒/剪切、参数边界与超限失败；Final 缺失 LUT 拒绝。
- 原片邻域含裁剪/旋转映射，单次 Undo/Redo、保存重开与非当前帧不变；取样等待中调参/切帧/阶段/校准/取消及源变化不能发布过期结果。
- 普通点击不读数；吸管仅启用后生效，窗外释放不提交，片基/裁剪互斥。
- 非文本焦点与 Filmstrip 后 Timing/Option Contrast 可用；正负键、0.01 与 Shift 不放大、长按/停止/一组撤销；文本、修饰键、弹窗与失焦边界。
- 调参保持上一对画面/直方图并一起更新、最终收敛，跨上下文清除；大图网格边缘、样本计数与百分比分母、取消及小图精确路径；密度 CV 横轴/参考线位置，其余0…1，统计不改变。
- 缩略图占位、主预览缓存优先与正式替换；源/参数/几何/阶段不匹配不复用，项数/字节/LRU，占位禁用精确操作。
- 最小窗口顶部重置/复制/吸管、无旧状态栏；导出取消/保存失败重试可达，release构建、独立资源/签名与原始资产哈希。

实际执行见 [acceptance-0.3.2.md](acceptance-0.3.2.md)，未执行不视为通过。


## K. 0.3.3 Final 中性点验收

- 真实 2383 LUT 不同明暗、中性 D3 输入的色偏补偿；独立解析 ICC/Lab 验证 Final 中性、亮度与重复点击不漂移。
- 合成通道耦合 LUT 的解析逆解及整数邻域比较；LED/校准/非单位反差、Final 偶数中位数、颗粒/离群点。
- 原始样本剪切多数/少数、LUT 平坦区与可恢复剪切、Timing 越界、整数精度不足、非法输入/ICC和取消；失败保持原参数。
- 实际 TIFF 原始 11×11 ROI；新参数的 CPU/Metal 一致性及四 ICC×两压缩 TIFF 回读。
- 原片裁剪/方向映射、Final 数值、单次撤销/重做、保存重开、非当前帧不变；后台求解、等待取消、上下文/源变化过期防护和失败不增加撤销。
- 独立 0.3.3 release 构建、资源/签名、原始资产哈希；保留旧版，无发布。实际结果只记录于 acceptance-0.3.3.md。


## L. 0.3.5 双矩阵验收

本节取代历史 N07 中“切矩阵重算 offset”的要求，当前公式与阈值仅以 pipeline.md §16 为准。

- 合成三光源观测数据：角色识别、RGB 列顺序、解耦、等值中性、曝光比例、非法/奇异输入；合成三张 TIFF 的真实中心 ROI 读取与原文件不变。
- 独立解析 L0/L1/L2/D0/D1 顺序、负值与上界保留，CPU/Metal 八阶段误差预算、两种矩阵改变使 D1 缓存失效，非有限中间值不能被 LUT 隐藏。
- 框选后逐像素 CMOS 再中位数；换矩阵/编辑预设、Undo/Redo、保存/重开保持已有校准；只有显式框选更新。采样矩阵快照、派生量损坏和旧项目迁移保护。
- 本机库新增/编辑/删除、内置不可修改、外部写入冲突、损坏拒绝覆盖；卷内快照跨库编辑/删除保持独立。
- 0.3.17 起独立 L1 TIFF 导出已移除；验证普通 Final 导出的 ICC、裁剪/方向、快照、取消与源保护。
- 最小窗口左 CMOS/右密度，标题管理浮层与两类管理弹窗，CMOS 只读系数与密度输入可辨；弹窗文本焦点不触发调色键。

本轮实际执行及尚未执行项目见 acceptance-0.3.5.md。

## M. 0.3.6 RAW 验证入口

实际结果以acceptance-0.3.6.md为准。`scripts/test-raw-integration.sh`执行固定LibRaw/CFA拒绝/GCD线程、八张真实Adobe全RGB哈希、nearest代理与ROI、CPU/Metal、裁剪及整卷全尺寸/ICC；需要本机Adobe、TEST/RAW和保留的独立研究参考TIFF。`PRINTROOM_TEST_REAL_RAW=1 PRINTROOM_VALIDATE_RAW=1 scripts/test.sh --filter 'RAWEditorIntegrationTests|RAWImageServiceTests'`执行真实编辑器与精确服务。默认RAWSourceServiceTests与RAWGeometryTests执行可控故障/并发取消/源替换/缓存/后台提交测试，不冒充真实Adobe验证。原始RAW基线使用assets/RAW-SHA256SUMS。

## N. 0.3.7 静默与四路

RAWSourceServiceTests覆盖固定四槽、同源混合请求、跨实例、取消与维护屏障；RAWPrewarmerTests验证界面驱动确实四路与停止排队。构建release后可运行scripts/adobe-shadow-qa.sh及scripts/adobe-service-four-qa.sh；实际Adobe进程策略/并行峰值和八张像素验证见acceptance-0.3.7.md。原有TIFF数值与RAW图像策略不变。

## Sony CMOS / RAW 标定回归

运行 `PRINTROOM_CMOS_RAW_TEST=1 scripts/test.sh -c release --filter 'MatrixTests|MatrixEditingTests|RAWSourceServiceTests'`（需本机 Adobe 和 TEST/RAW），检查全尺寸中心均值、只读机型、快照兼容和片基冻结。未设置环境变量时真实 RAW 标定测试跳过。窗口使用 `bash scripts/matrix-window-qa.sh`。本轮结果见 acceptance-cmos-raw.md。

## 0.3.8 BigTIFF

` scripts/test.sh --full --filter 'TIFFCodecTests|OrientationHistogramTests|Export' ` 验证 BigTIFF 大小端、三种 compression 标签、水平预测、八方向、ICC 不转换、完整读取/预览/ROI、损坏文件头/数量拒绝；超过 4 GiB 的稀疏文件分别覆盖高地址目录/ICC/条带及大尺寸预览/ROI，同时回归十张参考 TIFF 与全尺寸输出。实际执行结果见 acceptance-0.3.8.md。


## 0.3.9 矩阵联动片基

取代 L 节的“切矩阵保持校准”验收要求。运行 `scripts/test.sh --filter 'MatrixEditingTests|MatrixTests|RollProjectTests'`，验证 CMOS 原始选区重采样、密度 Gain 保持/offset 更新、解析 95 CV、连续请求、失败和取消原子性、帧参数保持、一次撤销重做及保存重开。实际结果见 acceptance-0.3.9.md。

## 0.3.12 最近胶卷

使用 `scripts/test.sh --filter 'RecentRollsTests|EditingV2Tests'` 验证持久化、去重/上限、删除/撤销、项目保护和恢复active；`bash scripts/editor-window-qa.sh --release --appearance`检查六行和撤销的最小窗口布局。实际结果与未测项见 acceptance-0.3.12.md。


## 0.3.13 RAW 日常代理验证

运行 `scripts/test.sh` 检查缓存命中无需DNG、旧大文件淘汰、四路并发与取消、失败导出不污染代理；`PRINTROOM_VALIDATE_RAW=1 PRINTROOM_TEST_REAL_RAW=1 PRINTROOM_RAW_INTEGRATION=1 PRINTROOM_CMOS_RAW_TEST=1 scripts/test.sh` 追加实际Adobe、代理网格取样/方向/片基、八张全尺寸RGB哈希和真实导出回读。旧版本精确RAW ROI断言由pipeline.md的新契约取代；TIFF及导出原像素断言保留。实际结果见acceptance-0.3.13.md。


## 0.3.15 缩略图迁移

`scripts/test.sh -c release --filter 'ThumbnailMigrationTests|ImageServiceTests|AdjustmentSchedulingTests|EditingV2Tests'` 验证缓存像素/ICC、限额/过期、迁移/重复迁移、目标失败保留源、陌生文件/符号链接/临时文件保护、胶卷隔离和编辑器打开/清理后不再写卷内缓存。原始数据与JSON保护使用临时合成卷；真实外置盘和旧版同时写入尚未实机验收。实际结果见acceptance-0.3.15.md。


## 0.3.16 原位裁剪验证

运行 `scripts/test.sh --filter 'CropEditingTests|PreviewCanvasTests|SelectionCropTests|RAWGeometryTests|CropCanvasTests'`，检查切换期间图像与几何配对、提交/取消、快速切图、原片裁剪同步及最小窗口画布身份和边界。`bash scripts/crop-window-qa.sh --transition-only` 使用真实TIFF副本验证R/Enter/Esc、边角拖动、重进/取消及1060×720窗口截图。实际结果见acceptance-0.3.16.md。


## 0.3.20 LUT 与同步

`scripts/test.sh --filter 'CineonLUTTests|CropEditingTests|RAWGeometryTests'` 验证七种调色勾选组合、未勾选参数保留、撤销/重做、保存重开、复制重置、schema 5 原字节备份、未知选择拒绝、两份实际 LUT 的 CPU/Metal 预览一致性及混合批量导出回读。`bash scripts/editor-window-qa.sh` 检查最小窗口 LUT 面板和同步浮层。实际执行状态见 acceptance-0.3.20.md。

## 0.3.19 简易 Timing

`scripts/test.sh --filter 'SimpleTiming|TimingKeyboardTests|EditorKeyboardRoutingTests|PipelineTests|MetalTests|EditorIntegrationTests|EditingV2Tests'`检查映射、整数/范围边界、模式持久化与不漂移、按键与通用反差、原生滑杆回显、复制/保存/撤销和既有图像回归。`bash scripts/editor-window-qa.sh --timing`检查最小窗口三/四Timing滑杆和固定Contrast位置。执行状态和未执行范围见acceptance-0.3.19.md。


## 历史：0.3.22 LUT 参考白（已由 DirectLUTTests 取代）

`LUTWhiteBalanceTests` 验证两份真实 LUT 白点 RGB 相等、独立 ICC Y/TRC 亮度、重复准备、原格点保持、不同 RGB 反差固定点、CPU/Metal 色阶、校正后的吸管、Identity与不可达LUT、v3原字节备份。`CineonLUTTests`覆盖正式AppAssets加载、选择同步、预览与混合LUT导出回读。实际运行证据与未验收范围见acceptance-0.3.22.md。


## 0.3.25 直方图纵轴

`scripts/test.sh --filter 'HistogramDisplayScaleTests|OrientationHistogramTests'`验证巨大暗峰和多bin暗峰下主体可见、未截顶线性比例、样本数量倍增不改变高度、RGB共用尺度、空/纯色/稀疏分布与原统计契约。`bash scripts/editor-window-qa.sh --release --histogram`检查合成夜景分布在RGB/密度单通道下的真实窗口绘制。实际照片观感与执行证据见acceptance-0.3.25.md。


## 0.3.26 直方图切换

运行 `scripts/test.sh --filter 'HistogramDisplayScaleTests|OrientationHistogramTests|EditingV2Tests|EditorRefinementTests|AdjustmentSchedulingTests'` 验证独立阶段、快速切帧及调色快照。`bash scripts/editor-window-qa.sh --release --histogram` 检查两阶段与收起／展开布局。实际证据和未执行项见 acceptance-0.3.26.md。


## 0.3.27 D3直接LUT与定向补偿

`DirectLUTTests`验证两份原LUT的CPU/Metal直接D3采样、不同反差及边界、v4迁移不自动改参数及原字节备份。配合CineonLUTTests的正式资源/预览/混合导出回读、NeutralTimingTests、管线/裁剪/项目迁移回归。独立补偿脚本对每张既有RAW代理取长边320样本，对照原v4输出与v5补偿输出，记录D3残差、最大/RMS RGB误差、CPU/Metal误差；写入后核对哈希及保留字段。证据见acceptance-0.3.27.md。


## 0.3.28 RAW异步维护

运行 `PRINTROOM_TEST_REAL_RAW=1 PRINTROOM_VALIDATE_RAW=1 scripts/test.sh --filter 'RAWEditorIntegrationTests|RAWImageServiceTests|RAWGeometryTests|RAWSourceServiceTests|RAWPrewarmerTests'`。验证一个实例的慢转换不阻止其他源返回和槽位复用，维护不删除活动staging，小容量缓存空闲后收敛，以及真实RAW编辑与代理取样。维护完成断言显式等待后台队列，不能把代理返回当作清理完成。证据见acceptance-0.3.28.md。


## 0.3.29 裁剪切图保存

运行 `scripts/test.sh --filter 'SelectionCropTests|CropEditingTests|RAWGeometryTests|EditorKeyboardRoutingTests'`，验证点击和左右键切图保存、原片裁剪与方向保留、项目立即回读、重置全图、逐次撤销重做、扩选保持草稿、快速加载不覆盖裁剪与取消行为。实际证据见 [acceptance-0.3.29.md](acceptance-0.3.29.md)。


## 0.3.34 缓存管理

`scripts/test.sh --filter 'DiskCachePolicyTests|RAWSourceServiceTests|ThumbnailMigrationTests|ImageServiceTests'` 检查统一预算/跨类型LRU、期限边界、永不、持久化与非法值、陌生文件/符号链接保护、现有RAW并发维护及缩略图迁移。`bash scripts/cache-window-qa.sh` 截取独立管理窗口检查布局。实际结果和未验证项见acceptance-0.3.34.md。


## 0.3.36 LUT直接白点对齐

DiffuseWhiteTests覆盖两份表685 CV的ICC亮度及RGB中性、不同通道反差固定点和CPU/Metal。DirectLUTTests覆盖直接D3查表、v5到v6参数保留和原字节备份；CineonLUTTests覆盖正式资源、同步、预览和混合导出回读。生成器固定随机种子测量重采样误差。两卷补偿核对历史整数差、其他字段保持、备份与正式加载，具体证据见acceptance-0.3.36.md。


## 0.3.37 缓存命中与维护频率

`scripts/test.sh -c release --filter 'RAWSourceServiceTests|RAWPrewarmerTests|DiskCachePolicyTests|ThumbnailMigrationTests'`：验证命中不新增维护、新代理仍触发维护、显式维护继续运行，以及损坏重建/四路/取消/容量/期限回归。性能用 `PRINTROOM_RAW_MEASURE_BACKGROUND=1 PRINTROOM_RAW_MEASURE_ROLL=/path/to/RAW scripts/test.sh -c release --filter RAWPreviewPerformanceMeasurements`，读取指定卷项目及前六帧，不保存项目；正常服务可能更新或重建应用缓存。记录读取与包含直方图的渲染耗时，不等同于窗口呈现时间。

## 0.3.39 自动裁切与自由比例

`AutoCropTests`覆盖解析旋转帧、无边缘帧和可选76帧代理对照；`AutoCropProjectTests`覆盖schema6字节备份与自由比例/来源/检查标记重开；`AutoCropEditingTests`覆盖普通保留/覆盖、手动全图、整组撤销、检查队列、取消/切卷迟到结果、并发目标修改/保留调色及不完整结果拒绝。`CropTests`新增自由裁框整数样本、D4转换、重复拟合、边界、分块导出与预览对照；`CropCanvasTests`验证独立边角拖拽。窗口使用`PRINTROOM_CROP_QA_SOURCE=/path/to/proxy.tiff bash scripts/crop-window-qa.sh --release --autocrop`，源只复制到scratch；验证原生批量、最小窗口、筛选、确认、自由拖拽及重开，截图仅本测试窗口。实际证据见acceptance-0.3.39.md。

## 0.3.40 自动裁切设置与检查流程

`AutoCropTests`新增首尾帧四边通过要求，并确认严格规则只改变检查标记、不改变检测框；`AutoCropEditingTests`覆盖保留旧版/手动/既有自动裁切、取消勾选后整卷覆盖、0–5%内收、整组撤销及检查队列。窗口验证检查独立入口、设置对话框运行中保持、进度与取消、完成自动进入仅看待检查，以及检查控件只在裁切栏出现且清零后隐藏。实际执行范围见acceptance-0.3.40.md。
