# 0.3.66 导出复选项验收

日期：2026-09-28。删除“恢复胶卷名”按钮及恢复处理；ZIP压缩改复选框，仅TIFF显示。新增“应用裁剪”，TIFF/JPG共用，初始勾选并按卷记忆；关闭时忽略裁剪范围与微调角度，保留独立旋转/翻转，照片裁剪记录与预览不变。规则见interaction.md、pipeline.md；字段兼容见architecture.md。

## 已执行

- `scripts/test.sh --build-system native --filter 'ExportColorTests|ExportProfileOptionsTests'`：23项XCTest及4项Swift Testing通过。首次沙盒执行因临时目录访问限制失败，授权后在本机环境重跑通过。
- 新增两种格式、全部八种D4方向的合成TIFF导出回读：关闭裁剪（含4度微调）与无裁剪参考导出文件逐字节相同；开启裁剪尺寸减小；导出请求冻结设置、帧裁剪与源文件保持。既有ICC、ZIP、并发、取消和重名保护测试通过。
- 面板测试覆盖默认勾选、修改草稿不改初始设置、序列化重开、旧字段缺省启用，以及JPG隐藏压缩而保留应用裁剪。
- `bash scripts/editor-window-qa.sh --skip-build --export-layout`：两种格式的AppKit选项面板截图目视检查通过，文字及复选框完整可见，前缀输入框无恢复按钮。截图在scratch/editor-ui-qa/0352-export-tiff.png及0352-export-jpeg.png。脚本有既有主工具栏自动测量警告，导出选项截图未见布局缺失。
- `scripts/build-app.sh`：release编译、包内ICC/LUT和五项输出profile、Apple M4 Metal与预览自检、ad-hoc签名验证通过，成功覆盖output/Printroom.app，包内版本0.3.66、构建1，应用名称及标识保持。
- `git diff --check`通过。

## 边界

本轮未执行真实RAW全尺寸导出、人工点击完整导出对话框或深色外观截图验收。自动导出回读使用临时合成TIFF，不修改用户胶卷和原始资产。旧应用不认识applyCrop字段，仍按其既有方式应用裁剪。
