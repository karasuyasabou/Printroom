# 0.3.13 RAW 日常仅代理

日期：2026-09-10。用户要求平时完全走proxy、实际导出才走全尺寸。算法和坐标契约见pipeline.md末节，缓存生命周期见architecture.md末节。

## 变更

- RAW预览、任意预览尺寸、1:1、片基、中性点和CMOS制作均读代理；1:1明确标注代理。TIFF输入不变。
- 生成代理后删除临时DNG；导出重新转换、直接使用完整UInt16像素，不写full.tiff。无代理的冷启动导出只转换一次。
- 保留已有小代理，互斥维护清理旧source.dng/full.tiff；保留原片、项目、陌生文件与符号链接目标。
- 原片坐标和导出尺寸保持；已存校准/矩阵不自动重算，新取样采用代理值。

## 实际验证

初轮默认沙盒下缓存单元测试17项通过；全套测试因沙盒无法访问Metal和系统文件协调而失败，随后使用本机权限重跑。

本机debug回归（冷启动导出优化前）：182项XCTest，6项按环境跳过，0失败；Swift Testing 95项、19组通过。包含实际Adobe八张RAW全尺寸RGB哈希一致、代理取样、八方向ROI、片基、CMOS制作及导出、八张裁剪导出与参考TIFF回读一致，另有7008×4672完整导出回读。

最终release回归：183项XCTest，6项按环境跳过，0失败；Swift Testing 95项、19组通过。缓存专测18项，含冷启动导出只转换一次、旧DNG/full清理、不重建已有代理、转换失败清理临时文件和并发取消。真实八张RGB与裁剪导出回读一致，单张7008×4672完整导出约2.34秒（仅该机器该样片，不代表整卷性能）。数值摘要保留在raw-proxy-0.3.13.json。

`scripts/build-app.sh`成功；ICC/LUT/四输出profile、Apple M4 Metal、SDR预览和ad-hoc签名验证通过。包内版本0.3.13，显示名称Printroom，应用标识仍studio.printroom.local.v3.3，已覆盖output/Printroom.app。缓存实测从约7.9GiB降到约500MiB（含此次验证新增的代理）。本轮独立临时RAW副本与测试导出已清理，日志和数值结论保留。

日志：scratch/proxy-cache-tests.log、scratch/proxy-regression.log、scratch/proxy-regression-host.log、scratch/proxy-release-tests.log。测试产物仅存scratch或系统临时目录。

## 边界

首次代理生成仍需完整Adobe/LibRaw处理；每次实际导出重新转换，因此没有旧全尺寸缓存命中速度。代理取样不等于原片精确取样，放大不增加细节；已有校准不会在打开时改变。全卷无裁剪性能专项、额外机型/系统、真实用户视觉验收本轮未执行。未新增Photoshop验证。
