# 算法与色彩管线

本文是公式、单位和常量的规范来源。除标注为“工程默认/待验证”的项，以下核心公式、矩阵、pivot、参数范围均来自用户说明及后续确认。算法初始标识：`printroom-density-v1`；这是拟实现契约，不代表已运行验证。

## 1. 阶段与表示

```text
L0 原始线性 RGB
 → Linear Gain → L1
 → Cineon Density → D0
 → Print Density Matrix → D1
 → Film Base Offset + User Timing → D2
 → RGB Contrast → D3
 → Kodak 2383 D65 LUT → Final（P3-D65 Gamma 2.6 编码 RGB）
 → 显示器色彩转换 / 导出 profile 转换
```

CPU 参考和 Metal 基线都用 Float32。L0/L1 是线性透射率数值；D0–D3 **统一保存归一化密度** `N`。UI Timing 与校准偏移保存 CV，进入计算时除以 1024。函数与字段名必须标明 `CV`、`Density` 或 `NormalizedDensity`，避免混用。

中间阶段不量化为整数 CV、8-bit 或 16-bit，不把密度数组包装成普通 RGB 交给 ICC 处理。Float16 只允许在后续通过误差验收后作为明确优化。

## 2. 输入读取与解释

支持的初始输入是 3 通道无符号 16-bit RGB TIFF，`L0 = uint16 / 65535`。先解压读取样本数值，不做 ICC 转换或 transfer 解码。无 alpha；不支持的灰度、浮点、带 alpha 或其他样本格式先明确报错，不静默转成 8-bit。

输入解释固定记录为：原色 P3-D65，transfer Linear。最终工作显示 profile 使用现有 `ICC/DCIP3_D65.icc`。

**资产实测差异：**10 张参考 TIFF 实际嵌入 `ProPhoto RGB Linear`，三个 TRC 均为 Gamma 1.0。按用户“指定/解释，保持数值”的要求，初始模式仍将这些原始通道数值解释为 P3-D65 Linear，不执行 ProPhoto→P3 转换。保留原 ICC 名称和哈希作为诊断，并显示“输入解释：P3-D65 Linear；嵌入：ProPhoto RGB Linear；未转换”。这是一项明确的数值处理约定，不宣称保留嵌入 profile 定义的原始色度。

不新增“自动按 ICC 转换”模式。未来如果引入真正的输入原色转换，必须成为独立算法策略和项目字段，不能改变旧项目结果。

## 3. 片基采样与 Linear Gain

选区映射到完成 TIFF orientation 校正后的原始像素坐标，整数边界，左上包含、右下不包含。保存此坐标空间、来源帧 ID、图像尺寸与选区，避免从缩略图采样。逐通道中位数；偶数样本数取中间两值平均，禁止先取 RGB 亮度再求中位数。

工程默认：选区至少 16 个有效 RGB 像素；排除任何通道非有限的整个像素。任一通道中位数 `base[c] <= 0` 则校准失败，保留已有有效校准。报告零值和饱和样本比例，不暗中排除有限亮暗值；用户可据此重选。

```text
gain[c] = 0.75 / base[c]
L1[c] = L0[c] × gain[c]
```

未校准时 gain=(1,1,1)、offsetCV=(0,0,0)，状态为未校准；预览可用但不能伪装已达片基目标。不裁切 L1 上界；大于 1 可以形成负密度。

## 4. 密度与 CV

```text
physicalDensity = -log10(T)
normalizedDensity = physicalDensity / 2.048
physicalDensity = CV × 0.002
normalizedDensity = CV / 1024
CV = normalizedDensity × 1024
```

工程默认：`T = max(L1, 1e-6)`；零值和有限负值被替换并累计诊断计数。NaN/Inf 不送入 LUT：处理任务返回明确错误，保留上一次有效预览并禁止本次导出。不裁切有限的中间密度。

| 参考点 | CV | 实际密度 | 归一化密度 |
| --- | ---: | ---: | ---: |
| 黑点/片基校准目标 | 95 | 0.19 | 0.0927734375 |
| 反差 pivot/18% 中灰参考 | 470 | 0.94 | 0.458984375 |
| 白点参考 | 685 | 1.37 | 0.6689453125 |

这些参考点不代表必须在基础 `-log10(T)` 中额外加入 Cineon 黑位、白位或曝光曲线。白点不是内部裁切点。

**1024/1023 工程决定：**本版本严格使用上述 1024 约定，D3 直接送 LUT，不附加 `1024/1023` 缩放。普通 10-bit 文件的 `code/1023` 不得混入本管线。文件头仅说明 Cineon Log 0–1，无法证明作者精确采用了哪种归一化或扫描标定；当前衔接是待视觉与色阶验证的工程约定。若证据要求调整，创建算法新版本，禁止无声更改已有项目。

## 5. Transform to Print Density

默认 `identity`。另提供 `ledLightSource`。RGB 列向量，左乘矩阵，计算发生在归一化密度域：

```text
D1 = M × D0

Identity =
[ 1  0  0 ]
[ 0  1  0 ]
[ 0  0  1 ]

LED Light Source =
[  1.0584  -0.0204   0.0023 ]
[  0.0753   1.0120  -0.0693 ]
[ -0.0147   0.1420   0.7774 ]

R′ =  1.0584R − 0.0204G + 0.0023B
G′ =  0.0753R + 1.0120G − 0.0693B
B′ = −0.0147R + 0.1420G + 0.7774B
```

来源：用户提供的矩阵截图及 RGB 顺序确认。无额外矩阵偏移。不得归一化行和、转置、拟合或修改系数。Swift SIMD 矩阵可能按列构造，须用基向量验收其实际乘法方向。

## 6. 片基 95 CV 自动校准

```text
baseL1 = base × gain
baseD0 = -log10(max(baseL1, epsilon)) / 2.048
baseD1 = M × baseD0
filmBaseOffsetCV = (95,95,95) − 1024 × baseD1
```

offsetCV 保留浮点。含义是让 `baseD1 + offsetCV/1024` 达到片基目标；偏移作用在 D1 之后。D1 本身不含偏移，D2 同时包含自动偏移和用户 Timing。校准承诺仅在用户 Timing=0、Contrast=1 的基准状态成立，后续手动调色可以移动片基。

重新采样：重新计算 gain 和 offset。切换矩阵：从已保存的 base/gain 重新计算 offset。两者影响整卷，但保留每帧用户 Timing/Contrast。失败时不部分更新。未校准时换矩阵保持 offset=0。

## 7. Timing 与 RGB Contrast

```text
effectiveCV[c] = filmBaseOffsetCV[c] + masterCV + channelCV[c]
D2[c] = D1[c] + effectiveCV[c] / 1024
```

Master、R、G、B 默认为 0，用户控件各自为整数 `[-256,256]`，每次步进 1 CV。各控件限制独立，合成偏移不再裁切到该范围。正值代表密度增加，不先按最终亮暗视觉反向解释。

```text
pivot = 470 / 1024
finalContrast[c] = masterContrast × channelContrast[c]
D3[c] = pivot + finalContrast[c] × (D2[c] − pivot)
```

反差默认均为 1。工程默认每个控件范围 `[0.25,4.0]`，步长 0.01，允许数值输入；乘积不再次裁切。首版 pivot 固定，显示 470 CV，不可编辑。不使用 685 CV 作为 pivot。

## 8. LUT

资产：`LUT/DCI-P3 Kodak 2383 D65.cube`，33³，35937 行，DOMAIN_MIN=(0,0,0)、DOMAIN_MAX=(1,1,1)。文件头声明 Cineon Log 输入，Kodak 2383 D65 外观、DCI-P3 Gamma 2.6 显示输出；文件数值范围见资产清单。

工程默认：输入在 LUT 边界逐通道 clamp 到 [0,1]，记录域外计数；采用显式三线性插值，CPU 和 Metal 采用相同算法。`.cube` 红索引变化最快，行索引 `r + N*g + N*N*b`。坐标为 `u*(N-1)`，上界索引不得越界。GPU 首版手动读取 8 个格点插值，避免硬件采样半像素坐标与精度差异。暂不提供四面体插值。

Final 按现有 P3-D65 Gamma 2.6 ICC 解释。LUT 后不再套 Gamma 2.6 编码。文件头语义作为实现依据；其色度正确性与完整视觉效果仍待实际验证，不能从文件名推断已经验证。

## 9. 预览、导出与中间阶段诊断

Final 由正确的源 profile 转换到显示器 profile；显示链路只进行一次相应转换。显示框架的纹理格式、transfer 和系统合成行为须由 M1 实测明确，不能把“看起来正常”作为排除双重 Gamma 的证据。

中间阶段工程默认：L0/L1 显示 `clamp(value,0,1)` 的诊断伪色 RGB；D0–D3 显示 `clamp(normalizedDensity,0,1)` 的诊断伪色 RGB，统一作为 sRGB 编码诊断画面送显示器。标记“数值诊断”；采样读数始终来自未裁切、未编码的内部值，密度同时显示 CV。诊断显示不参与任何后续计算。首版提供 RGB 取样读数，直方图可后续加入。

默认导出：Final→P3-D65 Gamma 2.6→16-bit RGB TIFF，嵌入原始 ICC；相同 profile 不转换数值。工程默认无损 ZIP/Deflate 压缩、无 alpha、orientation=1、抖动关闭；如编码器不支持所选压缩，明确失败或实现并记录无压缩模式，不隐式降位深。

M3 增加 Adobe RGB、sRGB、ProPhoto RGB 的实际 ICC 转换。默认相对色度意图、黑点补偿关闭；ICC 标识与哈希必须持久化。ProPhoto 使用正确 D50 profile 和色适应，不仅改标签。嵌入 ICC 默认为开，M1 必须支持；关闭嵌入的高级选项在 M3 增加。抖动初始保持关闭，未来增加时只发生在最终量化之前，并明确可重复的实现。

量化工程默认：先完成输出 profile 转换，检查有限值，再 `floor(clamp(value,0,1)*65535 + 0.5)`。16-bit 整数归一化用 65535，与密度的 1024 不是同一问题。导出不可覆盖源 TIFF，冲突生成递增后缀；写入临时文件成功后再原子移动到目标。
