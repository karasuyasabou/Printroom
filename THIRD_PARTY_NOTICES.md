# 第三方说明

Printroom 原创代码与文档采用 GNU GPL 第三版（`GPL-3.0-only`），完整条款见 [LICENSE](LICENSE)。第三方文件保留各自的版权与许可声明，不因顶层许可证而被重新授权。

## LibRaw 0.22.1

Copyright © 2008–2025 LibRaw LLC。Printroom 选择上游提供的 **GNU LGPL 2.1** 许可选项，并以静态库方式构建。上游源文件保持原样。

- [来源与构建说明](ThirdParty/LibRaw/ORIGIN.md)
- [上游版权及内含组件声明](ThirdParty/LibRaw/COPYRIGHT)
- [LGPL 2.1 全文](ThirdParty/LibRaw/LICENSE.LGPL)

LibRaw 中 dcraw、DCB/FBDD、X3F 和 Adobe DNG SDK 片段的原始声明均保留在上游源码和版权文件中。上游另选 CDDL 的文本也原样保留，但不是 Printroom 当前选用的许可路径。

静态链接分发需要提供让接收者修改库并重新构建应用所需的对应源码及构建材料。本仓库保留应用源码、库源码、资源和构建脚本；未来发布二进制时应提供匹配版本的源码。

## Adobe DNG Converter

Adobe DNG Converter 是用户另行安装的外部应用，不包含在 Printroom 仓库或应用包中，使用受 Adobe 自身条款约束。

## 系统组件

Printroom 使用 macOS 提供的系统框架和 zlib，不复制分发这些系统组件。其他附带文件中的既有来源及版权声明保持有效。
