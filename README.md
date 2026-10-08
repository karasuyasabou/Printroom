<p align="center">
  <img src="assets/AppIcon/Printroom.iconset/icon_128x128@2x.png" width="104" alt="Printroom 图标">
</p>

<h1 align="center">Printroom</h1>

<p align="center">macOS 原生负片调色工具，从整卷片基校准、逐帧调色到批量导出。</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-242424?style=flat-square&amp;logo=apple&amp;logoColor=white" alt="macOS 14 或更新版本">
  <img src="https://img.shields.io/badge/macOS-arm64%20%7C%20x86__64-C4A462?style=flat-square" alt="Apple Silicon 与 Intel">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0--only-C4A462?style=flat-square" alt="许可证 GPL-3.0-only"></a>
</p>

<p align="center">
  <a href="docs/user-guide.md">使用指南</a> ·
  <a href="#从源码构建">从源码构建</a> ·
  <a href="https://github.com/karasuyasabou/Printroom/issues">问题反馈</a>
</p>

<p align="center">
  <img src="docs/images/printroom-editor.png" width="100%" alt="Printroom 编辑界面：照片预览、密度直方图、调色面板与底部缩略图">
</p>

## 下载与安装

要求 **macOS 14 或更新版本**。

[下载 Printroom v1.0.0](https://github.com/karasuyasabou/Printroom/releases/tag/v1.0.0)

- **Apple Silicon（M 系列）**：下载 `Printroom-v1.0.0-macOS-arm64.zip`。
- **Intel**：下载 `Printroom-v1.0.0-macOS-x86_64.zip`。

解压后将 `Printroom.app` 拖入“应用程序”。应用未使用 Developer ID 签名或 Apple 公证；首次打开若被 macOS 拦截，请在尝试打开后前往“系统设置 → 隐私与安全性”，找到 Printroom 并选择“仍要打开”。

RAW 输入需要另行安装 [Adobe DNG Converter](https://helpx.adobe.com/camera-raw/using/adobe-dng-converter.html)；TIFF 不依赖 Adobe。

## 主要功能

- **按卷管理**：支持线性 16-bit RGB TIFF 与常见品牌 RAW，编辑设置自动保存，原片保持不变。
- **校准与调色**：卷级矩阵、片基校准、色罩分析，逐帧 Timing / Contrast 与中性点吸管。
- **印片外观**：内置 Kodak 2383 与 Fujifilm 3513DI。
- **批量处理**：自动及手动裁剪、齿孔置白、多选同步、整组撤销，以及五种色彩空间的 TIFF / JPG 导出。

## 快速开始

1. 打开底片文件夹，运行自动裁剪并检查裁框。
2. 确认矩阵设置，框选干净、未曝光的片基区域。
3. 运行色罩分析，应用整卷基础调色后逐张精调。
4. 导出当前照片、所选照片或整卷。

详细操作、支持格式、快捷键和调色原理见 **[使用指南](docs/user-guide.md)**。

## 从源码构建

安装 Xcode 和命令行工具，使用 Swift 6 工具链：

```sh
git clone https://github.com/karasuyasabou/Printroom.git
cd Printroom
scripts/build-app.sh
```

构建结果为 `output/Printroom.app`，也可在 Xcode 中打开 `Package.swift`。

开发与验证说明见 [参与开发](CONTRIBUTING.md)。如遇问题，欢迎提交 [Issue](https://github.com/karasuyasabou/Printroom/issues)，附上系统版本、输入格式与复现步骤。

## 项目支持

项目由个人持续维护，若对后期工作流程有帮助，可以支持作者：

<p align="center">
  <img src="docs/images/support-alipay.jpeg" width="280" alt="支付宝收款码，支持 Printroom 作者">
</p>

## 许可

Printroom 原创代码与文档采用 **GNU GPL 第三版（GPL-3.0-only）**，详见 [LICENSE](LICENSE)。第三方组件保留各自声明，见 [第三方说明](THIRD_PARTY_NOTICES.md)。
