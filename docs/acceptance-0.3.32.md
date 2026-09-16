# 0.3.32 相纸470 CV中性灰验收

日期：2026-09-14。用户要求相纸LUT以现有Kodak2383为中灰曝光参照，截取2.048密度，允许通道偏移保持470 CV为中灰。

## 实现

五个相纸LUT采用RGB分别平移密度窗口。470 CV输出RGB目标均为0.462908711538（P3-D65 Gamma 2.6编码），线性亮度0.134987173971，与原2383该点一致。每通道窗口宽度严格2.048，曲线形状保持；其他色阶仍可有相纸色偏。原2383/Fuji不做中和，上游685 CV反差pivot及用户Timing不改。

转换算法divere-paper-gray2383-neutral-v3，完整公式唯一来源为pipeline.md §8补充；当前资源SHA/精度见assets/DerivedLUTs/gray2383-neutral-v3/manifest.json。v2共用偏移为本轮中间研究产物，未交付，不作为当前资源。schema6、密度算法v5保持，既有相纸选择采用新版资源，缩略图身份随SHA变化。

## 位置实测

每个通道截取[dmax−2.048,dmax]。下列CV偏移相对于0.3.31默认dmax=2.5，只用于解释烘焙差异，不写入用户Timing。

| 相纸 | RGB dmax | 相对v1 RGB偏移 / CV |
| --- | --- | --- |
| Kodak Ektacolor Edge | 2.398581042 / 2.381869723 / 2.383089179 | 50.7095 / 59.0651 / 58.4554 |
| Kodak Endura Premier | 2.623615257 / 2.602943982 / 2.603497376 | -61.8076 / -51.4720 / -51.7487 |
| Kodak Portra Endura | 2.404629715 / 2.420847943 / 2.432868187 | 47.6851 / 39.5760 / 33.5659 |
| Kodak Supra Endura | 2.684339961 / 2.701367153 / 2.681746932 | -92.1700 / -100.6836 / -90.8735 |
| Kodak Ultra Endura | 2.557329680 / 2.590942432 / 2.583633351 | -28.6648 / -45.4712 / -41.8167 |

## 已执行

- 带NumPy的Python运行generate-divere-luts.py及validate-divere-luts.py：五表生成；源DiVERE四个原方法对照4096个随机RGB点，最大通道差<5.3e-14。烘焙表中灰逐通道目标残差<1e-9。
- `scripts/test.sh --filter 'PaperGrayLUTTests|DirectLUTTests|CineonLUTTests'`：3项XCTest通过；3项Swift Testing通过，其中同步/撤销测试含6种参数选择。CPU/Metal的中灰亮度及中性、每通道2.048窗口、直接LUT行为、旧项目迁移、选择保存/复制/重置、七LUT混合导出通过。
- 正式Float32 LUT采样的L*约43.504973…43.504978，2383参照43.504976；测试中CPU/Metal的|ΔL*|<0.00005，通道极差<1e-6。
- `PRINTROOM_VALIDATE_ASSETS=1 scripts/test.sh --filter 'CineonLUTTests.selectedLUTPreviewMetalAndMixedExportReadback'`：通过。只读DSC07079.tiff中心12×8像素块，七表分别写临时TIFF并导出；全96像素逐通道量化差≤2/65535，ImageIO确认16-bit和原P3 ICC字节一致。未执行整幅全尺寸实图导出。
- `shasum -a 256 -c assets/SHA256SUMS`：13项全部通过。v1、v2、v3各五个派生表SHA全部核验，历史表未覆盖。

## 边界

65³离散LUT对110001个探针的最坏通道误差约0.06464，各表RMS≤0.001606；这是任意颜色相对于连续转换的误差，主要在色域裁切边界，不是470 CV校准误差，也不代表16-bit解析精度。中灰已数值验收，整条灰阶及实际照片外观仍待用户验收。无需Photoshop，不上传任何扫描照片。

## 交付

`scripts/build-app.sh` 已成功；随包资源、四输出ICC、Metal Apple M4渲染、UInt16预览与严格签名验证通过。固定交付 `output/Printroom.app`，0.3.32/1，显示名Printroom、标识studio.printroom.local.v3.3。新包验证后替换旧包。
