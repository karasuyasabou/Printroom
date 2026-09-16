# 0.3.8 BigTIFF 输入验收

日期：2026-09-09。Apple Silicon / 本机 macOS，SwiftPM；工作区包含此前版本未提交修改，本轮未覆盖这些修改或创建远端。版本 0.3.8、构建 1，交付固定 `output/Printroom.app`。算法 density-v3、schema 5、几何版本 2 保持不变。

## 变更

共享 TIFFReader 支持 classic 42 / BigTIFF 43，按格式读取目录计数、目录项、内联载荷和外部 64 位地址，支持 LONG8 条带偏移/字节数。错误版本与非法 BigTIFF 文件头分别报错；校验目录计数、整数转换、文件地址和样本尺寸，避免溢出。完整读取、缩略预览、ROI / 1:1 共用原有条带解压、水平预测与方向处理。格式约束唯一来源为 pipeline.md 的 BigTIFF 输入节。

## 数值与边界证据

- 新增 4 个 XCTest：大小端 × compression 1/8/32946 × predictor 1/2 × 8 种方向，共 96 组合，逐样本对照已有 classic 已知 UInt16 测试图；同时比较 metadata、ICC 描述、preview 与 ROI。
- 大小端稀疏 BigTIFF：目录、ICC、条带偏移均超过 2^32；完整读取与 ROI 保持已知样本。
- 65536×11000 RGB16 稀疏 BigTIFF：样本总量 4,325,376,000 字节，metadata、1 像素 preview、最后一个像素 ROI 成功；按所需条带读取，未完整分配大图。
- 无效版本、偏移宽度、保留字段、截断文件头、溢出目录/载荷数量均抛出错误。
- 原始 TEST/TIFF、ICC、LUT 的 `shasum -a 256 -c assets/SHA256SUMS`：12 项全部 OK。

## 执行记录

初次沙箱执行 `scripts/test.sh --full --filter 'TIFFCodecTests|OrientationHistogramTests|Export'`：TIFFCodecTests 15 项全部通过（含十张真实 TIFF 与独立 Python/zlib 样本哈希对照、7008×4672 全尺寸输出回读）；依赖 Metal 的集成测试因沙箱无法创建 Metal 上下文失败。初次沙箱打包也在资源验证的同一环境限制处退出，旧包保留。随后以可访问 Metal 的执行环境重跑同一验证与 `scripts/build-app.sh`，最终结果见下方。

最终可访问 Metal 的重跑结果：

- XCTest 45 项，43 项通过、2 项真实 RAW 集成按环境开关跳过、0 失败；Swift Testing 中 2 项编辑器导出集成通过，1 项批导性能测量跳过。
- 7008×4672 实际参考管线导出成功，采样 CPU 对照最大误差 7.748604e-06，ICC 字节完全一致。
- `scripts/build-app.sh` 退出 0，包内 ICC/LUT 与四输出 profile 验证通过；Metal Apple M4 渲染及 UInt16 SDR 展示验证通过。签名检查通过后替换唯一交付包。
- 替换后独立检查 `CFBundleShortVersionString=0.3.8`，`codesign --verify --deep --strict output/Printroom.app` 与 `git diff --check` 均退出 0。

## 未验证与保留边界

没有取得截图中出错文件的路径，尚未对该具体文件人工验收；BigTIFF 使用独立合成格式测试，真实相机参考输入是 classic TIFF。未进行新增窗口视觉验收。未验证超过 4 GiB 图像的全尺寸解码或导出；完整读取及单条带仍需要相应内存。输出继续 classic TIFF，超过 4 GiB 拒绝。tile、LZW、多页、alpha、其他位深仍未支持。本轮没有重跑与读取器无关的 RAW 并行、矩阵编辑等完整验收，不将历史结果计作本轮通过。
