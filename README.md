# Printroom

macOS 原生负片调色工具。一个文件夹是一卷底片；保持 16-bit TIFF 原始样本，卷级片基校准、逐帧调色，使用 Kodak 2383 D65 LUT 输出。

**当前版本：0.3.1。** 裁剪与精细角度按原片坐标保存，多选同步保留每帧方向；⌘/Shift 扩选时保持正在编辑的照片与裁剪草稿。比例为 3:2、4:3、1:1、7:6，可切换横竖；±10°手动旋转、0.1°微调、0.01°输入、网格与自动收边。算法继续 `printroom-density-v2`（685 CV pivot），几何版本 2，项目 schema 3；旧裁剪按原画面迁移，首次覆盖前备份原设置。

## 运行与构建

独立应用包：[Printroom-0.3.1.app](output/Printroom-0.3.1.app)。新版使用独立包名和应用标识，保留 0.1.0/0.2.0/0.3.0 应用和偏好设置。本地 Apple Silicon 应用附带 ICC/LUT；无远端、无发布，无需 Photoshop 或额外运行库。

```sh
scripts/build-app.sh              # release 构建、资源打包、ad-hoc 签名
scripts/test.sh                   # 算法、模型、TIFF、输出、异步 UI 集成
scripts/test.sh --full            # 十张实际 TIFF / 全尺寸导出 / Metal
scripts/measure-performance.sh    # release 预览性能与内存记录
scripts/measure-adjustments.sh    # release 调参准备耗时、连续出图与最终收敛
scripts/measure-performance.sh --export # 两帧全尺寸批导性能
scripts/viewport-window-qa.sh --release # 真实窗口的视口回归
bash scripts/crop-window-qa.sh --release # 裁剪窗口/快捷键/多选同步截图回归
shasum -a 256 -c assets/SHA256SUMS
```

SwiftPM 项目，可在 Xcode 打开 `Package.swift`。部署目标 macOS 14+、arm64；当前实测 Apple M4 / macOS 26.6.2 / Xcode 26.6 / Swift 6.3.3。旧系统、Intel、更多显示器仍未实机验收。窗口截图需要本机图形会话与系统截图权限。

## 简短验收

1. 打开 TIFF 或胶卷文件夹。框选未曝光片基，完成整卷片基校准；调节 Color Timing / Contrast，切换 Identity / LED 矩阵。
2. 复制当前参数，⌘/Shift 多选并应用；⌘Z 一次恢复整组。**W 为 Master +1 CV，S 为 −1 CV**。Timing 单击 1、Shift 单击 10，长按 0.4 秒后固定 50 CV/秒，一次长按一次撤销；范围 ±512。复制只含 Timing 和 Contrast。
3. 从“方向”菜单旋转/翻转，再撤销/重做；重开胶卷检查恢复。水平/垂直翻转以当前画面为准，重置只清除用户追加方向。
4. 按 R 或点击“裁剪”，在单行裁剪栏选择比例、横竖和角度，拖边角调整或在框内移动。Enter/完成提交当前帧，Esc 取消，重置草稿可恢复全图。裁剪过程中用 ⌘/Shift 扩选目标，当前照片、范围锚点和草稿保持；普通点击才切换照片并取消草稿。裁剪栏内的“同步 N 张”整组应用同一原片范围，保留各帧旋转/翻转；一次撤销恢复每帧原状态。已有“复制参数”仍只复制调色。
5. 看预览右上角半透明 RGB / R / G / B 直方图，切换阶段或照片；信息按钮可展开详细统计。统计完整裁后降采样预览，Final 为显示器转换前 P3 编码值；域外与非有限值独立计数。
6. 点“1:1”检查原始分辨率，拖动平移。片基框选会临时恢复完整原片，结束后返回裁后画面；点击读数仍对应 TIFF 方向校正后的原始像素；适应窗口/双击复位。
7. 导出菜单选择当前、所选或整卷，再在导出对话框中选择 P3-D65 Gamma 2.6、sRGB、Adobe RGB 或 ProPhoto RGB，以及无压缩/Deflate 无损。确认才保存选择；取消对话框不改变输出偏好。导出期间继续调色，不改变已固定的任务。取消任务保留已完成文件，结果逐张列出失败。
8. 缺失照片在 Filmstrip 右键“重新定位”，选择卷内改名后的 TIFF，保留 ID、调色和方向。顶部“…”菜单可清理本卷缩略图缓存。

## 保存与输出

设置自动保存到卷内 `.printroom.json`。schema 迁移补充结构字段；白点算法迁移规则见下文，既有非单位反差画面会改变。损坏或未来 schema 不重置覆盖，外部写入冲突明确报错，保存失败保留内存设置与撤销，可另存/恢复 JSON 设置副本。schema 1/2 迁移为无裁剪，首次覆盖保留原 JSON；0.1.0/0.2.0 拒绝 schema 3。0.3.0 的几何版本 1 裁剪按每帧原始尺寸及既有方向转换，保留原画面，覆盖前保存 `.printroom-geometry-v1-UUID.json`；源文件缺失或尺寸不可读时保留旧几何，待恢复后转换。0.3.0 不支持几何版本 2，避免同时用两个版本编辑同一卷。迁移和备份细节见 [架构规范](docs/architecture.md#031-项目裁剪与资源)。

Final 的 P3-D65 Gamma 2.6 数值按四个固定 ICC 的 matrix/TRC 定义执行相对色度转换，黑点补偿关闭；源 TRC 解码 → D50 PCS 矩阵 → 目标 TRC 反函数，使用 Double 计算，最终统一量化。ProPhoto 使用正确 D50 白点与暗部线性段；色适应包含在 ICC 的 D50 colorants 中。相同 P3 不改变编码值，LUT 后不再添加 Gamma。统一 16-bit RGB TIFF、嵌入 ICC、orientation=1、无抖动。用户方向实际变换输出像素，奇数次 90° 交换宽高。裁剪按原始像素确定输出尺寸；零角整数裁剪保留样本，非零角从原线性样本一次双线性插值后执行调色。原 TIFF 不改写，也不因连续调角度重复处理已旋转图像。

批量任务固定目标、源指纹、卷级校准、逐帧调色、方向与裁剪、输出设置；逐张处理，内存不保留全卷原图。禁止覆盖卷内原片，重名自动递增后缀，发布时使用原子无覆盖操作处理竞争。解码前后检测到源文件指纹变化会失败并记录；读完后的导出使用已读取的当前帧样本快照。

## 性能与边界

连续调参使用单在途、单待办预览，复用 GPU 缓冲及 D1 前段结果；直方图在最终预览稳定后更新，缩略图仅刷新受影响帧。预览长边 1600，缩略图长边 240；原始取样与 1:1 读取 TIFF 条带中的必要区域。低分辨率源缓存有界，整卷全尺寸数据不常驻；每次全尺寸导出仅保留当前一张 UInt16 原图与有界 Float32 块。1:1 单区域上限 8,388,608 原始像素，超大窗口超限时明确提示，不自动降低精度。磁盘缩略图缓存默认上限 512 MiB、30 天未访问失效，只清理应用拥有的缓存文件。

输入支持 classic TIFF RGB UInt16 条带、无压缩/Deflate、大小端、水平预测、八种 TIFF orientation；暂不支持 BigTIFF、tile、多页、alpha 或其他位深。手动重新定位限定卷内直接子文件。精确扫描标定、LUT Cineon 物理衔接及跨设备色彩外观仍保留验证边界。

本轮原片坐标、多选与界面更新的验证状态见 [0.3.1 验收记录](docs/acceptance-0.3.1.md)；未经执行的项目保留待验证。此前证据保留在 [0.3.0 验收记录](docs/acceptance-0.3.0.md) 与 [0.2.0 验收记录](docs/acceptance-0.2.0.md)，不自动视作本轮通过，也不将数值测试等同于用户审美验收。

## 规范与入口

- [算法与色彩](docs/pipeline.md)：公式与常量的唯一来源。
- [交互](docs/interaction.md)、[架构与迁移](docs/architecture.md)、[验证契约](docs/validation.md)。
- [决策](docs/decisions.md)、[阶段](docs/roadmap.md)、[原始资产清单](assets/manifest.json)。
- `Sources/PrintroomCore`：CPU/Metal、TIFF、ICC、导出、方向、直方图、项目模型。
- `Sources/PrintroomApp`：SwiftUI/AppKit 编辑器、异步预览、区域读取与缓存。

参考 TIFF 从不上传或改写。测试项目、导出、截图均位于 `scratch/`、`output/` 或临时目录；Git 不跟踪这些产物。

白点 pivot 试用包：`output/Printroom-0.2.0-WhitePoint.app`。旧项目按用户选择迁移到白点算法；首次覆盖前保留同卷 `.printroom-density-v1-UUID.json` 原设置备份。已有反差不为 1 的通道外观会变化，旧版应用拒绝新版算法项目。
