# Printroom

macOS 原生负片调色工具，以文件夹为单位管理一卷底片，完成片基校准、逐帧调色、裁剪和批量导出。

## 功能

- 16-bit TIFF / Sony ARW 导入，自动保存胶卷设置。
- 卷级矩阵与片基校准，逐帧 Timing / Contrast，中性点吸管和整卷色罩分析。
- Kodak 2383 / Fujifilm 3513DI 外观，简易与 RGB 调色模式。
- 自动及手动裁剪、旋转翻转、多选同步、整组撤销。
- 16-bit TIFF / 8-bit JPG 导出，五种输出色彩空间。

## 运行要求

Apple Silicon Mac，部署目标 macOS 14 或更新版本；暂不支持 Intel。最低系统版本是构建目标，不代表所有系统和显示设备均已实机验证。

使用 ARW 需要安装 `/Applications/Adobe DNG Converter.app`。TIFF 不依赖 Adobe；应用运行无需 Python、Go 或 rawpy。

当前工程版本为 **0.3.69**。

## 从源码构建

安装 Xcode 和命令行工具，使用 Swift 6 工具链，在仓库根目录执行：

```sh
scripts/build-app.sh
```

构建结果为 `output/Printroom.app`。脚本在资源和本地签名验证成功后替换同一路径的旧应用。项目使用 SwiftPM，也可在 Xcode 中打开 `Package.swift`。

## 开始使用

打开底片文件夹，框选片基，调整调色与裁剪，再导出当前照片、所选照片或整卷。设置自动保存到胶卷目录中的 `.printroom.json`，原片不会被改写。

- [使用指南](docs/user-guide.md)：常用操作、快捷键与保存。
- [参与开发](CONTRIBUTING.md)：构建、验证和技术规范。

## 许可

Printroom 原创代码与文档采用 **GNU GPL 第三版（GPL-3.0-only）**，详见 [LICENSE](LICENSE)。第三方组件保留各自声明，见 [第三方说明](THIRD_PARTY_NOTICES.md)。
