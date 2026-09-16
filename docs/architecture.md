# 架构与项目数据

状态：0.3.3；使用 Swift Package 实现核心与 SwiftUI 应用；构建脚本生成原生 `.app`，没有 `.xcodeproj`。公式见 [pipeline.md](pipeline.md)，交互见 [interaction.md](interaction.md)。以下为设计契约；本轮验证状态见 [acceptance-0.3.3.md](acceptance-0.3.3.md)，历史记录不替代本轮验证。

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
└── .printroom.json
```

默认非递归扫描，扩展名大小写不敏感，自然文件名升序；名称比较相同时用完整相对路径作稳定次序。只接受直接子文件，不自动跟随指向卷外的符号链接。未知或无法读取文件保留可解释的失败状态，不中断整个目录发现。

文件夹访问由用户打开文件/文件夹授予；沙盒版本需要时保存安全作用域书签，不假定选中单文件即可读写整个目录。若当前访问不足，界面提供选取卷文件夹入口。初始开发为本地应用，不配置签名发布或商店流程。

## 持久模型契约

`schemaVersion=3`，`algorithmVersion="printroom-density-v2"`，当前裁剪 `geometryVersion=2`；schema 1/2 与旧裁剪几何显式迁移，见文末。项目至少含：

| 字段组 | 数据与约束 |
| --- | --- |
| identity | rollID（UUID）、创建/更新时间、schemaVersion、algorithmVersion |
| assets | LUT 与工作 ICC 的相对引用、SHA-256；矩阵标识由算法注册表解释 |
| inputInterpretation | primaries=P3-D65、transfer=linear、policy=assignPreserveSamples |
| calibration | 状态、来源 frameID、整数选区/坐标空间/尺寸、baseRGB、gainRGB、filmBaseOffsetCV、printDensityMatrix |
| frames | frameID→FrameRecord 映射，记录相对路径、源文件指纹、Timing、Contrast、独立 orientation 和 crop；不使用数组下标作为 ID |
| ordering | frameID 顺序列表和排序模式；新文件插入自然位置，不改变已存在 ID |
| exportSettings | profile 身份、16-bit TIFF、ICC 开关、抖动、命名规则；本地目录授权单独管理 |
| viewState | 可选 lastActiveFrameID；不保存多选、撤销历史或复制快照 |

FrameRecord 的初始 Timing 四项为 0，Contrast 四项为 1；pivot 与算法绑定，首版不做逐帧字段。无校准时明确 `status=uncalibrated`；来源与采样字段可为空，gain/offset 使用规范默认。已校准时必须完整保存采样依据及派生量。加载时按上次片基采样时的密度矩阵快照检查派生量；不以当前矩阵自动重算校准。不一致则报告不兼容或损坏，不无声覆盖文件。

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

每个渲染请求包含 frameID、源修订、卷参数修订、帧参数修订、阶段及资产身份。切图、校准、阶段或方向变化取消旧上下文；连续 Timing/Contrast 编辑按下文的单在途、单待办策略发布递增快照，最后收敛到最新参数。直方图与同一完成预览一起发布；中性点取样仍严格匹配当前渲染修订。等待时保留上一对画面和统计。

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

## 0.2.0 模型与迁移（历史契约）

本节更新上文 0.1.0 实现边界。`schemaVersion=2`；算法版本继续 `printroom-density-v1`。`FrameRecord.orientation` 是独立于 `FrameAdjustments` 的八状态 D4 枚举；`ProjectExportSettings` 增加 profile 和 compression，同时持久化 profileSHA256。Timing/Contrast 参数快照格式不变。

解码先读 schema/algorithm 头，再只对 schema 1 补 identity、P3、无压缩并设置 schema 2。迁移保留全部已有 ID、输入策略、校准、帧调色和视图状态；schema 2 缺失新增必需字段仍报损坏，不借默认值吞掉文件错误。首次正常保存写 schema 2。0.1.0 不支持新结构，会拒绝读取；新旧应用使用独立 bundle identifier，避免窗口状态和偏好冲突。恢复 JSON 设置副本同时恢复方向与输出设置。

`ProjectStore.relocate` 在同卷内绑定新文件名并验证可读 TIFF，保留 UUID 和全部帧设置。新发现的默认、无方向且非片基来源占位帧可合并；已编辑目标不能被覆盖。来源变化更新指纹、使片基状态需要复核，不丢失旧校准。

## 0.2.0 并发、资源与缓存

`ImageService` 通过 TIFF metadata/readPreview/readRegion 在 UInt16 条带层直接提取预览或必要 ROI，输入不经 ImageIO/ICC 转换。低分辨率源缓存为有限 LRU（64 MiB、12 项），身份包含路径、大小、mtime 和文件系统身份；兼容 load() 不常驻全图。原始区域最多 8,388,608 像素，普通 Retina 窗口 1:1 可用；超大窗口区域明确报错，未自动降采样。读取压缩TIFF仍须完整解压相交条带；非常大的单条带可能增加临时内存及取消延迟。

主预览、缩略图、1:1 有独立后台渲染 actor；主预览与1:1共享当前源读取服务，缩略图读取独立；GPU 仍 Float32，DisplayImage 的 UInt16 展示副本也后台制作。调度和 GPU 复用遵循下方的调参性能补记。直方图在主预览 actor 内计算，随同预览执行取消与上下文校验。

磁盘 `DiskThumbnailCache` 存储嵌入工作 ICC 的 PNG，键包含源指纹、方向、调色、校准、阶段策略、LUT/ICC、算法与展示版本。默认 512 MiB / 30 天未访问；刷新/写入时清理（不运行周期定时器），仅删除本缓存目录的已知哈希 PNG 与超过一天的已知临时文件，不跟随 symlink，不删除陌生文件。UI 可手动清理，后续重建。

`ExportRequest` 为不可变值：固定 ordered 帧、源路径/大小/mtime、校准、Timing/Contrast、方向、profile/compression，以及全卷受保护原路径。独立 `ExportEngine` actor 逐帧串行导出，当前帧原始 UInt16 全图 + 有界 Float32 行块；图像和文件输出与主预览 lane 分离。所有出口共享真实 ICC 转换与量化，取消在读条带、处理块和发布前检查。写入同目录临时文件，再原子 `RENAME_EXCL` 发布；同名或发布竞争不得覆盖已存在文件。


## 0.2.0 调参性能优化

主预览取消 25ms 尾部防抖，采用一个在途请求和一个可覆盖的待办快照。连续 Timing/Contrast 编辑保留正在运行的任务，完成后按递增顺序发布同源、同校准、同阶段、同方向的画面，再消费最新待办；跳过中间未执行的参数，不积压队列。切图、重新加载、校准、阶段、方向改变会取消旧上下文，已提交 GPU 工作允许完成但不能覆盖新上下文。最后一次编辑必定渲染完成，1:1 仍等待主预览稳定后读取。

每个渲染 actor 独享 `MetalPipeline.Session`，复用 source/destination/LUT 缓冲区；兼容的导出 render 接口使用独立受锁保护的 session。主预览每次成功载入生成不可变输入 UUID，同一源调参复用该 UUID，重读即换。D1 缓存身份包含输入 UUID、尺寸、gain、matrix；保留 Float32 阶段值，Timing/Contrast/自动偏移只执行 D1 后段，gain/matrix 改变重算前段。L0/L1/D0 诊断仍从原始源执行相应阶段；LUT 内容改变重新上传。nil UUID 的缩略图/1:1/导出每次验证并上传源，不复用 D1。各 lane 仅保留一份 source/destination/D1，每个像素 buffer 最多 1600²×16 bytes；超出预算的原始区域 buffer 用完释放，无全卷 GPU 原图缓存。

0.3.2 构建 3：主预览 actor 同时返回显示图像和可选直方图，裁剪编辑不统计。大图均匀取样规则以 pipeline.md §12 为准。主线程先设置对应统计，再设置画面，中间无挂起；SwiftUI 在同一更新中接收二者。取消旧的独立直方图任务与 120ms 防抖，不等待停手。同上下文递增快照一起替换，跨上下文沿用 generation/context/frameID 校验。缓存占位仍非正式结果，跨上下文不显示旧统计。

缩略图维护未完成帧 ID 集合：单帧编辑结束仅加入该帧，批量应用加入目标，Undo/Redo/恢复按前后差异加入；卷级校准变化、重开或主动清理重建全卷。取消刷新保留未完成目标，并优先当前帧；未变化且已完成的照片不再读取 PNG 或重新发布 CGImage。每次实际读取目标仍校验源指纹；磁盘容量/TTL 规则保持。1:1 原始区域缓存不在此次优化范围。


## 白点 pivot 算法迁移

当前算法 v2 采用 685 CV（见 pipeline.md §13）；白点更新时 schema 为 2，当前裁剪结构为 3。v1 项目读取后升级算法身份，不补偿原调色参数；用户已明确接受既有非单位反差外观变化。保存先检查外部修改时间和项目 ID，再以独占新文件保存 v1 原 JSON 字节备份，成功后才原子替换正式项目。备份失败即停止，v2 后续保存不重复白点迁移备份。缓存以算法身份失效，参数快照要求 v2/685 CV。


## 0.3.1 项目、裁剪与资源

当前 `schemaVersion=3`，`FrameRecord.crop` 为必需键，值可为 null；非空值采用 [pipeline.md §14](pipeline.md#14-031-裁剪与精细旋转) 的版本化几何。新编辑保存 `geometryVersion=2`，坐标位于 TIFF 方向校正后、用户 D4 之前。`FrameRecord.orientation` 与原片裁剪分别保存，改变方向不改版本 2 裁剪值。

schema 1/2 明确迁移为无裁剪，保留原 ID、调色、方向与输出设置；schema 3 同时支持几何版本 1/2，缺失 crop 或未知几何版本仍报损坏/不支持。打开 0.3.0 几何版本 1 项目时，以各帧 TIFF metadata 的原始尺寸和既有方向转换为版本 2，保持原画面。读取本身不改写旁存 JSON；缺失文件或不可读 metadata 保留版本 1，待源文件恢复、重连后取得尺寸再转换，不借其他帧尺寸猜测。

保存先验证项目、修改时间与卷 ID，再备份被覆盖的原 JSON 字节：旧算法沿用 `.printroom-density-v1-UUID.json`，旧 schema 使用 `.printroom-schemaN-UUID.json`，schema 3 的旧几何首次被转换或清除前使用 `.printroom-geometry-v1-UUID.json`。备份以独占新文件写入，失败则停止正式项目替换。已转换为版本 2 后的普通保存不重复该备份；若此前保留的缺失帧后来转换，其旧几何被覆盖前同样保留当时的 JSON。设置副本恢复也按源帧自身方向和可用尺寸迁移几何，恢复裁剪、方向与输出设置，并保留整组 Undo/Redo。

0.1.0/0.2.0 拒绝 schema 3，0.3.0 拒绝几何版本 2。0.3.1 交付独立 `Printroom-0.3.1.app` 和 bundle identifier，保留已有应用及偏好设置。

EditorModel 分离原片坐标草稿与项目；显示控件和 Canvas 使用由当前 D4 转换的临时显示草稿，编辑显示值后转换回原片坐标。草稿提交/多选同步统一事务、整组撤销和保存。同步先捕获当前原片裁剪，再按目标原始尺寸拟合，全组校验成功后一次写入；同尺寸目标裁剪值相同，保留各自方向和调色。

SelectionState 的 active 与 anchor 由普通点击建立；⌘/Shift/⌘Shift 修改目标集合时保持二者，active 不可被 ⌘ 移除。仅目标集合变化不重新载入源、不清除草稿、不更换预览或视口；普通点击或左右键换 active 前先提交当前已加载照片的裁剪草稿，再保持裁剪模式载入新源。具体边界由 interaction.md 定义。

主预览上下文包括裁剪及其几何版本、源尺寸与方向，几何切换取消旧渲染并清除不匹配展示，避免旧图配新尺寸。主预览 actor 只保留当前几何的有界输入，调色时可复用几何输入及 D1 缓存；未裁剪路径保留既有行为。缩略图缓存键包含完整裁剪，几何迁移后自然失效，源尺寸由真实 TIFF metadata 提供。恢复、同步和撤销按受影响帧失效。

ExportFrameSnapshot 固定裁剪值；导出期间的新编辑不改变已提交任务。CropGeometry 以一份原始 UInt16 图生成有界行块，不常驻全尺寸 Float32 旋转结果。1:1 通过 sourceRegion 读取必要原始包围区域并重采样，保留原来的区域预算和取消检查。缺失帧重新定位保留裁剪，含裁剪的占位条目不被合并覆盖。


## 0.3.2 预览展示缓存与取样事务

主预览新增仅内存、最多 4 项且不超过 64 MiB 的 CGImage LRU；每帧每阶段仅保留一份完整参数快照。缓存键包含原片路径/大小/mtime/inode、frameID、校准、全部调色、方向、完整裁剪及阶段，和对应原片尺寸。打开/重开卷及手动清理缓存时清空。缩略图额外保存同等展示身份，匹配当前 Final 状态后才可用作主预览占位；其他阶段不借用 Final 缩略图。文件指纹变化不复用缓存。

切帧仍取消旧加载/渲染工作并验证修订，缓存与缩略图只是暂时展示，不成为取样或调色输入。精确操作在正式输入/预览准备好前禁用。正式结果直接替换占位并更新 LRU；缓存不上磁盘，不改变已有输入 LRU/GPU缓存和磁盘缩略图格式。首次载入中的缩略图若先完成，也可补上当前空白占位。

中性点取样使用有界原始邻域读取，异步结果校验卷、帧、加载修订、渲染修订、校准、调色和取消令牌，文件读取前后检测源指纹。成功通过既有单帧 edit 事务登记一次撤销并安排保存/缩略图刷新；不保存取样坐标、不新增项目字段。普通像素读数的任务/状态/API 已移除，底层原始像素读取仍供验证和其他内部用途。


## 0.3.3 Final 中性点事务

`NeutralTiming` 接收原片邻域、校准/调色快照、实际 LUT 和工作 ICC；`FinalColorimetry` 复用输出模块的 ICC matrix/TRC 解析，仅提供求解器测量，不改变渲染或导出。数值目标、上限和失败标准的唯一来源是 pipeline.md §15。

EditorModel 将求解放入 userInitiated detached task，父任务取消向后台传播；完成后再次校验整个取样上下文和源文件指纹，只有仍有效的结果可进入单帧 edit。内部可注入求解闭包用于确定性测试取消、后台隔离和求解期间源变更；应用默认始终使用真实核心求解器。

无新增持久字段或迁移；既有参数快照、Undo/Redo、自动保存和缓存身份继续适用。旧项目按原参数渲染，只有用户点吸管才写入新 Timing。交付独立 0.3.3 bundle，保留 0.3.2 及更早应用。


## 0.3.4 统一同步事务

EditorModel 的统一同步命令捕获 active 已提交设置与排除 active 的选中集合，预校验并构造项目副本后一次替换。调色和裁剪可独立或共同覆盖，共用一个撤销记录；裁剪转换使用来源真实 metadata，目标按各自尺寸适配。复制快照仍独立保存。浮层勾选仅为会话 UI 状态，每次打开清空，不写 JSON。算法、schema、几何版本不变。交互唯一来源见 interaction.md 的统一同步节。


## 0.3.5 矩阵库、校准快照与迁移

矩阵版使用 schema 4、`printroom-density-v3`，几何版本仍 2。`MatrixPreset` 包含稳定 UUID、名称与九项按行排列 Float32 系数；内置 identity/ledLightSource 仍保存固定字符串并由注册值解释，不能伪造同 ID 覆盖系数。`FilmCalibration.matrix` 与 `cmosMatrix` 是当前卷的独立完整快照；`sampledDensityMatrix` 和 `sampledCMOSMatrix` 保存最近成功对齐时的矩阵。baseRGB 是 CMOS 后逐像素取中位数的结果，允许大于 1；Gain/offset 与采样快照一起保存；应用矩阵时按 pipeline.md §6 原子更新。

本机库默认 `~/Library/Application Support/Printroom/matrices.json`，版本 1，按 CMOS/density 分类存自定义项，内置项不入库。新建/编辑/删除经文件协调、原子写入、当前内容对比防外部冲突；损坏或未来库版本明确报错并停止覆盖。每卷自带系数，库变更、删除、丢失或换电脑不改变已有项目。测试注入临时库目录，不写实际用户库。

schema 1/2/3 读取沿用旧密度选择作为 CMOS 与采样快照；较新项目若只保存 CMOS 或密度其中一侧，也复用已有值，只有两侧都缺失时才使用 Identity。其余已存 base/gain/offset、帧参数与输出保持不变。首次成功覆盖前沿用旧 schema/算法/几何的原 JSON 独占备份机制；读取本身不写文件。schema 3 应用不支持 schema 4。后续 RAW 结构可以在此基础上独立迁移。

CPU Prepared、Metal 参数、D1 缓存键与全部预览/缩略图/1:1/导出快照均包含两种当前矩阵；矩阵变化重算前段，普通 Timing/Contrast 继续复用。采样结果发布必须匹配卷和两种矩阵，矩阵切换取消在途采样。0.3.17 移除独立 L1 导出模式，ExportRequest 统一固定 Final 导出快照，无新增持久字段或项目迁移。

## 0.3.6 RAW 源与缓存

`SourceImageIO` 是输入边界：TIFF 直通 TIFFCodec，ARW 经 `RAWSourceService` 调用已安装 Adobe 和静态 LibRaw C++ 桥接。项目 schema 5，FrameRecord.rawProcessing 为可选的独立 RAW 策略快照；TIFF 默认 nil。frameID、filename、sourceSize/sourceModified 始终绑定卷内原始文件，缓存不参与卷发现。schema 1–4 沿用原子迁移备份，矩阵 schema 4 契约不变。

廉价处理身份包含源 stat 修订、Adobe 真实版本、LibRaw/策略/代理采样版本；不在主线程为缓存键解码或计算整文件 SHA。后台 manifest 另记录源内容 SHA256、有效尺寸及 DNG/各 TIFF 的完整性哈希。准备前后验证源修订和转换器版本，导出冻结同一处理身份。变更不丢弃调色，已保存的 RAW 校准来源处理身份变化时标记复核。

默认缓存位于 `~/Library/Caches/studio.printroom.local.v3.3/raw-v1`，上限8GiB、按最近访问淘汰。0.3.13 起仅1600/240代理与manifest持久化；DNG临时使用后删除，不生成full.tiff。RAW准备固定4路，不提供并行数设置。跨进程同源锁串行复用meta/代理/full请求，同源等待者不占4个准备槽位；digest缓存独立同步。源处理持共享缓存锁，清理/淘汰仅在所有活动读者释放后持独占锁执行，禁止锁升级；0.3.28起源读取完成即释放共享锁、同源锁与准备槽，结果返回不等待维护。维护在独立utility队列合并执行，仍持跨进程独占锁，正在使用的代理与staging不被删除。8GiB为异步淘汰目标，持续读取期间可暂时超限，读者结束后收敛；不再承诺仅超出当批4个源。显式清理仍等待独占锁并同步完成。最后消费者取消后终止生产者，临时目录原子发布，拒绝符号链接缓存。缓存清理只处理本服务拥有的摘要目录；不删除卷、项目或原片。

几何同步、缺失RAW重连和旧裁剪恢复需要RAW尺寸时在后台准备，提交前验证项目、选择和编辑上下文未变；TIFF同步事务保持原语义。精确图像读取经现有ImageService actor，导出经独立ExportEngine；不在EditorModel分散外部进程调用。


## 0.3.7 Adobe静默启动与预先准备

通过临时LSUIElement应用外壳启动已安装的Adobe，外壳只复制Info.plist并链接原二进制/Resources/Frameworks，不改Adobe安装内容，不引入新的去马赛克后端。外壳失败明确报错，不退回可见Adobe启动。原始Adobe版本仍参与处理身份，像素策略/schema不变。

RAWPrewarmer向服务保持最多4个未调色代理准备请求，当前帧排在前面，Filmstrip显示生成独立。切帧/换卷取消旧预备任务并按新当前帧重排；取消传入detached工作任务，不继续排入下一张。不在预备层持有全尺寸RGB，也不为预备写full.tiff。Final导出仍逐张渲染，准备层的4路上限不增加导出图像驻留。

## Sony CMOS 预设兼容

Sony A7C II 使用保留 UUID `6DA9259A-6676-48CF-AB02-9C3DBBE43762`，以完整系数对象持久化。旧 schema 5 读取器可按自定义快照保持像素；新读取器验证保留 ID 的名称和系数一致并识别为只读内置。原 Identity/LED 字符串编码保持。schema 5、算法 v3、矩阵库版本 1 不变，不自动给旧卷应用机型。

## 0.3.8 BigTIFF 读取

TIFFReader 在同一条带读取器中按文件头选择 classic / BigTIFF 的目录布局，使用 64 位文件地址并验证范围；metadata、预览、完整读取和 ROI 共用解析与样本处理。具体格式边界见 pipeline.md 的 BigTIFF 输入节。无需项目迁移或缓存版本变更，源文件与原始通道保持不变。


## 0.3.12 本机最近胶卷

RecentRolls 使用应用 UserDefaults 的 recentRolls.v1 保存目录规范路径、项目UUID和最近成功打开时间。应用注入 EditorModel，测试使用隔离suite或默认不注入，避免测试卷污染真实历史。记录在项目打开成功后更新，失败不新增；符号链接目录按解析路径去重。删除和撤销仅写本机偏好，不触碰卷。窗口异步检查目录可用性，恢复活动时重查。项目schema、图像算法及卷级/帧级设置结构不变。


## 0.3.13 RAW 代理缓存与瞬时导出

沿用raw-v1目录和既有代理身份，缓存命中不再依赖DNG。每次维护在跨进程独占缓存锁下，清除可解码manifest所属64位摘要目录中的普通source.dng/full.tiff，保留代理与陌生文件，不跟随符号链接；无需让所有代理失效。旧manifest中的DNG/full哈希字段兼容读取但不再用作缓存有效性条件。

导出在同源锁/四槽/共享缓存锁保护下创建UUID临时目录，重新运行Adobe、验证尺寸和源身份、解码为UInt16后直接返回，所有成功/失败出口清理临时DNG。已有崩溃临时目录恢复机制继续适用。8GiB上限与LRU沿用，维护后仅计代理文件。RAW日常采样及兼容性以pipeline.md末节为准。


## 0.3.15 缩略图移出胶卷目录

正式缩略图统一位于 `~/Library/Caches/studio.printroom.local.v3.3/thumbnails-v1/<namespace>/.printroom-cache/`。namespace为胶卷UUID与标准化目录路径组合的SHA256，隔离胶卷副本和不同卷上的相同inode。胶卷移动可以重建缓存，项目字段、源坐标、像素算法和JSON位置不变。现有512MiB/30天维护规则继续按胶卷作用；清理本卷只清理该namespace。

打开胶卷（包括无可用照片的卷）时，在缩略图后台任务中尝试迁移卷内旧`.printroom-cache`：只读取已知SHA256普通PNG，成功写入系统缓存后才unlink旧文件；迁移失败保留尚未迁移的旧文件，后续打开可重试，失败不阻断编辑。成功迁移的PNG保持16-bit显示数据及ICC。超过一天的已知临时文件可清理，新临时文件、陌生文件、损坏不可读PNG与符号链接保留；仅通过rmdir移除空目录，不递归删除残留内容。手动清理先尝试处理旧缓存再清系统缓存，重新生成继续写系统目录。系统路径祖先和旧缓存目录拒绝符号链接/普通文件替换。

不主动扫描未打开的磁盘和胶卷，也不删除原片、旁存设置、历史JSON迁移备份、用户导出。旧版本应用仍可能再次生成卷内缓存；新版下次打开继续迁移。


## 0.3.16 裁剪展示切换

EditorModel在裁剪进入、提交与取消前保留一份临时展示几何（尺寸、裁剪模式、草稿几何及已有细节图），原previewImage持续存在。CanvasView在替换期间按该几何绘制，延后cropViewportToken的视口复位；新渲染通过既有generation/context/frame校验后，同一主线程回合清除临时几何并发布图像。清空预览（包括切图）也清除临时状态，快速反复操作保留最初仍可见的几何。该状态只引用当前展示资源，不做图像重编码，不用于取样/导出或项目持久化；算法、schema与几何版本不变。

## 0.3.19 Timing界面偏好

`EditorModel.timingMode`从本机UserDefaults的`timingMode`读取（simple/rgb，缺省simple），切换即时保存；测试注入独立defaults。模式不进入胶卷、帧参数、复制/导出快照或撤销记录。`SimpleTimingAxis`在Core执行可逆坐标读取及受整数/边界约束的编辑，UI和快捷键均调用该转换，再通过原有edit事务提交。管线和项目格式不变，数值规范见pipeline.md。


## 0.3.20 逐帧 LUT

项目 schema 6 在 FrameAdjustments 新增 cineonLogLUT，稳定值 kodak2383 / fujifilm3513DI。schema 1–5 读取缺失字段时补 kodak2383，旧画面保持；未知值拒绝读取。首次覆盖旧 schema 前沿用 ProjectStore 原始 JSON 备份机制，schema 5 使用 `.printroom-schema5-UUID.json`。旧应用不支持 schema 6，不应交替编辑。算法仍 printroom-density-v3、几何版本 2。

AppAssets 校验并预载两份 LUT，CPU/Metal 继续接收明确 LUT 实例。导出快照固定逐帧选择，批量逐帧解析对应 LUT；缺少所选 LUT 明确失败。主预览/缩略图/1:1 的 FrameAdjustments 身份包含选择，磁盘缩略图另包含所选 LUT 哈希。NeutralSolver 使用取样启动时当前帧所选 LUT，帧参数变化使旧请求失效。


## 0.3.21 导出命名

ExportFrameSnapshot 在筛选前捕获 project.frames 的一基编号；ExportRequest 固定可选 filenamePrefix，应用三个入口统一传入。前缀为对话框局部草稿，不写入项目，命名交互以 interaction.md 为准。旧项目已存 compression 原样读取；新建输出设置默认 deflate，对话框每次默认 ZIP。schema、算法和像素契约保持。底层独立调用者仍可指定完整目标路径。


## 历史：0.3.22 LUT 白点准备与算法迁移（0.3.27 已移除）

AppAssets 在校验 LUT/ICC 哈希后为所有可选 LUT 调用 `neutralizingWhite`；CubeLUT 持有不可变原格点与派生 `neutralWhiteShift`，`sample` 为原始插值，`sampleFinal` 为实际 Final 入口。派生偏移不写入项目或 Timing，契约见 pipeline.md。算法版本 v4 纳入现有缩略图身份；内存缓存随应用进程重建。

项目仍为 schema6，v1/v2/v3 读取时迁移 v4，帧参数不补偿。首次保存沿用冲突检查与原子写入：v1 使用原有密度备份；旧schema使用原有schema备份；同schema旧算法保存 `.printroom-density-vN-UUID.json` 原字节备份，然后才覆盖。备份失败中止保存。v4快照拒绝旧算法快照；旧应用拒绝新算法项目。


## 0.3.27 白点移除与定向补偿

AppAssets只校验并读取原始cube，不再准备白点偏移，CubeLUT只保留原始格点与sample。算法升级v5，支持v1–v4项目按现有规则迁移，默认不修改任何Timing；同schema旧算法首次保存备份原JSON，v4为`.printroom-density-v4-UUID.json`。算法身份使旧缩略图失效；旧版应用拒绝新算法设置。

独立 `scripts/white-removal-compensation.sh` / `WhiteRemovalCompensation.swift` 只接受明确传入的卷路径，prepare生成原JSON快照、替换JSON及逐帧误差报告，读取已有RAW代理验证输出，不触发RAW转换。apply要求Printroom退出，并核验所有原文件和候选SHA；逐卷在NSFileCoordinator写协调中重验源字节，先独占保存`.printroom-before-white-removal-UUID.json`，再原子替换并回读校验。仅写Timing、algorithmVersion与updatedAt，其他JSON字段保持；v5拒绝再次补偿。两卷按顺序独立提交，任一失败停止并报告已完成卷，不能声称跨目录原子事务。

## 0.3.31 相纸 LUT 注册与导出

CineonLogLUT 增加五个稳定 DiVERE 相纸枚举值，路径与SHA固定。AppAssets 在初始化时验证并加载全部注册表；预览、缩略图、吸管通过同一选择查表。ExportEngine 接收只读 LUT 字典，未知/缺少新增 LUT 明确失败，不能回退 Kodak 或 Fuji。运行任务继续使用帧选择快照。

schema 6 与算法 v5 保持：仅扩展已存在的逐帧枚举，旧应用遇到新枚举会拒绝解码，不会默认为旧 LUT 并覆盖。只用原有 LUT 的项目行为保持。新选项继承复制、重置、同步、撤销和缓存身份；转换策略见 pipeline.md §8。派生表在随包 Assets/assets/DerivedLUTs，MIT源材料及许可证随包提供。


## 0.3.32 相纸曝光定位版本

五个相纸选择保留帧枚举与菜单名称，注册资源更新为DerivedLUTs/gray2383-neutral-v3和新SHA，策略为divere-paper-gray2383-neutral-v3。schema6及密度算法v5保持；按用户要求，已有相纸帧也采用统一且中性的中灰定位，存储Timing不修改。缓存身份包含LUT SHA，不复用旧表缩略图。旧应用仍带旧表，不用于本轮外观验收；当前包只打包v3，源码保留历史派生表。偏移仅烘焙进新增相纸资源，不增加运行时偏移字段或全局校正器。


## 0.3.33 已移除相纸选择的兼容

当前枚举仅Kodak2383/Fujifilm3513DI。解码时只将五个明确的历史divere标识映射为默认Kodak2383；其他未知标识继续报错。读取不立即写磁盘；首次覆盖含历史标识的项目时，沿既有文件协调/冲突检查流程独占写入`.printroom-retired-paper-luts-UUID.json`原字节备份，失败则停止保存。再次保存不重复备份。帧Timing/Contrast/裁剪等字段保持，缩略图选择和SHA改变后重建。schema6和密度算法v5不变；这是撤销资源的显式兼容策略，不修改两个保留LUT的算法。


## 0.3.34 统一磁盘缓存策略（取代上述固定限额）

Core的DiskCachePolicy在UserDefaults保存diskCacheLimitGB/diskCacheRetentionDays；数值和交互以interaction.md为准。ManagedDiskCache仅扫描固定系统缓存根下raw-v1的64位摘要目录，以及thumbnails-v1摘要namespace下.printroom-cache中的摘要普通PNG。两类已提交缓存共用总字节预算，按最后使用时间全局LRU和TTL删除；不计内存缓存、锁文件和活动staging。缩略图命中更新PNG修改时间，RAW命中更新条目目录修改时间。

正式默认RAWSourceService在原有独占跨进程锁内执行统一维护；读取/转换仍持共享锁，结果先返回。正式DiskThumbnailCache停用每卷512MiB/30天限额，写入后请求同一后台合并维护，仍回收一天前的已知缩略图临时文件。注入的测试目录保留原独立限额行为。应用启动、运行每小时、缓存写入/RAW读取以及策略改变时请求维护；持续RAW活动可暂时超限，空闲后收敛。窗口后台统计每2秒刷新，不等待锁。仅扫描本机已迁移系统缓存，不主动扫描未打开的胶卷；旧卷缓存沿原打开迁移流程进入管理。缓存不可用可重建，原片、项目、导出、算法v5和schema6保持。


## 0.3.35 RAW 磁盘缓存快速命中

已有代理按完整 FileRevision（大小、inode、设备号、mtime/ctime 秒及纳秒）和 Adobe/LibRaw/策略/代理版本生成带 stat-cache-v1 域标记的目录摘要。命中时不读取原片内容；读取前后继续验证源修订及转换器版本，并完整验证两个代理的 SHA256。仅缓存缺失或损坏需重建时计算原片 SHA256，manifest 保留该值。此节取代缓存定位必须先计算原片全文 SHA 的实现，像素、处理身份和项目版本保持。

首次遇到旧内容摘要目录时，在现有同源锁和缓存共享锁内查找匹配 manifest，核对旧目录摘要及两个代理 SHA 后将目录移至新身份位置；不转换、不改写代理。后续启动直接定位。目录和 manifest/代理拒绝符号链接，统一缓存管理仍识别64位摘要目录。变化、缺失、损坏均回到既有重建路径，四路准备及异步维护保持。快速路径依赖文件系统正确更新 stat 修订；不宣称检测所有元数据均被底层还原的内容变更。


## 0.3.36 烘焙 LUT 与偏置回补

AppAssets按CineonLogLUT.path/sha256加载两份diffuse-white-v1派生表；原始ProjectAssetIdentity继续作为原LUT与ICC来源身份，派生表身份由选择注册项及算法v6明确绑定。CubeLUT、CPU、Metal和吸管仍直接采样，无白点运行时字段。构建脚本打包派生表与manifest。项目v1–v5按既有规则迁移v6、保留参数，首次保存前原字节备份；v5软件拒绝v6项目，缓存按算法与LUT SHA失效。

独立WhiteRestoreCompensation只应用已准备且SHA固定的两卷计划，要求应用退出，全部候选预检后逐卷文件协调、复核源、独占备份、原子替换和回读。备份为`.printroom-before-white-restore-UUID.json`。之后以正式ProjectStore重新打开核验。算法已为v6时不能重新准备，避免重复扣回；跨卷不是单一事务。


## 0.3.37 RAW 缓存命中不触发全库维护

取代0.3.34中每次RAW读取均请求维护的触发规则。普通metadata、preview、region命中只更新访问时间，不请求独占缓存锁及全库扫描；全尺寸导出仅有临时文件，也不因读取请求维护。新增代理发布或旧目录迁移成功后请求异步维护，应用启动、每小时、缩略图维护与策略修改继续请求维护。预算、TTL、活动读者保护、同源互斥及四路限制保持。显式clearCache行为保持。测试/工具中改变独立服务的容量后，需要显式scheduleMaintenance以执行新策略。
