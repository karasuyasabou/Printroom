<p align="center">
  <img src="assets/AppIcon/Printroom.iconset/icon_128x128@2x.png" width="104" alt="Printroom 图标">
</p>

<h1 align="center">Printroom</h1>

<p align="center">
  <strong>从一卷底片，到一组照片。</strong><br>
  macOS 原生负片调色工具 · 片基校准、逐帧调色与批量导出
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-242424?style=flat-square&amp;logo=apple&amp;logoColor=white" alt="macOS 14 或更新版本">
  <img src="https://img.shields.io/badge/Apple_Silicon-arm64-C4A462?style=flat-square" alt="Apple Silicon arm64">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0--only-C4A462?style=flat-square" alt="许可证 GPL-3.0-only"></a>
</p>

<p align="center">
  <a href="docs/user-guide.md">使用指南</a> ·
  <a href="#从源码构建">从源码构建</a> ·
  <a href="https://github.com/karasuyasabou/Printroom/issues">问题反馈</a>
</p>

<p align="center">
  <img src="docs/images/printroom-editor.png" width="100%" alt="Printroom 深色编辑界面：照片预览、密度直方图、片基校准与调色面板，以及整卷缩略图">
</p>
<p align="center"><sub>整卷校准，逐帧调色。让一卷照片在同一个工作流中完成。</sub></p>

## 为整卷底片而设计

- **按卷管理** — 打开一个文件夹就是一卷底片，支持 16-bit TIFF 与 Sony ARW，编辑设置自动保存，原片保持不变。
- **从校准到调色** — 卷级矩阵与片基校准，逐帧 Timing / Contrast；提供简易与 RGB 模式、中性点吸管和整卷色罩分析。
- **选择印片外观** — 内置 Kodak 2383 与 Fujifilm 3513DI 外观，配合曝光、色彩与反差调整。
- **连贯的批量操作** — 自动及手动裁剪、旋转翻转、多选同步与整组撤销；导出 16-bit TIFF 或 8-bit JPG，支持五种输出色彩空间。

## 开始使用

**打开底片 → 选择矩阵并框选片基 → 调色与裁剪 → 导出照片**

可导出当前照片、所选照片或整卷。设置自动保存在胶卷目录的 `.printroom.json` 中，下次打开即可继续编辑。

操作说明与快捷键见 [使用指南](docs/user-guide.md)。

## 运行要求

- **Apple Silicon Mac，macOS 14 或更新版本**，暂不支持 Intel。最低系统版本是构建目标，不代表所有系统和显示设备均已实机验证。
- **Sony ARW** 需要安装 `/Applications/Adobe DNG Converter.app`。TIFF 不依赖 Adobe；应用运行无需 Python、Go 或 rawpy。

当前工程版本为 **0.3.69**，暂未提供正式发行包，可从源码构建。

## 从源码构建

安装 Xcode 和命令行工具，使用 Swift 6 工具链：

```sh
git clone https://github.com/karasuyasabou/Printroom.git
cd Printroom
scripts/build-app.sh
```

构建结果为 `output/Printroom.app`。脚本在资源和本地签名验证成功后替换同一路径的旧应用。项目使用 SwiftPM，也可在 Xcode 中打开 `Package.swift`。

开发与验证说明见 [参与开发](CONTRIBUTING.md)。如遇问题，欢迎提交 [Issue](https://github.com/karasuyasabou/Printroom/issues)，附上系统版本、输入格式与复现步骤。

## 许可

Printroom 原创代码与文档采用 **GNU GPL 第三版（GPL-3.0-only）**，详见 [LICENSE](LICENSE)。第三方组件保留各自声明，见 [第三方说明](THIRD_PARTY_NOTICES.md)。
