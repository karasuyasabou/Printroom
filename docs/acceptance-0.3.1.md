# Printroom 0.3.1 验收记录

日期：2026-09-08。版本 0.3.1 / build 1，实现起点 `63d76db`，最终源码由本记录所在的本地提交确定。算法继续 `printroom-density-v2` / 685 CV，项目 schema 3，裁剪几何版本 2。测试环境为 Apple M4、arm64、macOS 26.6.2；本地验证，无远端或发布。

## 变更

- 裁剪保存于 TIFF 方向校正后的原片坐标，用户旋转/翻转独立生效；同步同一原片范围，按目标原始尺寸适配。模型、预览、1:1、取样、导出共用几何，具体契约见 pipeline.md §14。
- 旧几何按各帧原始尺寸和旧方向转换，保持画面；首次覆盖前备份原 JSON。缺失原片保留旧几何，重连和设置副本恢复使用实际原始尺寸转换。
- Filmstrip 的 ⌘/Shift/⌘Shift 操作只改变同步目标，保留 active、anchor、草稿及预览。普通点击切换照片；⌘ 当前帧保持选中。
- 裁剪栏精简为单行，上方工具栏的重复“同步”菜单已移除。保留四比例、横竖、角度调节、重置、取消、同步与完成。

## 已执行验证

| 命令 | 实际结果 |
| --- | --- |
| `scripts/test.sh --full -c release` | **120 项核心测试全部通过，59 项应用功能测试通过**。3 项按开关启用的性能量测未执行，不计入通过数。核心 16.374 秒，应用 6.874 秒；日志 `scratch/crop-source-full-tests.log`。 |
| `shasum -a 256 -c assets/SHA256SUMS` | **12/12 原始资产匹配**，十张 TIFF、ICC 与 LUT 不变；日志 `scratch/crop-source-asset-hashes.log`。 |
| `scripts/build-app.sh` | 独立 `output/Printroom-0.3.1.app` 构建成功，四 ICC/LUT 资源、Metal Apple M4 与 UInt16 SDR 展示格式验证通过；日志 `scratch/crop-source-build-app.log`。 |
| `codesign --verify --deep --strict --verbose=2 output/Printroom-0.3.1.app` | valid on disk / satisfies its Designated Requirement；日志 `scratch/crop-source-signature.log`。 |
| `bash scripts/crop-window-qa.sh --release --skip-build --layout-only` | **布局截图检查通过**：1060×720 窗口、753 px 预览列、38 px 单行裁剪栏。所有控件完整可见，无顶部重复同步菜单。日志 `scratch/crop-layout-only-qa.log`，截图 `scratch/crop-qa/layout-only-minimum-window.png`。该模式直接设置模型，不运行真实键鼠事件。 |

新增核心测试覆盖：八种 D4 下偏心非对称裁剪、0°及正负精细角度、原片先裁剪再排列像素的一致性、旧版迁移保画面、显示与原片坐标往返、不同源尺寸同步。合成 TIFF 批导覆盖全部八种用户方向并回读像素；现有四 ICC、两种压缩、CPU/Metal 数值、1:1/ROI、十张实际 TIFF 保真等回归一并通过。

新增应用测试覆盖：以旋转或反射照片为同步来源，八方向完整预览缓冲区对照；⌘/Shift/⌘Shift 保留 active、anchor、CGImage 身份、视口和草稿；显示角度反号与横竖换算；旧裁剪转换前后完整像素、首次保存原 JSON 字节备份与重复保存；缺失源重连及设置副本恢复。最小窗口单行布局测试通过。

实际 `TEST/DSC07079.tiff` 只读，7:6 / 3.17°裁剪导出 **5124×4392 sRGB Deflate 16-bit TIFF**，5.128 秒，129,015,490 bytes。8 个独立解析检查点回读最大差异 **0 个 UInt16 阶**，源 SHA256 前后相同；这是稀疏解析检查，不代表全图逐像素比较。测试输出位于临时目录并自动清理。

首次编译时新增测试中的复杂 SIMD 表达式触发 Swift 类型检查超时；拆分表达式后完整回归通过，未放宽数值容差。

## 窗口与交付状态

应用打包与签名已完成，旧版应用保留。真实键鼠回归首次在 R 键断言处中断；增加状态检查后确认 `frontmost=loginwindow`、`activeApp=false`、`key=false`，测试窗口可见且照片加载正常，但锁屏会话不能获得键盘焦点。该轮不计为真实点击通过；完整回归需解锁后运行 `bash scripts/crop-window-qa.sh --release`。模型多选与布局测试的通过不替代这项实际事件验收。

已查看专用布局模式的测试窗口截图，裁剪栏四比例入口、横竖按钮、角度控件、重置、取消、同步和完成完整保留，未出现换行或截断；画面遮罩、网格与 Filmstrip 正常呈现。截图仅取本地测试窗口，输入为 scratch 中的参考 TIFF 副本。

## 边界

本轮未重新量测持续性能与内存基准，也未进行其他显示器、旧 macOS 或 Intel 实机测试。用户日常拖动与微调手感仍待试用；数值回归不代表色彩审美验收。几何版本 2 项目不能用 0.3.0 读取，迁移前原设置备份规则见 architecture.md。
