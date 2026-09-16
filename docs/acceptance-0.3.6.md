# 0.3.6 RAW 验收（2026-09-09）

## 范围与环境

在同工作区0.3.5双矩阵实现上增量接入RAW；不把矩阵功能归为RAW新增成果。输入为Sony ILCE-7CM2的DSC07119–DSC07126八张ARW，Adobe DNG Converter 18.1.1 (2422)、官方LibRaw0.22.1源码静态构建、Apple Silicon/macOS 26.6.2。输出数值契约以pipeline.md为准。

本记录验证RGB与给定open-make-tiff源码的转换模块一致，不宣称未知旧版安装应用的全部元数据、ICC外观或其他机型已获验收。历史研究见raw-adobe-study-2026-09-09.md/json。

## 已执行证据

- `scripts/verify-libraw-source.sh scratch/raw-adobe-study/LibRaw-0.22.1.tar.gz`：官方归档SHA256和vendored源码逐文件一致，CDDL及源码随包分发。
- `scripts/test-raw-integration.sh`：release真实Adobe→SourceImageIO代理/精确图像→ExportEngine。4项native测试及1项综合集成通过；八张7008×4672完整RGB的小端UInt16 SHA256与独立源码参考完全一致，共785,793,024通道样本，最大误差0。1600 nearest代理、原始ROI、CPU/Metal同参处理和八帧裁剪导出对照均通过，最终ICC精确嵌入。
- `PRINTROOM_TEST_REAL_RAW=1 PRINTROOM_VALIDATE_RAW=1 scripts/test.sh --filter 'RAWEditorIntegrationTests|RAWGeometryTests|RAWImageServiceTests|CropEditingTests|EditorRefinementTests'`：23项通过；真实两张ARW打开/快速切帧/保存重开、处理身份及尺寸，真实原始片基/ROI/八方向，与旧TIFF裁剪及吸管回归。确定性RAW几何事务另覆盖后台等待时改参数和替换源，过期结果不提交。
- `RAWSourceServiceTests`：9项通过，覆盖身份读取不触发转换、独立两档代理不先生成full、精确ROI、冻结版本拒绝、缺Adobe/转换失败/CFA输出/源变化无fallback、损坏缓存重建、容量淘汰、symlink与不可写路径、共享请求与取消、跨实例锁、清理后重建以及真实Process非零/缺输出/取消。
- 项目schema5兼容1–4，RAW发现、移动、缺失重连、稳定frameID及源修订失效由RAWProjectTests和ProjectMigrationRelocationTests覆盖。原项目JSON首次覆盖前备份；新源字段不改变TIFF数值。

日志保留在scratch/raw-editor-integration-tests.log、raw-service-isolated-test.log、raw-integration-tests.log；可再生临时输出允许按工作区规则清理。核心数值与性能数据另保留在本版JSON。

## 实测性能

首次代理与首次精确操作为每张新复制原片的正式缓存路径，串行准备；使用release构建。八张首次代理1.470–1.578秒，磁盘proxy命中0.104–0.118秒；首次全尺寸ROI0.267–0.302秒，缓存完整读取0.020–0.022秒。1600/240代理均从同次完整解码分别取样。

单张7008×4672 CPU Final导出1.370秒；八张小裁剪批导0.397秒，这不是全尺寸整卷时间。综合测试进程峰值RSS1,642,577,920字节，包含完整参考比较和GPU缓冲，不能当作单纯应用内存。最终全尺寸整卷/真实窗口/包验证结果在下节追加。

## 发现并修复

真实后台首次导入曾SIGBUS：LibRaw约768KiB局部对象超过GCD约512KiB栈。metadata/decode改为unique_ptr堆分配；新增真实DispatchQueue完整解码/hash回归，并重跑真实编辑器与集成测试全部通过。只在主线程运行的原生哈希验证不覆盖该条件。

首次全回归还暴露并修正矩阵新增阶段的旧测试数组长度、旧schema模拟夹具和当前TEST/TIFF资产路径；原始资产及其哈希保持。高负载并发测试有一次旧裁剪8秒等待超时，定向重跑通过；最终收敛回归单独记录，初次失败不计为通过。

## 边界

仅八张当前Sony ARW实测。没有执行120秒真实超时等待、进程被强杀后的掉电模拟、磁盘实际写满、其他机型/旧macOS/Intel实机验收。超时与清理有实现；失败或缺Adobe不回退。用户视觉偏好仍以实际使用确认为准，数值一致不替代审美验收。

## 最终收敛与交付验证

- `scripts/test.sh --full` 最终收敛回归：164项核心测试，3项按环境开关跳过、0失败；88项Swift Testing应用测试、0失败。日志scratch/raw-final-regression.log。真实RAW opt-in已单独执行，不以默认跳过代替通过。
- 收尾新增后台几何任务取消传播：切帧/换卷取消内部worker、不继续下一张、不提交旧结果，4测试/5用例全部通过（scratch/raw-geometry-cancellation-tests.log）。相应准备状态显示在临时操作栏。
- 服务最终10项通过，新增实际崩溃遗留合法UUID暂存目录清理；非法名/文件/symlink不删除，持跨进程锁清理失败则停止准备。
- 八张全尺寸整卷导出补测：CPU参考、无压缩P3，缓存全尺寸已准备，串行18.624秒；8/8尺寸7008×4672且ICC精确匹配。该独立测试导出后、回读验证前峰值RSS804,765,696字节（约767.5MiB）。共享缓存4,246,195,949字节/8GiB上限，含其他测试条目，非仅这卷。数据见raw-full-roll-0.3.6.json。
- `scripts/raw-window-qa.sh` 真实1060×720编辑窗口通过，显示ARW文件名、7008×4672、正式预览和Filmstrip；截图scratch/raw-window-qa/editor.png已目视检查。原始无片基校准画面保持原输入方向与数值，不替用户自动调色。单独运行已编译窗口驱动，热缓存1.31秒完成（含固定500ms截图等待），最大RSS566,132,736字节；该数值不是冷导入耗时或全功能峰值。
- `shasum -a 256 -c assets/SHA256SUMS` 12/12通过，`assets/RAW-SHA256SUMS` 8/8通过。资产清单仅从旧TEST根同步到用户当前TEST/TIFF位置，没有重生成哈希或原片。
- 重新开卷会廉价检查片基来源RAW处理身份；转换器/策略变化或不可用时标记复核，恢复旧设置也比较RAW处理快照。最终收口后真实RAW编辑器、几何取消与既有EditorIntegrationTests合计15项再次通过（scratch/raw-final-editor-check.log）。
- 最终 `scripts/build-app.sh` 成功交付 `output/Printroom.app`，版本0.3.6/1、标识`studio.printroom.local.v3.3`。包内ICC/LUT、四输出profile、实际Metal渲染和SDR预览冒烟通过；`codesign --verify --deep --strict`通过。包内LibRaw源码/许可与ThirdParty目录逐文件一致；`otool -L`仅系统库/框架，无rawpy、Siril、Python、scratch或外部LibRaw dylib依赖。新包验证成功后替换旧包，日志scratch/raw-build-app.log。最终20个原始资产哈希再次全部通过。
