# 0.3.54 验收记录（2026-09-19）

导出重名逐个询问覆盖、自动重命名或取消；原片保护保持。说明文字清理范围见 interaction.md。图像算法、项目 schema 与并发上限不变。

## 已执行

- `scripts/test.sh --build-system native --filter 'ExportColorTests|ExportProfileOptionsTests'`：沙盒外22项XCTest及2项Swift Testing通过。覆盖TIFF/JPG的覆盖、选否改名、取消、原片保护；覆盖写入中途取消保留旧文件并清理临时目录；既有发布竞争、四路导出、ICC和选项草稿回归通过。日志 `/tmp/printroom-export-test-local.log`。
- `scripts/build-app.sh`：release构建、包内ICC/LUT与五种输出profile、Metal Apple M4渲染、预览资源和严格签名验证通过，替换 `output/Printroom.app`，版本0.3.54/构建1。日志 `/tmp/printroom-build-0.3.54-local.log`。
- `git diff --check`通过。

沙盒内首次测试因临时卷目录读取受限失败，初次打包因无法创建Metal上下文未替换旧包；上述沙盒外重跑通过。

## 待验证

真实窗口重名弹窗的点击流程与文字清理后的视觉效果尚未人工验收；不将核心决策回调测试等同于真实窗口验收。
