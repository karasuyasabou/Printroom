# Printroom

macOS 原生负片调色工具。一个文件夹是一卷底片；保持 16-bit TIFF 原始样本，卷级片基校准、逐帧调色，使用 Kodak 2383 D65 LUT 输出。

**当前版本：0.2.0。** 提供完整调色、方向、预览直方图和单张/批量多 ICC TIFF 输出。算法仍为 `printroom-density-v1`，项目 schema 2；schema 1 自动迁移为默认方向、P3、无压缩，画面数值不变。

## 运行与构建

打开 [Printroom-0.2.0.app](output/Printroom-0.2.0.app)。新版使用独立包名和应用标识，不替换 0.1.0 应用或偏好设置。本地 Apple Silicon 应用附带 ICC/LUT；无远端、无发布，无需 Photoshop 或额外运行库。

```sh
scripts/build-app.sh              # release 构建、资源打包、ad-hoc 签名
scripts/test.sh                   # 算法、模型、TIFF、输出、异步 UI 集成
scripts/test.sh --full            # 十张实际 TIFF / 全尺寸导出 / Metal
scripts/measure-performance.sh    # release 预览性能与内存记录
scripts/measure-performance.sh --export # 两帧全尺寸批导性能
scripts/viewport-window-qa.sh --release # 真实窗口的视口回归
shasum -a 256 -c assets/SHA256SUMS
```

SwiftPM 项目，可在 Xcode 打开 `Package.swift`。部署目标 macOS 14+、arm64；当前实测 Apple M4 / macOS 26.6.2 / Xcode 26.6 / Swift 6.3.3。旧系统、Intel、更多显示器仍未实机验收。窗口截图需要本机图形会话与系统截图权限。

## 简短验收

1. 打开 TIFF 或胶卷文件夹。框选未曝光片基，整卷显示 95 CV 校准；调节 Timing / Contrast，切换 Identity / LED 矩阵。
2. 复制当前参数，⌘/Shift 多选并应用；⌘Z 一次恢复整组。**W 为 Master +1 CV，S 为 −1 CV**。复制只含 Timing 和 Contrast。
3. 从“方向”菜单旋转/翻转，再撤销/重做；重开胶卷检查恢复。水平/垂直翻转以当前画面为准，重置只清除用户追加方向。
4. 看 RGB / R / G / B 直方图，切换阶段或照片。统计整张降采样预览，Final 为显示器转换前 P3 编码值；域外与非有限值独立计数。
5. 点“1:1”检查原始像素，拖动平移。画面上可框选片基或取样，坐标反映 TIFF 方向校正后的原始像素；适应窗口/双击复位。
6. 在输出面板选择 P3-D65 Gamma 2.6、sRGB、Adobe RGB 或 ProPhoto RGB，以及无压缩/Deflate 无损。导出菜单选择当前、所选或整卷。导出期间继续调色，不改变已固定的任务。取消保留已完成文件，结果逐张列出失败。
7. 缺失照片在 Filmstrip 右键“重新定位”，选择卷内改名后的 TIFF，保留 ID、调色和方向。输出面板可清理本卷缩略图缓存。

## 保存与输出

设置自动保存到卷内 `.printroom.json`。旧项目迁移只增加结构字段；算法不变。损坏或未来 schema 不重置覆盖，外部写入冲突明确报错，保存失败保留内存设置与撤销，可另存/恢复 JSON 设置副本。新版保存 schema 2 后，0.1.0 将拒绝读取该新结构；避免同时用两个版本编辑同一卷。

Final 的 P3-D65 Gamma 2.6 数值按四个固定 ICC 的 matrix/TRC 定义执行相对色度转换，黑点补偿关闭；源 TRC 解码 → D50 PCS 矩阵 → 目标 TRC 反函数，使用 Double 计算，最终统一量化。ProPhoto 使用正确 D50 白点与暗部线性段；色适应包含在 ICC 的 D50 colorants 中。相同 P3 不改变编码值，LUT 后不再添加 Gamma。统一 16-bit RGB TIFF、嵌入 ICC、orientation=1、无抖动。用户方向实际变换输出像素，奇数次 90° 交换宽高。

批量任务固定目标、源指纹、卷级校准、逐帧调色与方向、输出设置；逐张处理，内存不保留全卷原图。禁止覆盖卷内原片，重名自动递增后缀，发布时使用原子无覆盖操作处理竞争。解码前后检测到源文件指纹变化会失败并记录；读完后的导出使用已读取的当前帧样本快照。

## 性能与边界

预览长边 1600，缩略图长边 240；原始取样与 1:1 读取 TIFF 条带中的必要区域。低分辨率源缓存有界，整卷全尺寸数据不常驻；每次全尺寸导出仅保留当前一张 UInt16 原图与有界 Float32 块。1:1 单区域上限 8,388,608 原始像素，超大窗口超限时明确提示，不自动降低精度。磁盘缩略图缓存默认上限 512 MiB、30 天未访问失效，只清理应用拥有的缓存文件。

输入支持 classic TIFF RGB UInt16 条带、无压缩/Deflate、大小端、水平预测、八种 TIFF orientation；暂不支持 BigTIFF、tile、多页、alpha 或其他位深。手动重新定位限定卷内直接子文件。精确扫描标定、LUT Cineon 物理衔接及跨设备色彩外观仍保留验证边界。

具体执行结果、性能数据及未测项见 [0.2.0 验收记录](docs/acceptance-0.2.0.md)。不将数值测试等同于用户审美验收。

## 规范与入口

- [算法与色彩](docs/pipeline.md)：公式与常量的唯一来源。
- [交互](docs/interaction.md)、[架构与迁移](docs/architecture.md)、[验证契约](docs/validation.md)。
- [决策](docs/decisions.md)、[阶段](docs/roadmap.md)、[原始资产清单](assets/manifest.json)。
- `Sources/PrintroomCore`：CPU/Metal、TIFF、ICC、导出、方向、直方图、项目模型。
- `Sources/PrintroomApp`：SwiftUI/AppKit 编辑器、异步预览、区域读取与缓存。

参考 TIFF 从不上传或改写。测试项目、导出、截图均位于 `scratch/`、`output/` 或临时目录；Git 不跟踪这些产物。
