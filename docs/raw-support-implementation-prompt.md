请在 `/Users/bao/Desktop/Printroom` 中实际实现 RAW 支持，完成相关验证并打包交付，不要只提交方案。下面包含用户目标、已完成实验和实现要求。

## 用户目标与授权范围

我是用数码相机翻拍负片。我满意 open-make-tiff 开启 Adobe 选项后的结果，希望 Printroom 复现这种 RAW 输入处理效果。

我的“只允许 Adobe”指：**RAW 去马赛克必须由 Adobe 完成；允许 LibRaw 读取 Adobe 生成的 Linear DNG 并执行后处理。** Adobe 未安装、不支持输入或转换失败时明确报错，不允许自动退回 LibRaw、系统 RAW 解码器或其他去马赛克算法。

期望流程：导入 RAW 后先生成小尺寸、未调色的线性 TIFF 代理供编辑；最终导出使用全尺寸线性 TIFF 中间文件，再进入 Printroom 现有调色和输出管线。全尺寸中间文件也可因 1:1、片基校准或吸管而提前按需生成。原始 RAW 始终不改写。

首版必须完整支持现有 Sony A7C II 的八张 ARW。其他机型或编码没有实测，不要仅因 Adobe 宣称支持就把它们写成已验收；可按实际能力扩展，但不能削弱上述 Adobe-only 去马赛克约束。

## 开始工作

先检查 Git 工作区，阅读 AGENTS.md、README.md、docs/roadmap.md、docs/decisions.md、docs/pipeline.md、docs/interaction.md、docs/architecture.md、docs/validation.md。当前工作区存在其他任务的未提交修改，涉及同步交互、矩阵、直方图等；保留并基于最新状态实现，不重置、不覆盖，也不要把其他代理修改归为本次成果。不要照抄历史版本号或旧矩阵定义，以当前规范和代码为准。

必须阅读已完成的 RAW 实验：

- `/Users/bao/Desktop/Printroom/docs/raw-adobe-study-2026-09-09.md`
- `/Users/bao/Desktop/Printroom/docs/raw-adobe-study-2026-09-09.json`
- `/Users/bao/Desktop/Printroom/scripts/raw-adobe-study/README.md`
- `/Users/bao/Desktop/Printroom/scripts/raw-adobe-study/decode.cpp`

参考源码位于 `/Users/bao/Desktop/open_make_tiff`，重点是 `internal/convert/convert.go`、`pkg/dngconverter/` 和 `pkg/golibraw/`。只参考它的处理思路和数值行为，不要求照搬 Go、GUI、任务组织或 TIFF 写入实现，不修改该参考项目。

实验产物目前位于 `/Users/bao/Desktop/Printroom/scratch/raw-adobe-study`。先检查是否仍存在，可复用已验证的基准和脚本，不无意义地重做整个研究；必要重跑只在 scratch 或临时目录进行。

## 已证实的结论：作为实现依据

实验环境：Adobe DNG Converter 18.1.1 (2422)、LibRaw 0.22.1、macOS 26.6.2、arm64。输入为 TEST/RAW/DSC07119.ARW 至 DSC07126.ARW。

1. open-make-tiff 的原两遍 Adobe 路线是：
   - RAW → 中间 CFA DNG：`-u -p0 -cr5.4`
   - 中间 DNG → Linear DNG：`-u -l -p0 -dng1.1`
   第一遍在这八张样片上没有改变 CFA 样本，第二遍执行去马赛克。
2. **单遍 `-u -l -p0 -dng1.1` 可直接得到相同的 Linear DNG。** 八张完整 DNG 数组逐样本相同；经过相同后处理的全尺寸 RGB，与用户所给 open-make-tiff 源码实际生成的 TIFF 逐样本相同。共 785,793,024 个 RGB 通道样本，改变数量、最大绝对误差、RMS 均为 0。
3. 不得把 `-cr5.4` 合并进单遍命令。本机实测它会覆盖线性和压缩选择；即使调整参数顺序，结果仍是 CFA DNG。`-dng1.1` 本身也不代替 `-l`。
4. DNG 要识别真正的 RAW 主图，验证 LinearRaw photometric=34892、预期通道/样本格式及有效尺寸；不能把首个 IFD 的缩略图当输入，也不能仅凭扩展名、退出码或文件存在视为成功。`-p0` 不缩小 RAW；`-dng1.1` 的输出可能仍标记 DNGVersion=1.4、BackwardVersion=1.1，不要错误拒绝。
5. LibRaw 处理这类 Linear DNG 时不会再次去马赛克。AHD 改成 bilinear 的对照结果完全相同。`half_size=1` 同样没有缩小输出，不能靠它生成代理。
6. 应保留以下已验证的 LibRaw 处理参数，而不是使用默认照片显影设置：

```text
user_mul = [1, 1, 1, 1]
output_color = 0
user_flip = 0
highlight = 1
output_bps = 16
no_auto_bright = 1
user_qual = 3
gamm = [1, 1]
adjust_maximum_thr = 0
use_camera_matrix = 0
```

读取顺序参考：open_file → adjust_to_raw_inset_crop(3, 0) → unpack → dcraw_process → copy_mem_image。不要额外开启相机白平衡、自动曝光、标准色域转换或非线性 Gamma。

7. 本批数据实测：Linear DNG 主图 7040×4688，有效裁剪 (12,8,7008,4672)；输出等价于有效区域像素减去 2048 后负值归零，最大值 63487。**没有再次乘以 65535/(65535-2048)**。额外归一化会破坏复现。尺寸、裁剪和黑位必须从实际输入/LibRaw 获取，不要把这些样片数值硬编码成通用规则，也不要自行用一个减黑公式替换完整 DNG 处理。
8. 原程序的 ICC 选项只嵌入 profile，不改变 RGB；例如其 ProPhoto.icm 实际不是线性 TRC。不要对 RAW 中间文件按 ICC 自动解码或转换，也不要为了显示“正确”而给内部样本加 Gamma。接入 Printroom 的样本解释要成为明确的 RAW 输入策略，保持原有 TIFF 输入数值行为。
9. Printroom 实际 TIFFCodec 已对八张基准完成完整读取、1600×1066 nearest 代理无损回读和 11×11 原始 ROI 检查，均精确一致。尺寸使用现有取整策略，不能擅自变成 1600×1067。
10. 单遍 Adobe 部分中位约 0.819 秒/张，两遍约 1.422 秒/张。这只是本机观测，不是整条导出流程或所有硬件的承诺。原生解码实验子进程峰值约 692 MiB，应限制并发。示例无压缩 DNG 约 189 MiB、全尺寸 TIFF 约 187 MiB、Deflate 代理约 8.3 MiB。
11. 单张补测无损压缩 DNG 的像素相同，体积约 102 MiB，但解码约 1.08 秒，明显慢于无压缩的约 0.18 秒。首版优先无压缩 DNG 的速度缓存，不引入有损代理 RAW。

基准范围必须准确表述：已安装 open-make-tiff 0.1.1 的 CLI 存在 Wails 启动故障，实验使用的是从用户源码原样复制、独立编译的转换模块，跳过 GUI 和 ExifTool 元数据写入。验证的是 RGB 数值，不是未知旧版应用的全部元数据或 ICC 显示外观。相关源码/输入哈希和输出样本哈希已保存在 JSON。

## 实现要求

### 1. RAW 准备层与依赖

在现有图像源读取服务前增加清晰的 RAW 准备层，统一提供源身份、有效全尺寸、代理、精确区域/全尺寸读取入口。不要仅修改打开对话框扩展名，也不要在 EditorModel 各处散落外部转换逻辑。

使用 macOS Process 的 executableURL 和独立 arguments 调用已安装的 Adobe DNG Converter；不要构造未经转义的 shell 命令。默认检测 `/Applications/Adobe DNG Converter.app`，记录真实版本。缺失或失败时给出清楚的恢复/重试入口；依赖失效不得损坏项目或影响现有 TIFF 工作。无需为了安装 Adobe 自动下载或改写它。

处理取消、超时、非零退出、缺失/不完整输出、转换时源文件变化。读取有效主图并验证已由 Adobe 去马赛克后才能进入 LibRaw。失败不得默默换后端，缓存也不能绕过错误使用另一种处理结果。

生产 LibRaw 必须可重复构建并随 Printroom 正确打包，优先使用已验证的 0.22.1；静态/动态链接和桥接细节自行决定，包含所需许可文件和可执行构建步骤。**实验中借用 rawpy、Siril、Go、Python、ExifTool 只是研究工具，正式应用不能依赖这些应用、scratch 路径或用户额外安装的运行库。** 不打包借来的测试 dylib 当作生产依赖，不拷贝整个 open-make-tiff 应用。

### 2. 代理与全尺寸

导入优先准备当前帧，其他帧后台排队；持续切图或调参不阻塞主线程。同一源/处理配置的并发请求复用一个准备任务，避免预览、缩略图、采样和导出各自重复启动 Adobe。取消一个消费者时不要误删其他任务正在使用的结果。

代理保存未调色的 16-bit 线性 RGB。首版沿用当前 nearest-original-sample 和长边 1600 策略，调色、卷级片基、矩阵、裁剪等仍由现有管线处理，不烘焙进源代理。不使用相机内嵌 JPEG 或 DNG 缩略图作为数值调色输入。

首次生成代理允许全尺寸 Adobe 去马赛克和 LibRaw 解码，但避免必须先把整张全尺寸 TIFF 写入磁盘再生成代理。解码后写小代理并释放大缓冲，缓存 Linear DNG。不要声称小代理免除了首次全尺寸 RAW 解码。

全尺寸 TIFF 在导出、1:1、片基校准和中性点吸管需要时准备并复用。使用支持区域读取的多个较小条带，编码兼容 Printroom 的无压缩/Deflate 路径；不照搬原程序的整图单条带或 LZW。

这些精确功能必须使用原始分辨率样本，代理坐标映射到有效全尺寸坐标；等待期间应明确显示准备状态。不能用代理采样假装原始精度。代理、全尺寸和最终导出必须共享同一源文件身份、同一 Adobe/LibRaw 处理策略。

有效 RAW 裁剪、源方向和用户追加的旋转/翻转应有明确分层，避免重复应用方向或裁剪。按照当前几何契约映射所有裁剪、取样与 1:1；复现中间样本时保留上述 user_flip=0 语义，不擅自改变参考像素布局。

### 3. 项目与缓存

项目绑定原始 RAW 的稳定 frameID、相对路径与指纹；DNG、proxy TIFF 和全尺寸 TIFF 都是可再生缓存，不能成为项目唯一真源，也不能被卷发现当成新的照片。

审计所有直接调用 TIFFCodec 或假定源是 TIFF 的地方，覆盖：文件发现/打开、metadata、主预览、Filmstrip、直方图、裁剪/几何迁移、片基校准、吸管、1:1、缺失重连以及单张/所选/整卷导出。保留当前同步、复制、撤销等行为。

必要时升级 schema，给旧 TIFF 项目明确默认值，按现有规则迁移/备份；不改变旧 TIFF 的图像结果。记录 RAW 处理策略版本和转换器/LibRaw 版本，而不把所有新字段塞进既有密度算法常量。整卷移动、缺失重连和缓存清理后仍能恢复调色。

缓存身份至少包含原始文件身份/修订、Adobe 版本与参数、LibRaw/RAW 处理策略版本、有效尺寸及代理采样版本。不能在 Adobe 升级后混用旧代理和新全尺寸。改变处理策略或原片后使相关缓存失效，片基校准来源变化按现有复核规则处理；保留用户调色。

缓存采用原子发布，设置明确的容量上限和淘汰规则，内存有界。清理只删除应用拥有且未被任务占用的缓存；项目和原始资产不受影响。缓存目录/限额等常规工程选择自行决定并记录，不为这些细节停下来索要确认。

### 4. 导出与兼容

沿用现有固定快照导出语义：提交时冻结原始 RAW 指纹、处理策略、卷校准、逐帧调色、方向、裁剪和输出选项。中途编辑不改变任务；准备全尺寸失败必须正确反馈为该帧失败，不能导出代理尺寸或旧版本结果。

继续保护全部原始 RAW/TIFF 路径，不覆盖源文件，保留当前重名处理、原子输出和批量取消行为。最终 ICC 转换、CPU/Metal 算法以及 LUT 后编码遵守当前 pipeline.md，不因 RAW 支持引入额外 Gamma 或改变密度矩阵。

## 必须完成的验收

1. 八张真实 ARW：生产桥接/正式解码路径生成的全尺寸 RGB 与已记录的源码基准逐样本一致，尺寸一致，最大误差为 0。可以复用 JSON 中 `comparisons[].rgb_hash` 和现存参考 TIFF；哈希针对按行连续 little-endian UInt16 RGB 样本，不是 TIFF 文件字节。不能把待测路径自己的输出重新定义为基准；若更换依赖后不一致，定位原因，不能擅自放宽容差。
2. 验证生产路径确实使用 Adobe 去马赛克；缺少 Adobe、转换失败或错误输出为 CFA 时不允许 fallback。测试可注入可控进程执行器验证错误分支，但实际成功路径必须跑真实 Adobe。
3. 对比单遍与原两遍的验证可复用本轮证据；若参数、依赖版本或相关处理发生变化，再做针对性实测，不能机械重跑全部研究或将未经重验的新结果标为相同。
4. 代理与同源全尺寸按相同采样规则得到的 RGB 一致；TIFF 回读保持 16-bit 样本。使用真实当前 CPU/Metal 管线验证 RAW 路径输出没有额外颜色变换，并与同一基准 TIFF 加同一组调色参数的结果比较。不能把不同采样/裁剪导致的差异混入 RAW 解码误差。
5. 片基校准、中性点吸管、1:1、裁剪及旋转/翻转映射正确；代理未就绪和全尺寸准备期间不提交错误坐标/过期取样；撤销和重开恢复正确。
6. 旧 TIFF 项目结果保持；RAW 项目保存重开、卷移动/缺失重连、清理缓存后重建保留 frameID 和调色；RAW+TIFF 目录发现不导入缓存。项目迁移和外部保存冲突遵守现有保护。
7. 快速切帧、取消、重复请求、源文件替换、无权限/磁盘写入失败、转换器版本变化、缓存损坏时无串帧、死锁、半文件成功状态或原始资产损坏。测试并发消费者共享准备任务的行为。
8. 单张、所选和整卷导出使用真实全尺寸及冻结快照，输出尺寸和 ICC 正确；导出期间继续调色不改变已提交任务。
9. 测量真实导入/首次代理、缓存命中、首次精确操作、单张/整卷导出时间和峰值内存。记录实测数据、并发设置与缓存大小，不承诺研究中未测的性能。
10. 原始 TEST/RAW、TEST/TIFF、ICC、LUT 全程不改动。UI/旁存测试先复制样片到 scratch 或临时卷目录，不能直接在 TEST 内生成项目。记录原始资产前后哈希。

按 docs/validation.md 执行与实际变更直接相关的测试和应用验证，记录通过、失败及未执行项。不要因为历史验收记录存在就宣称新 RAW 集成已验收，也不要要求 Photoshop 对照或上传样片。

## 文档、构建与交付

把正式 RAW 数值契约写进 pipeline.md，交互写进 interaction.md，源模型/缓存/迁移写进 architecture.md；decisions.md 记录持久决定，roadmap.md 记录阶段，新增本版验收记录，并更新 README 的实际依赖、运行/构建命令和支持边界。实验报告作为历史证据保留，不把它变成第二套随意修改的算法规范。

使用 `scripts/build-app.sh`，固定交付 `/Users/bao/Desktop/Printroom/output/Printroom.app`，显示名称 Printroom，应用标识保持 `studio.printroom.local.v3.3`。新包构建、资源和签名验证通过后再替换旧包；失败保留现有可用应用。不要另建带版本/功能后缀的软件副本，不创建远端、不推送、不发布。

最终说明已实现功能、与参考的数值一致性、测试与性能证据、Adobe 依赖和剩余兼容边界。常规实现选择自行处理并持续完成到可运行交付；遇到真正阻塞或冲突时说明具体原因。
