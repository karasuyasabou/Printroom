# 0.3.44 移除 Neutral

2026-09-18。用户撤回刚加入的 Neutral。移除菜单注册、运行加载与导出分派以及随包资源，保留下载原件和仓库原始资产；其他任务已有的滚动条、中性点吸管修改保持。

兼容：旧项目中的 neutral 读取为 Kodak 2383，保留其余参数；首次覆盖前保留原字节备份 .printroom-neutral-UUID.json，后续不重复备份。算法v6、schema7不变。

验证：本机权限运行 scripts/test.sh --filter 'DirectLUTTests|DiffuseWhiteTests|CineonLUTTests'，4 项 XCTest 和 3 项 Swift Testing 均通过。包含移除选项的迁移、原字节备份与不重复备份、CPU/Metal、既有白点、同步/撤销/保存及合成 TIFF 混合导出回读。git diff --check 通过。真实照片观感及窗口操作本轮未执行。

scripts/build-app.sh 构建、ICC/LUT/四输出配置、Metal与SDR预览、严格签名验证通过后替换 output/Printroom.app；版本0.3.44 / 1。检查包内已无 Neutral 文件。
