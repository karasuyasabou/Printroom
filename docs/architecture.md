# 架构与项目数据

状态：0.1.0 已使用 Swift Package 实现核心与 SwiftUI 应用；构建脚本生成原生 `.app`，没有 `.xcodeproj`。公式见 [pipeline.md](pipeline.md)，交互见 [interaction.md](interaction.md)。以下为设计契约，文末列出本版实际映射与边界。

## 模块边界

| 模块 | 责任与边界 |
| --- | --- |
| PrintroomApp / EditorView | SwiftUI 生命周期、预览/面板/Filmstrip；不直接实现公式或读写 TIFF |
| ProjectDocument / ProjectStore | RollProject、FrameRecord、版本迁移、原子保存、文件协调 |
| PipelineCore / PipelineReference | 无 UI、无显示转换的 Float32 CPU 核心，阶段纯函数、参数校验、数值诊断；拟用本地 Swift Package |
| MetalRenderer | 与 CPU 相同阶段和 LUT 插值，纹理/缓冲区管理、取消和最新预览提交 |
| TIFFImporter | 解码原始 UInt16 RGB、metadata/orientation；禁止隐式 ICC 转换 |
| ColorManagement | 原始 profile 记录、最终输出与显示器转换、导出 profile 解析 |
| TIFFExporter | 输出 profile 转换后的样本量化、16-bit 写入、ICC 嵌入、无覆盖发布 |
| ThumbnailCache | 可再生的最终外观缩略图、缓存身份、过期与清理 |
| Diagnostics | 阶段值/域外计数/计时/错误，不能将原图上传或记录整幅像素日志 |

UI 只通过模型命令修改参数；渲染接收不可变 `RenderRequest`。CPU 参考独立于 Metal，作为算法对照，不能为通过测试而直接调用 GPU 代码。框架选择暂定 ImageIO/ColorSync，但必须实测能保持原始 TIFF 样本；若不能，再选择可控的解码实现并记录原因。

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

`schemaVersion=1`，`algorithmVersion="printroom-density-v1"`。项目至少含：

| 字段组 | 数据与约束 |
| --- | --- |
| identity | rollID（UUID）、创建/更新时间、schemaVersion、algorithmVersion |
| assets | LUT 与工作 ICC 的相对引用、SHA-256；矩阵标识由算法注册表解释 |
| inputInterpretation | primaries=P3-D65、transfer=linear、policy=assignPreserveSamples |
| calibration | 状态、来源 frameID、整数选区/坐标空间/尺寸、baseRGB、gainRGB、filmBaseOffsetCV、printDensityMatrix |
| frames | frameID→FrameRecord 映射，记录相对路径、源文件指纹、Timing、Contrast；不使用数组下标作为 ID |
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
- 普通滑块编辑自动保存防抖默认 300 ms；滑块结束、数值提交、批量应用、校准/矩阵变更后立即安排保存。
- 临时文件写在项目同一目录，完整编码成功后原子替换 `.printroom.json`；中途失败不得留下截断的正式项目文件。
- “参数已应用”与“项目已保存”是不同状态。保存失败保留 dirty 状态、重试入口和内存数据。
- 切换卷或正常退出时等待最后保存；失败时提供重试、另存项目或用户明确放弃未保存内容的选择。
- 只读目录可编辑预览，但明确不能旁存；提供另存项目。权限变化后重试，不悄悄把项目放到不可发现的位置。
- 同一应用实例内，同一卷复用会话；外部项目修改通过文件协调及保存前版本/修改标记检测，冲突时停止覆盖并提示重新载入或另存副本。首版不自动合并两套调色。
- 不保存缩略图像素到 JSON；缓存状态可提示但不能作为业务真相。

## 预览、缓存与资源使用

每个渲染请求包含 frameID、源修订、卷参数修订、帧参数修订、阶段及资产哈希。用户切图或调参后取消旧请求；只有匹配最新请求的结果能提交到 UI。直方图/读数遵守相同身份检查。

参考单帧 7008×4672；RGB Float32 约 393 MB（375 MiB），RGBA Float32 约 524 MB（500 MiB）。不得同时常驻全部 10 张的全分辨率阶段图。默认按需加载当前帧、低分辨率异步预览、有限 LRU 缓存；片基采样读取原始像素；全尺寸导出分块处理。全尺寸 CPU 参考可慢，但数值行为必须一致。

缩略图缓存身份包括源指纹、算法版本、卷校准与矩阵、帧参数、LUT/ICC 哈希、尺寸与显示策略。缓存存储带明确 profile 的最终外观缩略图，不缓存依赖某台显示器 profile 的最终设备值。显示器变化重新显示转换；缓存可丢弃重建。

## 工具链与构建落地

工程使用 macOS 14+、arm64、Swift 6、系统框架与本地 Swift Package，已创建 app/test targets 和可重复脚本。Swift 并发隔离、Metal 数值路径、原始样本保真与输出回读已在当前机器测试；旧系统兼容、更多显示设备与独立多 profile 导出转换仍在后续范围。

## 0.1.0 实际落地

- `Sources/PrintroomCore`：Contracts、CPU Pipeline、MetalPipeline、TIFFCodec、RollProject/ProjectStore/SelectionState/ParameterSnapshot。
- `Sources/PrintroomApp`：EditorModel、SwiftUI EditorView、AppKit PreviewCanvas、ImageService actor、DisplayImage/AppAssets、App 生命周期。
- 核心用 XCTest，异步 UI 模型集成使用 Swift Testing；命令在 README 与 `scripts/test.sh`，打包入口为 `scripts/build-app.sh`。
- TIFF 解码采用自有 classic TIFF 条带解析及系统 zlib，绕过隐式 ICC 转换。GPU 通过 Float32 buffer 运行完整管线，CGImage 携带 ICC 交给系统显示；全尺寸导出复用 GPU 算法并由编码器分块请求样本。
- 项目已编码 inputInterpretation、assets、exportSettings、calibration、calibrationNeedsReview、frames 与 lastActiveFrameID，数组元素使用稳定 UUID。排序为确定的自然文件名顺序，暂无手动排序 UI。
- 打开项目的修改时间令牌在与 JSON 相同的文件协调读操作内捕获，保存检查此令牌，避免读完再取新令牌导致覆盖他人修改。
- 源缓存使用新鲜文件系统属性比较尺寸/修改时间；重开卷清空内存缩略图源，磁盘缓存键包含文件、参数、算法、ICC/LUT 和尺寸身份。暂不做周期磁盘缓存清理。
- 保存冲突可另存经版本化的本卷 JSON 设置副本，再通过 File 菜单恢复；也可明确放弃未保存修改后重新载入。设置副本禁止直接覆盖当前项目，恢复需匹配卷 ID 并再次执行冲突检查。
- 缺失条目保留设置、原名重现可恢复；未实现改名后的手动重连界面。项目文件之外的独立恢复副本不改变原始 TIFF。
- 本版是本地 ad-hoc 签名应用，没有 App Sandbox/商店签名配置。macOS 14 部署目标未进行旧系统实机验收。
