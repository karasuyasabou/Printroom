# 0.3.37 RAW 首次切图与缓存维护

## 原因与修改

每个RAW metadata/preview请求完成后都会请求独占全库维护。即使命中已存在代理，后台扫描仍使后续读取等待。现在命中仅更新访问时间；新增代理、旧缓存迁移、启动、每小时、缩略图维护及修改策略继续触发维护。算法v6、schema6、两份现有LUT及用户项目保持。

## 实际性能证据

本机Apple M4、release测试、2026-09-01-2/RAW的DSC07115–DSC07120，读取现有项目参数，四路RAWPrewarmer并行。每次比较使用新测试进程，OS文件缓存未清空。使用真实1600代理、已保存裁剪/调色和Final直方图，不写用户项目。

| 指标 | 修改前 | 修改后 |
| --- | ---: | ---: |
| 读取平均 | 246.4ms | 27.8ms |
| 读取最大 | 494.4ms | 39.6ms |
| 读取＋渲染平均 | 288.1ms | 66.9ms |
| 修改后读取＋渲染范围 | — | 55.4–102.9ms |

明细见 [raw-cached-preview-0.3.37.json](raw-cached-preview-0.3.37.json)。这是六帧单轮对照，不包含窗口上屏、应用启动资产加载或缩略图重建，不宣称所有情况下都小于100ms，也未复现用户估计的整整1秒。

可复用命令：`PRINTROOM_RAW_MEASURE_BACKGROUND=1 PRINTROOM_RAW_MEASURE_ROLL=/path/to/RAW scripts/test.sh -c release --filter RAWPreviewPerformanceMeasurements`。

## 回归与交付

- `scripts/test.sh -c release --filter 'RAWSourceServiceTests|RAWPrewarmerTests|DiskCachePolicyTests|ThumbnailMigrationTests'`：27项XCTest、8项Swift Testing通过。首次受限环境中EditorModel无法创建Metal资源；正常本机权限下全部通过。
- 新测试验证连续metadata/两档preview命中不增加维护次数，新代理仍维护，显式请求可继续维护。既有缓存损坏、源变化、跨实例、四路、取消及容量/过期测试通过。
- `scripts/build-app.sh`：release构建、ICC/LUT/四输出profile验证、Apple M4 Metal渲染、SDR UInt16预览及严格签名验证通过；固定交付 `output/Printroom.app`，0.3.37（构建1）。
- 实际窗口切图体验待用户验收；无全尺寸重新导出或新增外观验收。
