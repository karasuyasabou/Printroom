# 0.3.49 导出色彩空间

2026-09-19，Apple Silicon / macOS 27。本轮按用户提供的 LRC 截图提供五项菜单，顺序、名称见 interaction.md；实际转换和固定 ICC 定义见 pipeline.md §11，兼容规则见 architecture.md。新增 Display P3 与 Rec. 2020，保留底层旧 p3。原有密度算法v6、项目schema7、16-bit TIFF及ZIP行为保持。

## 构建1历史验证（旧P3保留策略已被构建2取代）

`scripts/test.sh --filter 'ExportColorTests|ProjectMigrationRelocationTests|ExportProfileOptionsTests|PivotMigrationTests'` 在可访问系统服务的环境运行：26项XCTest和1项Swift Testing全部通过，0失败。日志 `/tmp/printroom-export-profiles-final-tests.log`。

- 全六份配置（含旧P3）×两种压缩：TIFFCodec与独立ImageIO回读16-bit样本、ICC字节及orientation一致；裁切0°/6.73°导出解析采样和单张/批量快照覆盖全部配置。
- 独立公开原色矩阵与曲线参考：Display P3最大绝对误差7.62e-6，Rec. 2020为3.09e-5。CoreGraphics参考分别6.30e-6、9.00e-6；独立暗部/灰阶解析检查通过。
- 五项菜单名称、顺序、选择与SHA映射、新卷默认、旧p3对话框草稿和保存重开通过。旧schema1夹具显式使用历史P3/SHA；解析裁剪夹具显式使用恒等校准，避免新卷Sony/LED默认值污染其解析假设。
- 首次沙盒运行因系统文件协调服务限制失败；首次正常环境运行触发原有解析裁剪夹具的大量断言而停止，修正夹具后全部通过。曾试用系统ITU-2020 profile，ICC曲线与CoreGraphics解释差异导致失败，改用Adobe固定Gamma2.4 profile后两套参考均通过。来源见OutputProfiles/PROVENANCE.txt。
- `git diff --check`通过。原始ICC与两份LUT的SHA校验通过；`assets/SHA256SUMS`内十张参考TIFF所在的TEST目录在当前工作区缺失，不能宣称全资产校验通过。

## 验证边界

本轮未进行真实LRC导入/外观对照、导出窗口截图验收或真实参考TIFF全尺寸导出。数值与ICC测试不等于用户色彩外观验收，不声称与LRC导出像素或ICC字节完全一致。保存了新选项的项目不应再用旧版打开；旧版遇到未知枚举会拒绝读取。

## 构建1交付

`scripts/build-app.sh`通过release构建、五项输出ICC与旧P3资源检查、Apple M4 Metal/16-bit预览冒烟和严格签名验证后覆盖`output/Printroom.app`。包内版本回读0.3.49，构建1，固定应用标识保持。日志 `/tmp/printroom-0349-build.log`。现有工作区其他修改保留，本轮不提交Git、不发布。


## 构建2：移除旧P3，自动回退默认值

用户明确要求不保留旧P3，遇到不兼容输出改为默认。旧p3已从枚举和导出转换分支删除；旧p3/未知字符串解码为Display P3并同步SHA，schema1同样回退，正常保存写回。内部LUT源ICC仍按原指纹验证，不作为输出选项。有效选项但SHA错误仍拒绝读取。读取与保存契约见architecture.md。

`scripts/test.sh --filter 'ExportColorTests|ProjectMigrationRelocationTests|ExportProfileOptionsTests|PivotMigrationTests'`：27项XCTest + 1项Swift Testing全部通过，0失败。五份ICC × 两种压缩读回、数值与灰阶、菜单、schema迁移、旧/未知输出回退及保存重开均通过。日志 `/tmp/printroom-export-profiles-build2-tests.log`。本轮验证边界仍同上。

构建2通过`scripts/build-app.sh`的release编译、五项ICC/LUT资源、Apple M4 Metal、16-bit预览与严格签名验证，已覆盖`output/Printroom.app`；版本0.3.49/2、固定标识保持，日志`/tmp/printroom-0349-build2.log`。`git diff --check`通过。
