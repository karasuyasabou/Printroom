# Adobe RAW 路径实测：2026-09-09

状态：**技术实验已完成，尚未接入 Printroom 应用，也不是新增 RAW 功能的用户验收。** 用户要求实际研究 open-make-tiff 两遍 Adobe 转换的作用、是否能简化及相关后处理/代理问题。

## 结论

对于本次 8 张 Sony ILCE-7CM2（A7C II）ARW，Adobe DNG Converter 18.1.1 的单遍 `-u -l -p0 -dng1.1` 可以代替 open-make-tiff 的两遍 Adobe 调用。

- 两种路线的完整 7040×4688×3 Linear DNG 数组逐样本相同。
- 经过相同 LibRaw 后处理的 7008×4672×3 RGB 与从用户提供源码实际生成的 TIFF 逐样本相同。8 张共比较 785,793,024 个 UInt16 RGB 样本，改变数量、最大绝对误差和 RMS 均为 0。
- 第一遍在这批样片上保留了全部 CFA 样本，主要完成厂商 RAW → 标准 DNG 的封装/兼容元数据准备；第二遍才执行 Adobe 去马赛克。单遍可以直接完成这些工作。本实验不能证明作者历史上采用两遍的具体原因，也不把本机型结果推广到全部 RAW。
- 推荐实现方向：单遍 Adobe → 验证 Linear DNG 类型 → 固定 LibRaw 参数 → 未调色线性代理 / 按需全尺寸 TIFF。失败报错，不切换成 LibRaw 自行去马赛克。

完整数字、命令、输入及源码哈希见 [机器可读证据](raw-adobe-study-2026-09-09.json)。实验脚本说明见 [scripts/raw-adobe-study](../scripts/raw-adobe-study/README.md)。

## 实验对象与基准

输入：`TEST/RAW/DSC07119.ARW` 至 `DSC07126.ARW`，共 8 张。原始感光区域 7040×4688，有效裁剪起点 (12,8)，大小 7008×4672。8 张均为负片翻拍；接触图仅用于核对内容，不作为色彩验收。

环境：macOS 26.6.2 (25G83)、arm64；Adobe 18.1.1 (2422)；LibRaw 0.22.1-Release（rawpy 0.27.1 官方 wheel 内动态库及匹配官方头文件）；Go 1.25.12；独立 DNG/TIFF 数值读取使用 tifffile + imagecodecs + NumPy，版本记录于 JSON。

基准的建立：

1. 本机已安装 open-make-tiff 0.1.1 的 CLI 在任何转换前因 Wails WindowSetAlwaysOnTop 的无效 context 退出。未用它的失败输出冒充基准。
2. 把用户桌面源码的 `internal/convert`、`internal/config` 和相关 `pkg` 原样复制到隔离目录，编译最小 Go 驱动，直接调用原始 `Converter.Convert`。原源码未修改，关键源码 SHA-256 已记录。
3. 采用相同 LibRaw 0.22.1；libtiff 使用本机 Siril 携带库。仅跳过 ExifTool 元数据写入、GUI 和任务调度；默认无 ICC、无压缩。实际执行两遍 Adobe，日志已核对，没有 fallback。8 张全部成功输出真实 TIFF。
4. 独立 C++ 驱动使用同一 LibRaw 版本和源码参数，处理单遍 / 两遍 DNG；最终与上述真实 TIFF 比较。另用 tifffile 独立比较解码前 DNG 像素，排除两个 LibRaw 路径共同掩盖差异。

因此结论是**复现所提供源码在本实验依赖版本下的 RGB 样本**；不是复现未知旧版本应用/Adobe 设置的所有元数据、ICC 显示外观或历史输出。实验没有修改原应用、Printroom 产品源码、项目设置或原始资产。

## 两遍的作用与参数陷阱

源码两遍参数（省略 `-d/-o` 路径）：

```text
RAW → pre.dng：-u -p0 -cr5.4
pre.dng → two.dng：-u -l -p0 -dng1.1
```

实际读出：

| 路线 / 参数 | 主图类型 | 压缩 | 与两遍 Linear DNG 的像素比较 |
| --- | --- | --- | --- |
| 第一遍 `-u -p0 -cr5.4` | CFA，7040×4688×1 | 7，无损 JPEG | 与原 ARW 解包的 CFA 全部相同，8/8 |
| 两遍最终 | LinearRaw，7040×4688×3 | 1，无压缩 | 基准 |
| 单遍 `-u -l -p0 -dng1.1` | LinearRaw | 1，无压缩 | 全部相同，8/8 |
| 单遍 `-u -l -p0` | LinearRaw | 1，无压缩 | 全部相同，1/1 |
| 单遍 `-c -l -p0 -dng1.1` | LinearRaw | 7，无损 JPEG | DNG 及最终 RGB 全部相同，1/1 |
| `-u -l -p0 -cr5.4` | **CFA** | 7，无损 JPEG | 不是 Adobe 已去马赛克结果 |
| `-cr5.4 -u -l -p0` | **CFA** | 7，无损 JPEG | 调整参数顺序也无效 |
| `-u -p0 -dng1.1`，省略 `-l` | CFA | 1，无压缩 | `-dng1.1` 本身不保证去马赛克 |

**修正前期仅按源码标志作出的解释**：第一遍虽然传了 `-u`，本机实际不是无压缩。`-cr5.4` 兼容预设会覆盖这里的线性/压缩选择，不能将两遍参数简单合并使用。集成时必须读取真正的主图 photometric（34892）和通道数，不能只相信命令成功或 `.dng` 扩展名。

`-dng1.1` 的结果实际记录 DNGVersion=1.4.0.0、DNGBackwardVersion=1.1.0.0；应理解为兼容目标，不能断言文件头版本就是 1.1。`-p0` 不缩小 RAW，文件仍带有 256×171 的小缩略图 IFD，数值比较必须选真正的 RAW 主图。

第一遍 CFA 比较用 rawpy 只解包原始 ARW，不执行去马赛克，独立与 pre.dng 的 CFA 数组比较，8/8 完全相同。第一遍会规范化/改变部分元数据，例如原 ARW 中的白电平标签与 DNG/LibRaw 的解释不可仅凭字段名称视作同一处理数值。

## LibRaw 后处理的实际行为

基准参数保留源码设置：单位 user_mul、output_color=0、user_flip=0、highlight=1、output_bps=16、no_auto_bright=1、user_qual=3、gamm=(1,1)、adjust_maximum_thr=0、use_camera_matrix=0。读取后应用 `adjust_to_raw_inset_crop(3,0)`，再 unpack/process/copy_mem_image。

这批 Linear DNG 的三个通道黑电平均为 2048、白电平标签均为 65535。在当前参数/LibRaw 下，输出精确等价于：

```text
RGB16 = max(LinearDNG[有效裁剪] - 2048, 0)
```

8 张与独立整数公式逐样本完全相同，输出最大值 63487。**没有再次乘以 65535/(65535-2048)**；尝试该常见归一化公式与基准最大相差 2048 个 UInt16 等级，应拒绝这种“修正”。LibRaw 在此将黑位放在 per-channel cblack 中扣除，而通用 maximum 没有按这个数同步降低；固定最大值设置保留了源码行为。DNG BaselineExposure=0.35 也未在这条固定相机 RGB 路径上额外应用。

这只是本次数据的可验证等价公式，不是可对任意 DNG 硬编码的通用解码器；其他黑位布局、LinearizationTable、Opcode、浮点或不同版本须另验，推荐仍由固定 LibRaw 实现承接。

以下单因素实验均在 DSC07119 上执行：

| 变更 | 实际结果 |
| --- | --- |
| 不应用有效裁剪 | 7040×4688；按 (12,8,7008,4672) 对齐后与基准完全相同 |
| AHD 改为 bilinear | 完全相同；Linear DNG 已无 CFA，LibRaw 不再执行去马赛克 |
| `half_size=1` | **仍为 7008×4672、像素完全相同**，不能借此生成小代理 |
| 开启 camera matrix，仍 output_color=0 | 完全相同；相机 RGB 路径没有转换到标准色域 |
| 相机白平衡 | 65,479,952 个通道样本改变，最大差 37,720 |
| 单独开启 auto brightness | 在现有 highlight=1 组合下无变化；源码条件也说明它抑制该自动提亮分支，不代表可以随意更换整组默认值 |
| `adjust_maximum_thr=0.75` | 94,495,733 个通道样本改变，最大差 2,048；必须保持 0 |
| `no_auto_scale=1` | 本样片无变化，不外推所有输入 |
| 仅 `user_black=0` | 本样片无变化；它未清除 per-channel cblack，不能解释为黑位处理不存在 |
| 转为 sRGB 并启用相机矩阵 | 98,099,559 个通道样本改变，最大差 16,730 |
| 常见非线性输出 gamma | 98,183,753 个通道样本改变，最大差 15,768 |
| 原始 ARW 直接 LibRaw AHD，并对齐有效裁剪 | 96,772,407 个通道样本改变，最大差 9,129；包含去马赛克和 RAW 数值处理差异，不用于对算法审美优劣下结论 |

由此支持：固定参数，禁用非 Adobe 去马赛克回退。LibRaw 的存在本身不会把 Adobe 的去马赛克换成 AHD。

## ICC、代理与 Printroom 接入验证

- open-make-tiff 的 ICC 选择只是嵌入字节，不执行 RGB 转换。其 ProPhoto.icm 的 TRC 实际约为 Gamma 1.80078125，并非线性 ICC；“像素是线性数值”与“附带 ICC 如何解释这些数值”必须区分。以后 RAW 缓存应明确标记输入策略，不从 ICC 自动加 Gamma 或转换色域。
- 用 Printroom **实际 TIFFCodec** 读取 8 张源码基准 TIFF，与单遍路线 UInt16 完整数组相同；源头处理差异没有被现有 TIFF 解析吞掉。
- 沿用现有 nearest-original-sample 策略生成 1600×1066 代理（不是 1067：当前实现对缩放后尺寸取整截断），通过现有 TIFFCodec 写为多条带 Deflate TIFF，再回读，8/8 样本完全相同。实验刻意附带普通 ProPhoto ICC，也未触发隐式解码变换。
- 原始 11×11 区域读取与对应全图区域逐样本相同，8/8。区域文件应由全尺寸中间 TIFF 提供，不能从代理冒充原始像素。
- 另测线性 BOX 缩小：生成约 0.126 秒，16-bit TIFF 回读无损，但与现有 nearest 代理不同（包括边缘/颗粒/齿孔）。因此抗混叠代理是另一个可选择的采样策略，不能把其差异说成 Adobe 路线差异。当前结论建议先保持 existing nearest 策略完成复现；如后续改用 BOX，应明确记录预览采样策略及验证。
- 代理不烘焙 Printroom 调色。几何映射必须记录有效裁剪后的全尺寸宽高，不能按代理宽高保存原始取样坐标。

## 性能与缓存取舍

8 张单线程顺序运行，奇偶帧交替先跑单遍/两遍，减少固定顺序偏差；是本机一次批量观测，不是冷启动性能承诺。Adobe 启动日志含 `GPU3 disabled via cr_config at init time`，不把它称为 GPU 加速实测。

| 环节 | 观测 |
| --- | --- |
| 单遍 Adobe | 中位 0.819 秒/张 |
| 原两遍 Adobe 合计 | 中位 1.422 秒/张 |
| Adobe 部分节省 | 均值口径约 42.4%；不是整个应用/导出的提速百分比 |
| 原始源码完整两遍 + LibRaw + 无压缩 TIFF（无 ExifTool） | 1.63–1.72 秒/张 |
| 示例无压缩 Linear DNG | 198,355,582 bytes，约 189.17 MiB |
| 示例无损压缩 Linear DNG | 107,062,516 bytes，约 102.10 MiB；像素相同 |
| 无压缩 vs 无损压缩 DNG 的 native decode/copy 示例 | 约 0.18 秒 vs 1.08 秒；压缩节省空间但反复解码更慢 |
| 示例全尺寸 TIFF | 196,448,396 bytes，约 187.35 MiB |
| 示例 nearest Deflate 代理 | 8,661,179 bytes，约 8.26 MiB |
| native 子进程峰值 RSS（本组后续解码子进程的最大值） | 726,056,960 bytes，约 692.42 MiB；不包含 Adobe/GUI/整卷驻留 |

生成小 TIFF 不会免掉 Adobe 全尺寸去马赛克；`half_size` 对这类 Linear DNG 无效。不过可以在 LibRaw 得到线性像素后仅写小代理，避免每张导入都保存全尺寸 TIFF；全尺寸 TIFF 在 1:1、片基/吸管或导出时再生成。优先当前帧、限制转换并发、缓存 Linear DNG，可控制延迟和内存。无压缩 DNG 适合近期使用的速度缓存，无损压缩可作为容量取舍；不使用有损 RAW/JPEG 缩略图代替调色输入。

## 保留的边界与下一步

- 已完成上述 8 张当前机型的数值和实际文件闭环；原始 ARW SHA-256 前后 8/8 一致。
- 尚未进行其他机型/RAW 编码、其他 Adobe/LibRaw 版本、完整 UI 导入/取消/缓存失效和多任务内存验收。本轮没有把 RAW 加入正式项目 schema 或打包新应用。
- 没有用 Photoshop，未上传任何样片，也没有创建远端/发布。
- 后续正式实现建议固定经过验证的单遍参数与 LibRaw 处理契约，验证输出确为 LinearRaw，记录解码版本与源指纹，缓存身份区分原片/有效尺寸/代理采样，Adobe 失败即停止。新机型先跑同一组对照再声明兼容。

失败与纠正记录：Adobe 沙盒内启动被系统终止，按授权在沙盒外运行只写 scratch；已安装 open-make-tiff CLI 的 Wails 错误由隔离源码驱动绕开；测试驱动初次链接库路径无效，修正的是 scratch 中驱动的动态库引用，未改 Siril；常见减黑归一化假设被数值实验否定，最终采用源码实际输出作为判据。
