# 参与开发

## 环境与构建

使用 Mac、Xcode 和 Swift 6 工具链。部署目标为 macOS 14+，提供 arm64 与 x86_64 构建。已记录的构建环境为 Apple M4、macOS 26.6.2、Xcode 26.6、Swift 6.3.3，这不代表已验证全部部署系统。

项目使用 SwiftPM，LibRaw 0.22.1 源码随仓库提供，正常构建无需下载第三方依赖：

```sh
scripts/build-app.sh
# 指定目标架构（交叉编译不运行目标应用）
scripts/build-app.sh --arch x86_64
```

脚本生成 `output/Printroom.app`，验证成功后替换旧包。当前使用本地 ad-hoc 签名；运行包内资源检查需要可用的 Metal 设备。

## 验证

在仓库根目录运行默认回归：

```sh
scripts/test.sh --build-system native --no-parallel --skip 'NativeDialogTests|PreviewCanvasTests'
scripts/test.sh --build-system native --no-parallel --filter NativeDialogTests
scripts/test.sh --build-system native --no-parallel --filter PreviewCanvasTests
```

测试包含 AppKit／Metal 集成；原生对话框与预览画布分进程运行，其余测试串行执行以避免套件争用；应在可用的本机图形环境运行。默认测试不要求私人参考照片，需额外素材或环境的测试会自动跳过。

如需包含本地参考 TIFF 的完整校验（需要 `TEST/TIFF/` 参考照片）：

```sh
scripts/test.sh --full --build-system native --no-parallel
```

## 实现与规范

- [算法与色彩管线](docs/pipeline.md)：公式、常量、采样、几何和输出契约。
- [交互](docs/interaction.md)：选择、同步、裁剪、撤销和保存语义。
- [架构与项目数据](docs/architecture.md)：模块所有权、异步发布与迁移。

核心在 `Sources/PrintroomCore`，界面在 `Sources/PrintroomApp`，本地 RAW 桥接在 `Sources/CRawBridge`。测试位于 `Tests`。算法与项目格式变化需要明确版本策略；CPU 参考与 Metal 保留独立实现，并验证数值一致性。

## 提交约定

- 保持改动聚焦，说明用户可见变化、验证结果及未完成事项。
- 不覆盖原始 `TEST/`、`ICC/`、`LUT/`；测试卷、缓存、导出和截图放在 `scratch/`、`output/` 或临时目录。原始资产说明见 [assets/README.md](assets/README.md)。
- 不提交私人照片、用户胶卷设置、生成的应用和缓存。工程过程记录及个人代理指令由维护者本地保存，不是克隆后构建的前置条件。
- 对原创部分的贡献按项目 [GPL-3.0-only](LICENSE) 提供；第三方代码保留原有版权及许可，新增依赖需记录来源。

以后分发应用二进制时，应同时提供与该二进制对应的完整源码及构建材料，包括本项目源码、LibRaw、构建脚本、所需资源和许可证。仅随包附带 LibRaw 源码不足以代替整个应用的对应源码。
