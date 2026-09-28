# 0.3.53 整卷加载后进入编辑

日期：2026-09-19。本地工作区有此前未提交变更，本轮保留；不创建远端、不推送。

## 变更

按用户最终要求，新旧RAW胶卷统一“正在加载…”页面，进度条、已完成/总数及取消。每次打开检查全部可用RAW，复用有效代理，重建被自动淘汰、缺失或损坏的缓存。全部成功后才发布编辑项目并启动主预览/缩略图；失败显示文件及原因，可重试或返回主页。撤回此前尝试的逐张就绪补缩略图方案。

交互与生命周期以interaction.md及architecture.md的0.3.53节为准。固定4路、像素算法v6、schema7、原资产和缓存策略保持。

## 已执行

- `scripts/test.sh --filter 'RollImportTests|RAWPrewarmerTests|EditorRefinementTests|ThumbnailMigrationTests|RAWSourceServiceTests'`：23项XCTest与23项Swift Testing全部通过。日志 `/tmp/printroom-loading-tests.log`。
- 新增受控加载集成测试：新卷/已存卷均等待全部5张（最多4路），加载期间project/preview/thumbnails不提前发布，失败不覆盖已有JSON；重试、取消及换卷隔离迟到结果。合成源用于调度验证，不代表真实Adobe解码验收。
- 缓存核心测试：代理损坏重建、容量淘汰后用metadata恢复1600/240两种代理，随后编辑读取不再转换；既有缓存命中、取消、并发测试通过。
- `bash scripts/editor-window-qa.sh --release --skip-build --loading`：1060×720离屏加载页/失败页截图通过视觉检查；文案、1/8进度及操作按钮完整，无编辑控件。截图 `scratch/editor-ui-qa/0353-loading.png`、`0353-loading-failed.png`，日志 `/tmp/printroom-loading-ui.log`。
- `git diff --check`通过。

## 执行环境与边界

首轮沙盒内的应用渲染测试因Metal不可用失败，沙盒外复验以上项目通过。窗口脚本首次使用debug旧路径缺少链接产物，改用现有release核心产物后通过。未改动算法或色彩流程。

本轮没有重新执行真实14张ARW首次转换或真实整卷缓存淘汰后的端到端人工操作（仓库TEST/RAW参考目录缺失）；截图原始空位的首次失败原因未通过日志复现，不将时序修订等同于所有读取失败都已排除。真实胶卷的等待时长及体验待用户确认。缓存容量不足以容纳整卷时仍遵守已有异步淘汰规则，未作长期驻留保证。

## 打包

`scripts/build-app.sh`成功；包内ICC/LUT及五项输出profile校验、Apple M4 Metal渲染、UInt16预览与签名验证全部通过后，覆盖固定`output/Printroom.app`（0.3.53，构建1）。日志`/tmp/printroom-0353-build.log`。
