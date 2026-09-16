# 0.3.36 LUT漫反射白与RGB偏置回补

2026-09-15，Apple M4；交付 output/Printroom.app 0.3.36/1，固定bundle ID。算法v6、schema6、几何2。

## 实现

按用户最终要求，直接生成两份65³ LUT，D3直接查表，无运行时白点管线。原始LUT不改写；离线校准、公式、重采样边界见pipeline.md。原白点亮度保持，685 CV输出分别为等值RGB 0.842781933（Kodak）与0.840056170（Fuji）；不是输出满值1，也不保证整条灰阶中性。

派生表与SHA位于assets/DerivedLUTs/diffuse-white-v1/manifest.json。固定随机种子、每表100000个域内RGB测量均匀格点重采样相对于原表连续平移的差异：Kodak最大0.008150373、RMS0.000222551；Fuji最大0.028319701、RMS0.000934724。数值在P3编码域，陡峭区域可能有可见差异，不宣称与历史v4逐像素一致。

## 验证

- `scripts/test.sh --filter 'DiffuseWhiteTests|DirectLUTTests|CineonLUTTests|NeutralTimingTests|PivotMigrationTests|PipelineTests|MetalTests|RollProjectTests'`：74项XCTest + 3项Swift Testing，0失败。覆盖两份真实派生表白点ICC亮度/中性、非单位RGB反差固定点、CPU/Metal、直接查表、v5备份迁移、正式资源/预览/双LUT混合导出回读。
- 初次沙箱执行无法创建Metal/使用文件协调；在获准沙箱外重跑。同步更新旧版本断言及旧schema矩阵测试预期（当前生产规则为复用旧矩阵到两类矩阵，生产行为未改）。最终结果见scratch/diffuse-white-tests.log。
- `scripts/build-app.sh`：release成功，随包ICC/LUT及四输出profile验证、Metal Apple M4、SDR UInt16预览及签名通过，成功后替换固定应用包。日志scratch/diffuse-white-build.log。
- `shasum -a 256 -c assets/SHA256SUMS`：13项通过，原TIFF/ICC/LUT保持。

## 两卷回补

用户确认2026-09-01-1/RAW（36帧）及2026-09-01-2/RAW（40帧），路径沿用0.3.27记录。按frameID映射原备份与当前项目，扣回历史实际整数RGB偏置；Master、反差、片基、矩阵、选择、几何和其余字段在写入候选中逐字段核对保留。逐帧before/after见white-restore-2026-09-15.json。

应用退出且全部原SHA一致后，使用文件协调备份、原子写入、即时SHA回读，两卷均成功：

- 第一卷 `.printroom-before-white-restore-31C11061-0434-44AC-A8D4-566C841BF814.json`
- 第二卷 `.printroom-before-white-restore-883C66FE-51FA-4D0B-AA6D-8FFD5F5FD91D.json`

后续核验发现第二卷DSC07123.ARW/DSC07124.ARW调色及当前帧发生后续修改，未覆盖这些新值；因此第二卷当前文件不再等于当时写入SHA。最终只读正式ProjectStore加载两卷均成功，校准/帧记录与当前JSON一致，原备份SHA精确匹配。不要重复执行回补。

## 待验收

实际76帧视觉观感、全分辨率逐帧重新导出及其他设备未验收。工程数值与回读通过不代表外观已获用户确认。
