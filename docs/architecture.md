# 架构与项目数据

状态：0.2.0；使用 Swift Package 实现核心与 SwiftUI 应用；构建脚本生成原生 `.app`，没有 `.xcodeproj`。公式见 [pipeline.md](pipeline.md)，交互见 [interaction.md](interaction.md)。以下为设计契约，文末列出本版实际映射与边界。

## 模块边界

| 模块 | 责任与边界 |
| --- | --- |
| PrintroomApp / EditorView | SwiftUI 生命周期、预览/面板/Filmstrip；不直接实现公式或读写 TIFF |
| RollProject / ProjectStore | RollProject、FrameRecord、版本迁移、原子保存、文件协调 |
| Pipeline | 无 UI、无显示转换的 Float32 CPU 核心，阶段纯函数、参数校验、数值诊断；本地 Swift Package |
| MetalPipeline | 与 CPU 相同阶段和 LUT 插值，纹理/缓冲区管理、取消和最新预览提交 |
| TIFFCodec 原始读取 | 解码原始 UInt16 RGB、metadata/orientation；禁止隐式 ICC 转换 |
| OutputColorConverter / DisplayImage | 原始 profile 记录、最终输出与显示器转换、导出 profile 解析 |
| ExportEngine / TIFFCodec 输出 | 输出 profile 转换后的样本量化、16-bit 写入、ICC 嵌入、无覆盖发布 |
| ImageService / DiskThumbnailCache | 可再生的最终外观缩略图、缓存身份、过期与清理 |
| Diagnostics | 阶段值/域外计数/计时/错误，不能将原图上传或记录整幅像素日志 |

UI 只通过模型命令修改参数；渲染接收捕获后的不可变参数值，导出使用 `ExportRequest` 快照。CPU 参考独立于 Metal，作为算法对照，不能为通过测试而直接调用 GPU 代码。输入采用可控的 TIFF 条带解码以保持样本值；ImageIO仅用于可再生PNG缓存与独立输出回读，显示器适配由系统完成，四输出ICC由已验证matrix/TRC转换器处理。

## 卷项目结构

运行时结构（不是本仓库的测试输出位置）：

```text
Roll/
├── Scan001.tif
├── Scan002.tif
├── .printroom.json
└── .printroom-cache/
```

默认非递归扫描，扩展名大小写不敏感，自然文件名升序；名称比较相同时用完整相对路径作稳定次序。只接受直接子文件，不自动跟随指向卷外的符号链接。未知或无法读取文件保留可解释的失败状态，不中断整个目录发现。

文件夹访问由用户打开文件/文件夹授予；沙盒版本需要时保存安全作用域书签，不假定选中单文件即可读写整个目录。若当前访问不足，界面提供选取卷文件夹入口。初始开发为本地应用，不配置签名发布或商店流程。

## 持久模型契约

`schemaVersion=2`，`algorithmVersion="printroom-density-v2"`；schema 1 显式迁移，见文末。项目至少含：

| 字段组 | 数据与约束 |
| --- | --- |
| identity | rollID（UUID）、创建/更新时间、schemaVersion、algorithmVersion |
| assets | LUT 与工作 ICC 的相对引用、SHA-256；矩阵标识由算法注册表解释 |
| inputInterpretation | primaries=P3-D65、transfer=linear、policy=assignPreserveSamples |
| calibration | 状态、来源 frameID、整数选区/坐标空间/尺寸、baseRGB、gainRGB、filmBaseOffsetCV、printDensityMatrix |
| frames | frameID→FrameRecord 映射，记录相对路径、源文件指纹、Timing、Contrast、独立 orientation；不使用数组下标作为 ID |
| ordering | frameID 顺序列表和排序模式；新文件插入自然位置，不改变已存在 ID |
| exportSettings | profile 身份、16-bit TIFF、ICC 开关、抖动、命名规则；本地目录授权单独管理 |
| viewState | 可选 lastActiveFrameID；不保存多选、撤销历史或复制快照 |

FrameRecord 的初始 Timing 四项为 0，Contrast 四项为 1；pivot 与算法绑定，首版不做逐帧字段。无校准时明确 `status=uncalibrated`；来源与采样字段可为空，gain/offset 使用规范默认。已校准时必须完整保存采样依据及派生量。加载时重算并检查派生量；不一致则报告不兼容或损坏，不无声覆盖文件。

JSON 数值必须有限；整数 Timing 不接受小数。记录 `schemaVersion` 处理结构迁移，记录 `algorithmVersion` 处理图像行为迁移；二者不能互相替代。损坏或不支持的高版本项目禁止自动重置并覆盖。

### 稳定 ID 与重新发现

工程默认：首次发现为每帧分配持久 UUID，以卷内相对文件名定位。整卷移动后相对路径保持有效。文件大小与修改时间用于快速变化检测，必要时校验内容摘要；同卷内文件系统 resource identifier 可作为重命名线索，但不是跨机器唯一依据。

路径相同、内容替换：保留 frameID/调色，标记源变化并使缓存失效；若为片基来源，则标记校准需要复核，保留原参数，禁止冒充校准仍已验证。重命名只有在唯一且可验证的文件身份匹配时自动重连，否则保留缺失条目并提供重新定位；不能凭缩略图下标或猜测名称迁移调色。

缺失帧不删除参数；重新出现后恢复。M2 必须实现缺失提示与明确重连方式。大 TIFF 不在每次滑块变动时重新计算整文件 SHA-256。

## 保存、事务与并发

- 模型写入串行化；批量应用预校验全部目标，在一次事务中修改。
- 普通滑块编辑自动保存防抖为 2 秒（用户指定）；滑块结束、数值提交、批量应用、校准/矩阵变更后立即安排保存。
- 临时文件写在项目同一目录，完整编码成功后原子替换 `.printroom.json`；中途失败不得留下截断的正式项目文件。
- “参数已应用”与“项目已保存”是不同状态。保存失败保留 dirty 状态、重试入口和内存数据。
- 切换卷或正常退出时等待最后保存；失败时提供重试、另存项目或用户明确放弃未保存内容的选择。
- 只读目录可编辑预览，但明确不能旁存；提供另存项目。权限变化后重试，不悄悄把项目放到不可发现的位置。
- 同一应用实例内，同一卷复用会话；外部项目修改通过文件协调及保存前版本/修改标记检测，冲突时停止覆盖并提示重新载入或另存副本。首版不自动合并两套调色。
- 不保存缩略图像素到 JSON；缓存状态可提示但不能作为业务真相。

## 预览、缓存与资源使用

每个渲染请求包含 frameID、源修订、卷参数修订、帧参数修订、阶段及资产身份。切图、校准、阶段或方向变化取消旧上下文；连续 Timing/Contrast 编辑按下文的单在途、单待办策略发布递增快照，最后收敛到最新参数。直方图/读数仍严格匹配当前渲染修订。

参考单帧 7008×4672；RGB Float32 约 393 MB（375 MiB），RGBA Float32 约 524 MB（500 MiB）。不得同时常驻全部 10 张的全分辨率阶段图。默认按需加载当前帧、低分辨率异步预览、有限 LRU 缓存；片基采样读取原始像素；全尺寸导出分块处理。全尺寸 CPU 参考可慢，但数值行为必须一致。

缩略图缓存身份包括源指纹、算法版本、卷校准与矩阵、帧参数、LUT/ICC 哈希、尺寸与显示策略。展示策略以独立 `presentationVersion` 纳入缓存键；本次 Float32 CGImage 改为 UInt16 展示副本必须使旧缓存失效，无需更改项目 schema 或算法版本。缓存存储带明确 profile 的最终外观缩略图，不缓存依赖某台显示器 profile 的最终设备值。显示器变化重新显示转换；缓存可丢弃重建。

## 工具链与构建落地

工程使用 macOS 14+、arm64、Swift 6、系统框架与本地 Swift Package，已创建 app/test targets 和可重复脚本。Swift 并发隔离、Metal 数值路径、原始样本保真与输出回读已在当前机器测试；旧系统兼容、更多显示设备与多 profile 导出见下方 0.2.0；旧系统/设备仍待验收。

## 0.1.0 历史实现（后续变化见下方 0.2.0）

- `Sources/PrintroomCore`：Contracts、CPU Pipeline、MetalPipeline、TIFFCodec、RollProject/ProjectStore/SelectionState/ParameterSnapshot。
- `Sources/PrintroomApp`：EditorModel、SwiftUI EditorView、AppKit PreviewCanvas、ImageService actor、DisplayImage/AppAssets、App 生命周期。
- 核心用 XCTest，异步 UI 模型集成使用 Swift Testing；命令在 README 与 `scripts/test.sh`，打包入口为 `scripts/build-app.sh`。
- TIFF 解码采用自有 classic TIFF 条带解析及系统 zlib，绕过隐式 ICC 转换。GPU 通过 Float32 buffer 运行完整管线，DisplayImage 仅将展示副本转为 UInt16 RGBA CGImage 并携带原始 ICC 交给系统显示，量化与诊断解释遵守 [pipeline.md](pipeline.md#9-预览导出与中间阶段诊断)；全尺寸导出复用 GPU 算法并由编码器分块请求样本。
- 项目已编码 inputInterpretation、assets、exportSettings、calibration、calibrationNeedsReview、frames 与 lastActiveFrameID，数组元素使用稳定 UUID。排序为确定的自然文件名顺序，暂无手动排序 UI。
- 打开项目的修改时间令牌在与 JSON 相同的文件协调读操作内捕获，保存检查此令牌，避免读完再取新令牌导致覆盖他人修改。
- 源缓存使用新鲜文件系统属性比较尺寸/修改时间；重开卷清空内存缩略图源，磁盘缓存键包含文件、参数、算法、ICC/LUT、尺寸与独立展示策略版本身份。暂不做周期磁盘缓存清理。
- 保存冲突可另存经版本化的本卷 JSON 设置副本，再通过 File 菜单恢复；也可明确放弃未保存修改后重新载入。设置副本禁止直接覆盖当前项目，恢复需匹配卷 ID 并再次执行冲突检查。
- 缺失条目保留设置、原名重现可恢复；未实现改名后的手动重连界面。项目文件之外的独立恢复副本不改变原始 TIFF。
- 本版是本地 ad-hoc 签名应用，没有 App Sandbox/商店签名配置。macOS 14 部署目标未进行旧系统实机验收。

## 0.2.0 模型与迁移（当前契约）

本节更新上文 0.1.0 实现边界。`schemaVersion=2`；算法版本继续 `printroom-density-v1`。`FrameRecord.orientation` 是独立于 `FrameAdjustments` 的八状态 D4 枚举；`ProjectExportSettings` 增加 profile 和 compression，同时持久化 profileSHA256。Timing/Contrast 参数快照格式不变。

解码先读 schema/algorithm 头，再只对 schema 1 补 identity、P3、无压缩并设置 schema 2。迁移保留全部已有 ID、输入策略、校准、帧调色和视图状态；schema 2 缺失新增必需字段仍报损坏，不借默认值吞掉文件错误。首次正常保存写 schema 2。0.1.0 不支持新结构，会拒绝读取；新旧应用使用独立 bundle identifier，避免窗口状态和偏好冲突。恢复 JSON 设置副本同时恢复方向与输出设置。

`ProjectStore.relocate` 在同卷内绑定新文件名并验证可读 TIFF，保留 UUID 和全部帧设置。新发现的默认、无方向且非片基来源占位帧可合并；已编辑目标不能被覆盖。来源变化更新指纹、使片基状态需要复核，不丢失旧校准。

## 0.2.0 并发、资源与缓存

`ImageService` 通过 TIFF metadata/readPreview/readRegion 在 UInt16 条带层直接提取预览或必要 ROI，输入不经 ImageIO/ICC 转换。低分辨率源缓存为有限 LRU（64 MiB、12 项），身份包含路径、大小、mtime 和文件系统身份；兼容 load() 不常驻全图。原始区域最多 8,388,608 像素，普通 Retina 窗口 1:1 可用；超大窗口区域明确报错，未自动降采样。读取压缩TIFF仍须完整解压相交条带；非常大的单条带可能增加临时内存及取消延迟。

主预览、缩略图、1:1 有独立后台渲染 actor；主预览与1:1共享当前源读取服务，缩略图读取独立；GPU 仍 Float32，DisplayImage 的 UInt16 展示副本也后台制作。调度和 GPU 复用遵循下方的调参性能补记。直方图可取消，发布时验证当前帧/阶段/渲染修订。

磁盘 `DiskThumbnailCache` 存储嵌入工作 ICC 的 PNG，键包含源指纹、方向、调色、校准、阶段策略、LUT/ICC、算法与展示版本。默认 512 MiB / 30 天未访问；刷新/写入时清理（不运行周期定时器），仅删除本缓存目录的已知哈希 PNG 与超过一天的已知临时文件，不跟随 symlink，不删除陌生文件。UI 可手动清理，后续重建。

`ExportRequest` 为不可变值：固定 ordered 帧、源路径/大小/mtime、校准、Timing/Contrast、方向、profile/compression，以及全卷受保护原路径。独立 `ExportEngine` actor 逐帧串行导出，当前帧原始 UInt16 全图 + 有界 Float32 行块；图像和文件输出与主预览 lane 分离。所有出口共享真实 ICC 转换与量化，取消在读条带、处理块和发布前检查。写入同目录临时文件，再原子 `RENAME_EXCL` 发布；同名或发布竞争不得覆盖已存在文件。


## 0.2.0 调参性能优化

主预览取消 25ms 尾部防抖，采用一个在途请求和一个可覆盖的待办快照。连续 Timing/Contrast 编辑保留正在运行的任务，完成后按递增顺序发布同源、同校准、同阶段、同方向的画面，再消费最新待办；跳过中间未执行的参数，不积压队列。切图、重新加载、校准、阶段、方向改变会取消旧上下文，已提交 GPU 工作允许完成但不能覆盖新上下文。最后一次编辑必定渲染完成，1:1 仍等待主预览稳定后读取。

每个渲染 actor 独享 `MetalPipeline.Session`，复用 source/destination/LUT 缓冲区；兼容的导出 render 接口使用独立受锁保护的 session。主预览每次成功载入生成不可变输入 UUID，同一源调参复用该 UUID，重读即换。D1 缓存身份包含输入 UUID、尺寸、gain、matrix；保留 Float32 阶段值，Timing/Contrast/自动偏移只执行 D1 后段，gain/matrix 改变重算前段。L0/L1/D0 诊断仍从原始源执行相应阶段；LUT 内容改变重新上传。nil UUID 的缩略图/1:1/导出每次验证并上传源，不复用 D1。各 lane 仅保留一份 source/destination/D1，每个像素 buffer 最多 1600²×16 bytes；超出预算的原始区域 buffer 用完释放，无全卷 GPU 原图缓存。

整图直方图在最终预览稳定 120ms 后后台计算。新编辑取消等待或扫描，清空旧统计；连续快速拖动期间显示更新状态，停止后统计最后参数。区间、bins、计数与数值来源仍以 pipeline.md 为准。

缩略图维护未完成帧 ID 集合：单帧编辑结束仅加入该帧，批量应用加入目标，Undo/Redo/恢复按前后差异加入；卷级校准变化、重开或主动清理重建全卷。取消刷新保留未完成目标，并优先当前帧；未变化且已完成的照片不再读取 PNG 或重新发布 CGImage。每次实际读取目标仍校验源指纹；磁盘容量/TTL 规则保持。1:1 原始区域缓存不在此次优化范围。


## 白点 pivot 算法迁移

当前算法 v2 采用 685 CV（见 pipeline.md §13），schema 仍为 2。v1 项目读取后升级算法身份，不补偿原调色参数；用户已明确接受既有非单位反差外观变化。保存先检查外部修改时间和项目 ID，再以独占新文件保存 v1 原 JSON 字节备份，成功后才原子替换正式项目。备份失败即停止，v2 后续保存不重复备份。缓存以算法身份失效，参数快照要求 v2/685 CV。


## 0.3.0 项目、裁剪与资源

本节更新先前 schema 2 契约：当前 `schemaVersion=3`，`FrameRecord.crop` 为必需键，值可为 null；非空值采用 pipeline.md §14 的版本化几何。schema 1/2 明确迁移为无裁剪，保留原 ID、调色、方向与输出设置，schema 3 缺失 crop 或未知几何版本属于损坏/不支持，禁止用默认值吞掉错误。旧项目首次覆盖前保留原 JSON 备份，备份失败则停止保存；旧应用拒绝 schema 3。0.3.0 使用独立包名和 bundle identifier，保留 0.2.0 应用。

EditorModel 分离裁剪草稿和项目，草稿提交/多选同步统一事务、整组撤销和保存。主预览上下文增加裁剪与源尺寸，几何切换取消旧渲染并清除不匹配展示，避免旧图配新尺寸。主预览 actor 只保留当前几何的有界输入，调色时可复用几何输入及 D1 缓存；未裁剪路径保留既有行为。缩略图缓存键增加裁剪，源尺寸由真实 TIFF metadata 提供。恢复、同步和撤销按受影响帧失效。

ExportFrameSnapshot 固定裁剪值；导出期间的新编辑不改变已提交任务。CropGeometry 以一份原始 UInt16 图生成有界行块，不常驻全尺寸 Float32 旋转结果。1:1 通过 sourceRegion 读取必要原始包围区域并重采样，保留原来的区域预算和取消检查。缺失帧重新定位保留裁剪，含裁剪的占位条目不被合并覆盖。
