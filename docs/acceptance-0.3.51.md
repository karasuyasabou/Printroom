# 0.3.51 四路导出验收

日期：2026-09-19。已交付 `output/Printroom.app`，版本0.3.51、构建1；标识保持 `studio.printroom.local.v3.3`。

## 实现

完整导出最多四帧在途，空闲一路补下一帧；各路独立Metal缓冲。RAW解码、裁剪、调色、CPU输出转换、ZIP压缩和写盘均按帧并行。结果保持请求顺序，进度聚合且不倒退；取消停止补充队列，等待在途清理，保留已发布文件。复用已有源快照验证、RAW四槽、原子无覆盖发布及同名重试。算法v6、schema7、ICC、ZIP等级和像素公式不变。实现契约见architecture.md末节。

## 性能与一致性

机器GPU为Apple M4。读取用户指定2026-09-01-1/RAW第17–20张：DSC07095.ARW、DSC07096.ARW、DSC07097.ARW、DSC07098.ARW。沿用项目中逐帧调色/方向/裁剪，ProPhoto RGB、16-bit ZIP。只读原片和项目，输出到本地scratch，未向Synology目录写测试导出。没有清空系统文件缓存。

先用独立临时计时副本试验：四张串行21.067秒、四路6.821秒，完整TIFF的SHA256全部一致。初步峰值RSS分别817,938,432和2,782,216,192字节。

随后用正式release对象代码和可复用测量驱动反向执行四路→串行：

| 模式 | 四张总导出时间 | 测量进程最大RSS |
| --- | ---: | ---: |
| 串行 | 21.098秒 | 954,368,000字节（0.89GiB） |
| 四路 | 7.302秒 | 3,015,344,128字节（2.81GiB） |

正式四路约2.89倍吞吐，耗时降低65.4%。RSS包含驱动读取项目及输出哈希阶段，不含Adobe子进程；不是应用加Adobe的系统总内存。四张正式串行、正式四路以及变更前串行输出三方SHA256全部相同，包含像素、压缩与ICC整个文件。两次正式测量项目SHA256相同，每次前后也核验项目字节不变。

复现命令（输出目录须未存在）：

```sh
scripts/build-app.sh
scripts/measure-export-concurrency.sh '/Users/bao/Library/CloudStorage/SynologyDrive-BaoNAS/Photos/Film/2026-09-01-1/RAW' "$PWD/scratch/export-profile-one/production-parallel" 4 17 4
scripts/measure-export-concurrency.sh '/Users/bao/Library/CloudStorage/SynologyDrive-BaoNAS/Photos/Film/2026-09-01-1/RAW' "$PWD/scratch/export-profile-one/production-serial" 1 17 4
```

JSON报告保留于上述目录的measurement.json，包含项目及每个输出SHA256；进程计时分别在scratch/export-profile-one/production-{parallel,serial}-time.txt。测试TIFF随后删除，报告与可复用脚本保留。

## 回归与交付

- `scripts/test.sh --filter 'ExportColorTests|CineonLUTTests|ExportProfileOptionsTests|RAWSourceServiceTests'`：41项XCTest、4项Swift Testing全部通过，无跳过；日志scratch/export-profile-one/tests-verified.log。
- 新增四项：九帧串行/四路文件一致及进度/在途上限/排序；并行中途取消保留已完成、至少五帧不再启动、临时文件清理；同basename冲突与缺失源失败后继续；开始前取消不产生输出。既有单路逐帧取消测试显式使用一路，继续验证原场景。
- 本轮发现并修正CineonLUTTests历史断言：0.3.49后默认Display P3应转换并嵌入目标ICC，旧断言仍要求原生P3 Gamma2.6；改为按当前输出选择比较ICC及量化值。独立解析ICC和系统CMM对照仍由ExportColorTests覆盖，没有为通过测试改变生产色彩转换。
- 初次沙箱内测试因NSFileCoordinator无法读取临时目录失败，获授权后沙箱外完成上述回归；初次release调用因未指定可写module cache失败，设置工作区cache后构建成功。失败记录不计通过。
- `scripts/build-app.sh`成功：release、原ICC/LUT及五输出profile资源验证、Apple M4 Metal渲染、SDR预览验证、ad-hoc及严格签名验证。验证后覆盖固定应用路径。日志scratch/export-profile-one/package.log。
- `git diff --check`通过；保留工作区已有整卷调色等修改，未创建远端、未推送。

## 验证边界

未重新导出整卷36张，未测Synology同步目录写入性能、其他机型或低内存机器；约1分钟整卷仅可作为按样本外推，不是已测结果。四路增加内存占用；本轮验证数值一致与导出安全，不代替用户实际窗口操作或色彩外观验收。未补做历史缺失TIFF资产和不相关验收。
