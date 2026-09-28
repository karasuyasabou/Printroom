# Printroom

0.3.68 新增默认勾选的“裁剪预览”，关闭显示完整画面，直方图仍按保存的裁剪统计；见 [验收记录](docs/acceptance-0.3.68.md)。

0.3.67 统一“裁剪”用语，顶部自动裁剪与预览裁剪按钮共用 `crop` 图标；见 [验收记录](docs/acceptance-0.3.67.md)。

0.3.66 精简导出设置：删除恢复胶卷名按钮，ZIP 压缩改为复选框，新增应用裁剪，均初始勾选并按卷记忆。关闭裁剪导出完整画面，保留独立旋转/翻转；见 [验收记录](docs/acceptance-0.3.66.md)。

0.3.65 将卷名从品牌下方移到工具栏独立标题，使用更清晰的字重；见 [验收记录](docs/acceptance-0.3.65.md)。

0.3.64 新增胶卷命名与独立导出设置窗口。默认导出前缀跟随胶卷名，目的地和输出选项按卷记忆；见 [验收记录](docs/acceptance-0.3.64.md)。

macOS 原生负片调色工具。一个文件夹是一卷底片；保持 16-bit TIFF 原始样本，卷级片基校准、逐帧调色，可逐帧选择 Kodak 2383 或 Fujifilm 3513DI Cineon Log LUT 输出。

**当前交付：0.3.68（构建 1）。** 移除Filmstrip缩略图右下角已编辑黄点，见[验收记录](docs/acceptance-0.3.63.md)。 色罩分析统一使用整卷第一张照片所选LUT，应用时同时覆盖LUT，保留已调色与整组撤销语义保持，见[验收记录](docs/acceptance-0.3.62.md)。 自动裁剪必须指定画幅比例，默认3:2，支持常用预设、自定义与交换宽高，取消自动识别比例；比例参与模板尺寸判断，见[验收记录](docs/acceptance-0.3.61.md)。 调色按钮字体缩小、矩阵下拉等宽，01/02增加纵向留白，见[验收记录](docs/acceptance-0.3.60.md)。 方向菜单已替换为左旋、右旋、水平翻转、垂直翻转四个图标，见[验收记录](docs/acceptance-0.3.59.md)。 浅色面板与Canvas按最新指定明度更新。 直方图半透明并补齐绘图区外框、矩阵改为两行、调色标签与数字框统一对齐，见[验收记录](docs/acceptance-0.3.58.md)。 原生 unified Toolbar 将红黄绿、品牌和主操作合为一行；浅色按指定中性白灰色板，深色颜色保持。见[验收记录](docs/acceptance-0.3.57.md)。顶部“外观”菜单切换并记忆浅色／深色。 导出重名先询问是否覆盖，仅选否才自动重命名；清理同类说明小字。见[验收记录](docs/acceptance-0.3.54.md)。 新卷和旧卷统一显示“正在加载”及张数进度，整卷 RAW 代理全部准备成功后才进入编辑并启动缩略图；缺失或损坏缓存自动补齐。见[验收记录](docs/acceptance-0.3.53.md)。 打开文件夹仅留主页，自动裁剪和色罩分析集中到顶部；导出支持16-bit TIFF / 8-bit JPG，见[验收记录](docs/acceptance-0.3.52.md)。 批量TIFF导出最多四张同时处理，覆盖RAW解码、调色、ICC转换、ZIP压缩与写盘；验证和内存边界见[验收记录](docs/acceptance-0.3.51.md)。 新增整卷自动调色：顶部色罩分析入口经确认后分析整卷裁后画面，P95对齐685 CV并求共同RGB Timing；完成后显示整卷 RGB Timing 结果，可勾选“保留已调色”（默认不勾选），一次应用/撤销。必须先完成有效片基对齐，见[验收记录](docs/acceptance-0.3.50.md)。 导出色彩空间与 LRC 截图的五个名称及顺序对齐，新增 Display P3 / Rec. 2020 的真实 ICC 转换，见 [验收记录](docs/acceptance-0.3.49.md)。 自动裁剪尺寸与定位共用片基支持的边界评分，固定片基参考、可信候选起点并约束定位范围，修正弱画面边缘被片基外沿拉偏；尺寸算法、内收和检查阈值保持。验证范围见 [验收记录](docs/acceptance-0.3.48.md)。 新卷默认 Sony A7C II／LED Light Source，关闭主窗口退出软件，自动裁剪默认不保留已有裁剪且每边内收1%；见 [验收记录](docs/acceptance-0.3.46.md)。 画布默认箭头、拖动时抓手；悬停照片时，直方图显示0.8%长边邻域RGB中位数标记，见 [验收记录](docs/acceptance-0.3.45.md)。 已移除 Neutral LUT，见 [验收记录](docs/acceptance-0.3.44.md)。 自动裁剪设置对话框、内收比例、自动检查流程及首尾四边判定见 [验收记录](docs/acceptance-0.3.40.md)。整卷自动裁剪和自由裁剪比例的初版见 [0.3.39 验收记录](docs/acceptance-0.3.39.md)。裁剪模式新增 Q/E 调角度，见 [验收记录](docs/acceptance-0.3.38.md)。 已缓存 RAW 切图不再逐次触发全库清理，减少读取锁等待；真实六帧测试及边界见 [验收记录](docs/acceptance-0.3.37.md)。 两份电影 LUT 已直接烘焙 685 CV 漫反射白中性对齐；运行时仍为 D3 直接查表，两卷既有 RGB 偏置已按历史记录反向扣回，见 [验收记录](docs/acceptance-0.3.36.md)。 RAW 已缓存照片首次打开按文件身份直接读取代理，跳过原片全文 SHA；兼容旧缓存并保留代理完整性校验，见 [验收记录](docs/acceptance-0.3.35.md)。 主页新增“管理缓存”次级入口，移除缓存窗口底部说明小字。 File 新增“管理缓存”，统一设置缩略图和 RAW 缓存总上限与过期时间，移除顶部三个点菜单；见 [验收记录](docs/acceptance-0.3.34.md)。 已移除五个相纸LUT，仅保留 Kodak 2383 / Fujifilm 3513DI；旧相纸选择兼容与验证见 [验收记录](docs/acceptance-0.3.33.md)。 LUT选择和框选片基移至各自标题右侧，小幅收紧调色面板间距，显示效果待用户验收。 RAW代理完成即返回，缓存清理改为后台合并执行，继续固定4路准备。 已移除自动LUT白点校正，恢复D3直接查原始LUT。 直方图移除统计弹窗，收起／展开按钮置于右上角，独立切换 Density / Final，默认 Final，始终叠加 RGB。 直方图自动纵轴使用P90 × 4上限，减少截顶，保留其余峰的线性比例。 简易模式数值显示为整数，所有调色长按快捷键连续速率减半。 裁剪模式中点击缩略图或左右切图保持模式，新照片使用自己的裁剪设置；切换前自动提交并保存上一张裁剪。 导出默认 ZIP，支持文件名前缀，自动追加胶卷原编号（如 `假日-02.tiff`），单独导出保持编号。 新增 Cineon Log LUT 面板，默认 Kodak 2383，可选 Fujifilm 3513DI；同步拆为 RGB Timing、RGB Contrast、Cineon Log LUT、裁剪四项。 Timing 新增简易 / RGB 切换，简易提供曝光、色温、色调；模式本机记忆，切图、切卷和重启保持。简易 W/S 调曝光、Q/E 调冷暖、A/D 调绿/洋红，Z/C无作用；所有Option反差快捷键保持原样。切换只改变界面，图片参数不变。 Filmstrip 右键新增按选中数量显示的水平/垂直翻转、顺/逆时针旋转，整组一次撤销。 移除独立 CMOS 校正 TIFF 导出。 裁剪工具栏原位替换，复用固定预览画布；进入、完成与取消保留旧画面至新图就绪。 缩略图统一存入系统缓存，打开胶卷时迁移旧缓存。 预览工具栏统一样式，管线预览仅保留线性、密度、输出，缩放合并为适应/100%。 RAW日常仅用代理，DNG用完删除，导出时才重新解码全尺寸。 欢迎页与文件菜单提供最近胶卷，支持单击恢复、单条移除/撤销和缺失目录重新定位。 直方图支持收起/展开并记住本机状态。 欢迎页移除两行说明，照片预览底色为 sRGB（72，72，72，`#484848`），附深灰香槟金相纸图标。 新增 BigTIFF 条带输入，完整读取、预览和局部取样共用原始样本解码。 ARW 默认 Adobe 静默运行、固定4路准备。Adobe 去马赛克，小尺寸线性代理供编辑与取样，全尺寸像素仅供实际导出，不存中间 TIFF；八张 Sony A7C II 样片与参考转换 RGB 完全一致。 新增双矩阵与本机矩阵库：CMOS 从三张 TIFF / ARW 制作，内置只读 Sony A7C II，密度矩阵手动输入；01 标题右侧“管理…”分别管理两类矩阵，左 CMOS、右密度选择。应用矩阵自动沿已存片基选区重新对齐，矩阵与校准一次撤销，失败保留原状态。 同步统一位于 Filmstrip 上方，浮层每次默认全不勾选，可把当前照片的调色、裁剪或两者应用到其余选中照片，一次撤销。 直方图更新保留旧图，密度横轴显示 CV 与参考刻度；中性点吸管自动调整 RGB Timing，使 LUT 后 Final 接近中性并尽量保持最终亮度；后台求解，无合格解保留原参数。窗口统一调色快捷键，Option 调对应反差；切帧先显示匹配缓存再替换正式预览。裁剪与精细角度按原片坐标保存，多选同步保留每帧方向；⌘/Shift 扩选保持当前照片与草稿。直接LUT算法 `printroom-density-v6`（685 CV pivot），几何版本 2，项目 schema 8；旧裁剪按原画面迁移，首次覆盖前备份原设置。

## 运行与构建

0.3.43：中性点吸管按原片长边0.8%取方形邻域，TIFF/RAW共用未调色预览采样，见 [验收记录](docs/acceptance-0.3.43.md)。

0.3.42：Filmstrip 与右侧调色面板改为自动隐藏浮动滚动条，修正 Filmstrip 高度挤压。macOS 27 验证见 [验收记录](docs/acceptance-0.3.42.md)。

应用包：[Printroom.app](output/Printroom.app)，当前版本 0.3.68、构建号 1。自动裁剪设置与检查流程见 [验收记录](docs/acceptance-0.3.40.md)。每次打包验证成功后覆盖此路径，名称不加版本后缀；应用标识保持固定，沿用当前偏好设置。本地 Apple Silicon 应用附带 ICC/LUT，无需 Photoshop 或额外运行库。用户已手动验证 0.3.68 的全部功能；私有仓库只保存源码与开发资产，应用包和参考照片不入库。

```sh
scripts/build-app.sh              # release 构建、资源打包、ad-hoc 签名
scripts/test.sh                   # 算法、模型、TIFF、输出、异步 UI 集成
scripts/test.sh --full            # 十张实际 TIFF / 全尺寸导出 / Metal
scripts/measure-performance.sh    # release 预览性能与内存记录
scripts/measure-adjustments.sh    # release 调参准备耗时、连续出图与最终收敛
scripts/measure-performance.sh --export # 两帧全尺寸批导性能
scripts/measure-export-concurrency.sh ROLL NEW_OUTPUT CONCURRENCY FIRST_FRAME COUNT # 真实卷1/4路对比
scripts/viewport-window-qa.sh --release # 真实窗口的视口回归
bash scripts/crop-window-qa.sh --release # 裁剪窗口/快捷键/多选同步截图回归
bash scripts/editor-window-qa.sh --release --window-chrome # 原生窗口顶部、主题及全屏/最小化往返
bash scripts/editor-window-qa.sh --release # 最小窗口、D3刻度、吸管与顶部临时状态截图
bash scripts/editor-window-qa.sh --release --skip-build --keyboard # 自有窗口键鼠回归
bash scripts/editor-window-qa.sh --release --timing # 两种Timing最小窗口与固定布局
bash scripts/editor-window-qa.sh --release --scrollbars # 浮动滚动条与Filmstrip高度
bash scripts/matrix-window-qa.sh # 双矩阵、分类管理浮层与弹窗截图
shasum -a 256 -c assets/SHA256SUMS
```

SwiftPM 项目，可在 Xcode 打开 `Package.swift`。部署目标 macOS 14+、arm64；当前实测 Apple M4 / macOS 26.6.2 / Xcode 26.6 / Swift 6.3.3。旧系统、Intel、更多显示器仍未实机验收。窗口截图需要本机图形会话与系统截图权限。

## RAW 依赖与验证

ARW 去马赛克必须安装 `/Applications/Adobe DNG Converter.app`（本机验收18.1.1）。缺失或失败明确报错，不回退其他RAW后端；原有TIFF无需Adobe。正式应用静态构建固定LibRaw0.22.1，附CDDL源码/许可证，不需要Python、Go、rawpy或其他照片应用。首次代理仍包含全尺寸去马赛克，缓存使用 File → 管理缓存中的统一异步淘汰目标。其他机型尚未实测，首版只开放ARW扩展名。

```sh
scripts/test-raw-integration.sh   # 八张真实Adobe/正式解码/全尺寸与批导，需保留研究参考TIFF
PRINTROOM_TEST_REAL_RAW=1 PRINTROOM_VALIDATE_RAW=1 scripts/test.sh --filter 'RAWEditorIntegrationTests|RAWImageServiceTests'
scripts/raw-window-qa.sh         # scratch副本的真实RAW窗口截图
shasum -a 256 -c assets/RAW-SHA256SUMS
```

静默和四路准备验证见 [0.3.7验收记录](docs/acceptance-0.3.7.md)，RAW数值基线见 [0.3.6验收记录](docs/acceptance-0.3.6.md)。RAW数值规范、缓存和迁移详见对应pipeline/architecture文档；已有密度算法和TIFF样本行为保持。

## 简短验收

1. 从主页打开包含 TIFF / ARW 的底片文件夹。框选未曝光片基，完成整卷片基校准；调节 Color Timing / Contrast，切换 Identity / LED 矩阵。
2. ⌘C 复制当前参数，⌘/Shift 多选并用 ⌘V 应用；⌘Z 一次恢复整组。**W 为 Master +1 CV，S 为 −1 CV**。Timing 单击 1、Shift 单击 10，长按 0.4 秒后固定 25 CV/秒，一次长按一次撤销；范围 ±512。复制包含 Timing、Contrast 和 Cineon Log LUT。
3. 点击预览工具栏的四个方向图标旋转/翻转，再撤销/重做；重开胶卷检查恢复。水平/垂直翻转以当前画面为准，重置只清除用户追加方向。
4. 点击顶部“自动裁剪”打开设置，选择画幅比例（默认3:2，也可自定义或交换宽高）；默认不保留已有裁剪、每边内收1%；可勾选保留，内收可选0～5%。分析进度留在对话框中；完成后若有待检查照片，会自动进入仅看待检查的裁剪模式。待检查数量、筛选和“确认并下一张”显示在裁剪栏，清零后隐藏。无需先框片基，结果支持整组撤销。按 R 或点击“裁剪”，在单行裁剪栏选择自由/固定比例、横竖和角度，拖边角调整或在框内移动。Enter/完成提交当前帧，Esc 取消，重置草稿可恢复全图。裁剪过程中用 ⌘/Shift 扩选目标，当前照片、范围锚点和草稿保持；普通点击或左右方向键切换照片后保持裁剪模式，保存上一张裁剪并载入新照片自己的裁剪。完成裁剪后从 Filmstrip 上方“同步…”勾选裁剪，向其余所选照片应用同一原片范围，保留各帧旋转/翻转；一次撤销恢复每帧原状态。菜单“复制调色 / 粘贴调色”及 ⌘C/⌘V 保留调色快照。
5. 预览右上角直方图独立切换 Density / Final，默认 Final，始终叠加 RGB。右上角箭头收起，再点“直方图”展开；无统计详情弹窗。统计完整裁后降采样预览，Density 为 D3 密度，Final 为显示器转换前 P3 编码值。
6. 点“100%”检查原始分辨率，拖动平移。片基框选显示十字，会临时恢复完整原片，结束后返回裁后画面；适应窗口/双击复位。按 I 或点击 Color Timing 右上角吸管进入取样，预览指针变吸管；I/Esc 取消。取原片邻域，使 LUT 后 Final 代表色接近中性并尽量保持最终亮度，一次撤销恢复。无论查看哪个阶段，吸管都以 Final 为目标。过亮、剪切、参数范围或整数精度导致无法达标时直接结束取样，不弹窗，原参数保留。顶部重置只恢复当前帧调色。
7. 导出菜单选择当前、所选或整卷，再在导出对话框中选择16-bit TIFF或8-bit JPG、sRGB IEC61966-2.1、Display P3、Adobe RGB (1998)、ProPhoto RGB 或 Rec. 2020，以及 ZIP 压缩复选框（初始勾选，仅 TIFF），填写文件名前缀；应用裁剪初始勾选，关闭则导出完整画面并忽略裁剪微调角度，保留独立旋转/翻转；后缀自动使用胶卷原编号。确认才保存选择；取消对话框不改变输出偏好。导出期间继续调色，不改变已固定的任务。取消任务保留已完成文件，结果逐张列出失败。
8. 缺失照片在 Filmstrip 右键“重新定位”，选择卷内改名后的 TIFF，保留 ID、调色和方向。File → 管理缓存可查看总用量、设置 GB 上限及 3/7/30 天或永不删除。

## 保存与输出

设置自动保存到卷内 `.printroom.json`。当前schema8包含自由比例及裁剪检查状态；旧schema7首次覆盖自动备份，旧版不能读取新版设置。schema 迁移补充结构字段；白点算法迁移规则见下文，既有非单位反差画面会改变。损坏或未来 schema 不重置覆盖，外部写入冲突明确报错，保存失败保留内存设置与撤销，可另存/恢复 JSON 设置副本。schema 1/2 迁移为无裁剪，首次覆盖保留原 JSON；0.1.0/0.2.0 拒绝 schema 3。0.3.0 的几何版本 1 裁剪按每帧原始尺寸及既有方向转换，保留原画面，覆盖前保存 `.printroom-geometry-v1-UUID.json`；源文件缺失或尺寸不可读时保留旧几何，待恢复后转换。0.3.0 不支持几何版本 2，避免同时用两个版本编辑同一卷。迁移和备份细节见 [架构规范](docs/architecture.md#031-项目裁剪与资源)。

Final 的 P3-D65 Gamma 2.6 数值按固定 ICC 的 matrix/TRC 定义执行相对色度转换，黑点补偿关闭；源 TRC 解码 → D50 PCS 矩阵 → 目标 TRC 反函数，使用 Double 计算，最终统一量化。ProPhoto 使用正确 D50 白点与暗部线性段；色适应包含在 ICC 的 D50 colorants 中。五项输出均执行匹配的色彩转换，不在 LUT 后盲目重复 Gamma 编码。支持16-bit RGB TIFF或8-bit JPG、嵌入ICC、orientation=1、无抖动；JPG量化及编码见pipeline.md。用户方向实际变换输出像素，奇数次 90° 交换宽高。裁剪按原始像素确定输出尺寸；零角整数裁剪保留样本，非零角从原线性样本一次双线性插值后执行调色。原 TIFF 不改写，也不因连续调角度重复处理已旋转图像。

批量任务固定目标、源指纹、卷级校准、逐帧调色、方向与裁剪、输出设置；最多四张同时处理，内存不保留全卷原图。禁止覆盖卷内原片；重名先询问，确认覆盖后完整写入再原子替换，选择否才自动递增后缀。发布竞争同样通过冲突决策处理。解码前后检测到源文件指纹变化会失败并记录；读完后的导出使用已读取的当前帧样本快照。

## 性能与边界

主预览有最多 4 项/64 MiB 的展示缓存；切帧先用匹配缓存或 Final 缩略图占位，正式画面完成后直接替换。点击 Filmstrip 后可直接调色；Option+同键调反差，每次 0.01，Shift 不放大反差步长。调参期间旧直方图保持显示；D0–D3 使用 CV 横轴与参考标记，统计内部数值不变。

连续调参使用单在途、单待办预览，复用 GPU 缓冲及 D1 前段结果；直方图采用整图均匀取样并与对应画面一起发布，统计为取样估计；缩略图仅刷新受影响帧。预览长边 1600，缩略图长边 240；原始取样与 1:1 读取 TIFF 条带中的必要区域。低分辨率源缓存有界，整卷全尺寸数据不常驻；全尺寸导出每路仅保留当前一张 UInt16 原图与有界 Float32 块，最多四路。1:1 单区域上限 8,388,608 原始像素，超大窗口超限时明确提示，不自动降低精度。磁盘缩略图与 RAW 缓存共享总上限，默认 8.0 GB、30 天未使用后删除；规则见架构和交互规范，只清理应用拥有的缓存。

输入支持 classic TIFF / BigTIFF RGB UInt16 条带、无压缩/Deflate、大小端、水平预测、八种 TIFF orientation；暂不支持 tile、多页、alpha 或其他位深。输出仍为 classic TIFF，超过 4 GiB 明确拒绝；BigTIFF 输入的实际内存需求取决于条带大小和读取范围。BigTIFF 本轮验证见 [0.3.8 验收记录](docs/acceptance-0.3.8.md)。手动重新定位限定卷内直接子文件。精确扫描标定、LUT Cineon 物理衔接及跨设备色彩外观仍保留验证边界。

本轮 Final 吸管的验证状态见 [0.3.3 验收记录](docs/acceptance-0.3.3.md)，快捷键与直方图前轮证据见 [0.3.2 验收记录](docs/acceptance-0.3.2.md)；未经执行的项目保留待验证。此前证据保留在各版验收记录，不自动视作本轮通过，也不将数值测试等同于用户审美验收。

## 规范与入口

- [算法与色彩](docs/pipeline.md)：公式与常量的唯一来源。
- [交互](docs/interaction.md)、[架构与迁移](docs/architecture.md)、[验证契约](docs/validation.md)。
- [决策](docs/decisions.md)、[阶段](docs/roadmap.md)、[原始资产清单](assets/manifest.json)。
- `Sources/PrintroomCore`：CPU/Metal、TIFF、ICC、导出、方向、直方图、项目模型。
- `Sources/PrintroomApp`：SwiftUI/AppKit 编辑器、异步预览、区域读取与缓存。

参考 TIFF 从不上传或改写。测试项目、导出、截图均位于 `scratch/`、`output/` 或临时目录；Git 不跟踪这些产物。

2026-09-09 工作区清理：已删除历史测试中间产物、编译缓存及带版本后缀的旧应用包。源码、可复用测试脚本、历史验收结论与用户项目保留；验收文档中的旧包、scratch 日志和截图路径仅为历史记录，相关临时文件已清理。

本轮同步交互验证见 [0.3.4 验收记录](docs/acceptance-0.3.4.md)。


0.3.5 矩阵版验收见 [acceptance-0.3.5.md](docs/acceptance-0.3.5.md)。矩阵库保存在用户电脑 `~/Library/Application Support/Printroom/matrices.json`；每卷保存独立系数快照，不依赖库文件继续存在。0.3.5 当时的 CMOS 制作仅 TIFF；后续版本的 ARW 接入见上述当前说明。0.3.5 交付使用 `scratch/matrix-validation` 的 TIFF 隔离快照，通过同一 `scripts/build-app.sh` 生成唯一应用包；完整重现命令及证据见验收记录。

0.3.9 矩阵联动片基的验证与边界见 [acceptance-0.3.9.md](docs/acceptance-0.3.9.md)。


0.3.13 RAW代理策略与验证见 [acceptance-0.3.13.md](docs/acceptance-0.3.13.md)。RAW的1:1显示代理放大，片基/中性点/CMOS制作均基于代理；已保存参数不自动重算。首次准备仍需Adobe完整处理一次，之后只存代理，旧大缓存自动清理。每次导出会重新调用Adobe，因此比已有全尺寸缓存时多一次转换。


0.3.15 起胶卷不再新建 `.printroom-cache`。缩略图与RAW代理统一放在 `~/Library/Caches/studio.printroom.local.v3.3/` 下，具体目录和迁移边界见 [架构规范](docs/architecture.md#0315-缩略图移出胶卷目录)。打开旧胶卷时自动迁移可读的旧缩略图，成功后清理旧文件与空目录；原片和`.printroom.json`继续留在胶卷中。未打开的胶卷暂不处理。验证见 [acceptance-0.3.15.md](docs/acceptance-0.3.15.md)。

0.3.16 原位裁剪与验证见 [acceptance-0.3.16.md](docs/acceptance-0.3.16.md)。

0.3.19简易Timing数值/键盘/项目和窗口证据见 [acceptance-0.3.19.md](docs/acceptance-0.3.19.md)。相对坐标与整数精度、范围限制以pipeline.md为准。

0.3.21 验证与旧项目迁移见 [acceptance-0.3.21.md](docs/acceptance-0.3.21.md)。


0.3.22 LUT中性白校正的数值、CPU/Metal、迁移和导出验证见 [acceptance-0.3.22.md](docs/acceptance-0.3.22.md)。


0.3.27恢复原始LUT及指定两卷的调色补偿，验证与舍入误差见 [acceptance-0.3.27.md](docs/acceptance-0.3.27.md)。


0.3.27 构建2：直方图悬停恢复箭头，返回照片恢复工具指针；Filmstrip 移除缩略图黑色衬底，保留照片比例与选中提示。14项画布/裁剪回归、窗口光标和横竖缩略图检查、release资源/Metal/签名通过。
