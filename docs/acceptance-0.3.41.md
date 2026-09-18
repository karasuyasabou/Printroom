# 0.3.41 Neutral LUT 验收

日期：2026-09-18。交付：output/Printroom.app，0.3.41 / 1，固定应用标识。开始时 Git 工作区干净。

新增下载文件夹 DCI-P3_Kodak_2383_D65_NEUTRAL.cube 的字节一致副本，显示为 Neutral，接入逐帧选择、预览、吸管资源分派和批量导出。默认 Kodak 2383、既有两份电影 LUT、算法 v6 和 schema7 保持；Neutral 资产与采样规范见 pipeline.md。

执行证据：

- `scripts/test.sh --filter 'DirectLUTTests|DiffuseWhiteTests|CineonLUTTests'`：3 项 XCTest 与 3 项 Swift Testing（其中同步测试含 Fuji、Neutral 两组参数）全部通过。覆盖 CPU/Metal 直接查表、原有烘焙表白点回归、迁移备份、Neutral 同步/复制/撤销/重做/保存重开，以及三份 LUT 的合成 TIFF 预览与混合导出回读、16-bit 和 ICC 检查。
- `scripts/build-app.sh`：release 构建、随包 ICC/LUT 哈希、四输出配置、Apple M4 Metal、SDR 预览和严格签名验证通过后替换固定应用包。
- `cmp` 确认下载原件与仓库副本完全相同；随包 Neutral SHA-256 与注册值一致。原有 LUT 未修改。`git diff --check` 通过。

限制：初次沙箱内运行无法创建 Metal 上下文，已在本机权限下重跑成功。带 `--full` 的真实 TIFF 读取分支因历史参考 `TEST/TIFF/DSC07079.tiff` 不存在未完成，未改写或补建参考资产；上述回读使用既有合成数据分支。真实照片视觉效果与实际窗口选择操作待用户试用，数值验证不替代观感验收。
