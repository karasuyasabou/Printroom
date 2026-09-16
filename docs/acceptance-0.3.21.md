# 0.3.21 导出默认 ZIP 与胶卷编号

2026-09-11，统一交付 `output/Printroom.app`，构建 1。

实现：三个导出入口统一目录及前缀，ZIP 默认，编号取完整胶卷顺序；规范见 interaction.md，快照及兼容边界见 architecture.md。不修改原始资产或图像算法。

验证：
- `scripts/test.sh -c release --filter 'ExportColorTests|ProjectMigrationRelocationTests'`：23 项通过。新增合成 TIFF 检查第二张单独导出为 `假日-02.tiff`、所选第二/三张保持编号、重名追加后缀、ZIP 标签 8、TIFF 回读和非法前缀拒绝；既有输出颜色、取消、源保护和旧项目迁移回归通过。
- `scripts/build-app.sh`：release、包内资源、Metal、UInt16 预览格式和 ad-hoc 签名验证通过，成功后覆盖固定应用包。
- `git diff --check` 通过。

首次沙盒内测试因临时目录读取失败，打包因 Metal 上下文不可用失败；沙盒外重跑上述命令成功，失败打包保留旧应用。

未执行：真实导出面板键鼠/截图、全套图像回归、实际全尺寸 RAW/TIFF 导出。`scripts/ExportPanelQA.swift` 已同步默认值与命名断言，本轮未运行。用户实际交互与视觉验收待试用。
