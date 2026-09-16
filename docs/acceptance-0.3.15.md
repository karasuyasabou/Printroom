# 0.3.15 缩略图移出胶卷目录

日期：2026-09-10。用户要求将卷内缩略图也统一放系统缓存。路径、迁移/保留规则以architecture.md末节为准。

## 已实现

- 正式编辑器创建、读取、维护及手动清理缩略图均使用系统Caches下按胶卷隔离的目录，不再新建卷内缓存。
- 打开旧卷时迁移可读的已知PNG；成功写入目标后才删除源，最后仅移除空目录。失败保留尚未迁移文件，不阻断编辑。
- 原片、`.printroom.json`、陌生文件、符号链接目标与最近临时文件受保护；过期的已知临时文件可清理。
- 缓存命名空间包含胶卷UUID与路径；移动或复制胶卷可以重新生成，不影响设置。图像算法、项目schema和RAW代理策略不变。

## 已执行

`scripts/test.sh -c release --filter 'ThumbnailMigrationTests|ImageServiceTests|AdjustmentSchedulingTests|EditingV2Tests'`

27项测试、5组通过。6项迁移测试覆盖：像素/位深保留、项目与原片不变、幂等与空目录清理、失败保留源、陌生文件/新旧临时文件/符号链接、胶卷隔离与当前卷清理，以及真实EditorModel打开/清理/重建后卷内仅剩原片和JSON。既有缓存测试覆盖ICC、限额和过期，编辑器与调参调度回归通过。测试使用临时合成胶卷，无原始资产写入。

`scripts/build-app.sh`成功，资源ICC/LUT/四输出profile、Apple M4 Metal、SDR预览与ad-hoc签名验证通过；`git diff --check`通过。交付覆盖`output/Printroom.app`，包内版本0.3.15、构建1，显示名称与固定应用标识保持。

日志保留于`scratch/thumbnail-migration-tests.log`、`scratch/thumbnail-migration-build.log`。

## 未执行与边界

未扫描或迁移用户尚未打开的胶卷；需用新版打开后自动处理。真实外置盘只读/拔出和旧版应用并发写入未实机验证。旧目录中陌生文件、不可读PNG、符号链接或近期临时文件会保留；没有权限删除时旧文件也保留以供重试。此次未变更数值管线，不重复执行全尺寸RAW/TIFF导出专项。用户视觉验收未执行。
