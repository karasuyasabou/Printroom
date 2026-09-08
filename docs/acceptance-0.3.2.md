# Printroom 0.3.2 验收记录

日期：2026-09-08。本机 Apple M4、macOS 26.6.2（25G83）、Swift 6.3.3、arm64。独立 `output/Printroom-0.3.2.app`，初版构建号 1，当前构建号 2 的增量验证见末节；bundle ID `studio.printroom.local.v3.2`。算法 `printroom-density-v2`、schema 3、几何版本 2、展示格式 `sdr-uint16-v1` 不变。此记录随实现一并提交，本地提交可通过 `git log -1` 查看。

## 交付范围

- 同上下文调参保持上一份直方图，完成后直接替换；无转圈。密度阶段显示 CV 坐标与轻淡参考数字，其他阶段保留原坐标。
- 顶部重置、Color Timing 中性点吸管；删除普通点击读数、读数条及底部常驻状态栏。保存失败重试及导出进度/取消改为顶部按需呈现。
- 全窗口调色键，Filmstrip 点击结束文本编辑后可直接使用；Option 调反差，Shift 不放大反差步长，长按与撤销行为见 interaction.md。
- 原片邻域 D3 求解，保持平均密度并仅修改 RGB Timing；失败整次保留参数。公式、有效像素与整数误差边界见 pipeline.md §15。
- 有界主预览 LRU 与匹配缩略图占位，正式画面原位替换，精确操作不使用占位图。

## 已执行验证

| 命令/证据 | 结果 |
| --- | --- |
| `scripts/test.sh --full -c release`，本机权限运行，日志 `scratch/refinement-full-tests-local.log` | 130 项核心测试全部通过，包括 10 项新增中性点测试、十张实际 TIFF、CPU/Metal、ICC/导出回读；随后应用测试暴露吸管撤销分组异常，见下文修复及最终应用回归 |
| `scripts/test.sh --full -c release --filter PrintroomAppTests`，日志 `scratch/refinement-app-tests-final.log` | 共发现 74 项，71 项应用功能测试通过，3 项显式性能量测跳过；实际 TIFF 全尺寸参考导出通过 |
| `scripts/build-app.sh`，日志 `scratch/refinement-build.log` | release 构建、打包、ad-hoc 签名通过；独立应用实际执行资源验证，四 ICC、LUT、Apple M4 Metal 和 UInt16 展示格式通过 |
| `codesign --verify --deep --strict --verbose=2 output/Printroom-0.3.2.app`；`plutil -lint output/Printroom-0.3.2.app/Contents/Info.plist` | 签名与 plist 通过，bundle ID 已核对 |
| `shasum -a 256 -c assets/SHA256SUMS`，日志 `scratch/refinement-assets.log` | 12 项原始 TIFF/ICC/LUT 哈希全部通过 |

首次受限运行无法创建 Metal 上下文及访问系统文件协调服务，不能作为图像测试证据；上述通过记录来自已获自动批准的本机运行。新增测试还发现吸管在关闭撤销分组后命名动作会触发 NSUndoManager 异常，已改为在原 edit 事务内命名；最终应用回归包含成功取样、一次撤销/重做及保存重开。旧切帧测试要求 `previewImage == nil`，已按用户要求改为验证匹配缩略图占位。

## 覆盖内容

数值测试以独立 Double 解析值检验默认及非单位反差、LED/片基校准、偶数中位数、颗粒与离群点、剪切多数、参数极限及非法值；每通道整数误差满足既定有效反差界，普通数值附加 0.002 CV 浮点测试容差，不把该值扩展为所有异常校准下的全局上限。

应用测试覆盖裁剪后顺时针方向的原片邻域映射、非当前帧不变、撤销/重做与重开恢复、取样等待中调参/切帧丢弃、普通点击不取样及窗外释放保护；直方图保留/最终收敛/跨阶段失效，缩略图先显/主预览缓存优先/正式替换/源修改失效与 LRU 容量。快捷键测试覆盖所有正负通道、Option 死键、Shift 不放大、长按整组撤销、边界及切帧/裁剪/失焦停止。

窗口路由自动测试使用真实 NSWindow/NSTextView responder 和显式事件来源窗口，属于路由集成覆盖，不等同系统键鼠验收。

## 窗口截图

通过 `bash scripts/editor-window-qa.sh --release --skip-build` 编译自有测试窗口；受限环境无法截图后，在本机权限下运行 `scratch/editor-ui-qa/window-qa`。使用合成图和内存项目，不修改原始资产，不要求窗口激活。

- `scratch/editor-ui-qa/01-final-minimum-window.png`：最小 1060×720 内容窗口，顶部重置/复制等按钮完整，两条旧栏已删除。
- `scratch/editor-ui-qa/02-density-neutral-minimum-window.png`：CV 轴和参考数字无重叠，细线轻淡，吸管激活态可辨。
- `scratch/editor-ui-qa/03-export-save-status-minimum-window.png`：保存失败与导出并存时顶部重试/进度/取消均完整。

上述三张真实 WindowServer 截图已逐张查看。最小高度下调色面板保持滚动，未强行压缩全部滑杆。

## 真实窗口键鼠事件回归

`bash scripts/editor-window-qa.sh --release --skip-build --keyboard` 为可复跑入口。本轮以 `swiftc` 直接编译后，在已解锁图形会话运行 `scratch/editor-ui-qa/window-qa --keyboard`，只激活并操作自有测试窗口，使用 scratch 中三张合成 TIFF。

结果：事件队列点击第二张 Filmstrip 后 W 使 Master Timing +1；Option E（包含死键字符）使 Red Contrast +0.01，Option+Shift E 仍只 +0.01；实际数值输入框接收 W/⌘A，参数和选片未被快捷键误改；点击实际吸管按钮后 Esc 取消；前一帧参数保持默认。通过 NSApp 事件队列发送鼠标和按键，未直接调用模型或路由来代替该项窗口验收。

日志 `scratch/editor-ui-qa/keyboard.log`，截图 `scratch/editor-ui-qa/04-keyboard-regression.png`，均已检查。首次脚本未能定位 SwiftUI AX Filmstrip 子节点，修正控件定位后全部通过、exit 0；应用实现未因该脚本调整而变更。

## 未执行或人工边界

- 三项 release 性能量测本轮未运行；未宣称新的帧率、冷启动耗时或峰值内存成绩。
- 用户实际吸管选点效果、连续长按手感、其他 macOS/Intel/显示设备未人工验收。

交付核对：既有 0.2.0、0.3.0、0.3.1 应用仍在 output/；原始 TIFF/ICC/LUT 未改写或上传。本轮无远端、推送或发布。

## 构建号 2：工具指针与 I 快捷键

吸管显示黑色白描边图标，尖端为热点；片基框选显示系统十字。预览使用 AppKit tracking area 处理移入、移动和 cursorUpdate，工具状态更新后主动刷新静止指针。刷新避开 SwiftUI 更新过程，排除直方图等覆盖控件；取消、取样结束和移出预览恢复正常指针。I 开启/取消，自动重复不切换，保留文本/弹窗/失焦与片基/裁剪互斥规则。

| 命令/证据 | 本次结果 |
| --- | --- |
| `scripts/test.sh -c release --filter 'EditorKeyboardRoutingTests\|PreviewCanvasTests\|EditorRefinementTests'`；`scratch/cursor-shortcut-tests-final.log` | 16 项相关测试通过，覆盖路由边界、预览手势、吸管原片映射/撤销与过期取样保护 |
| `bash scripts/editor-window-qa.sh --release --skip-build --keyboard` 编译；本机运行 `scratch/editor-ui-qa/window-qa --keyboard`；`scratch/cursor-shortcut-window-final.log` | 自有真实 EditorView 窗口的事件队列验证通过：按钮与 I 开启、I/Esc 取消、长按不重复、静止指针更新、预览移出/重入、实际吸取后恢复、片基十字/取消与互斥、输入框接收 I；既有 W/Option 调色回归通过 |
| `scripts/build-app.sh`；`scratch/cursor-shortcut-build.log` | release 编译、打包与签名完成；资源自检因受限环境无法创建 Metal 而退出，随后单独本机运行新版 `--verify-resources` 通过，日志 `scratch/cursor-shortcut-resources.log` |
| `codesign --verify --deep --strict --verbose=2 output/Printroom-0.3.2.app`；`plutil -lint output/Printroom-0.3.2.app/Contents/Info.plist` | 通过；构建号 2 |
| `shasum -a 256 -c assets/SHA256SUMS`；`scratch/cursor-shortcut-assets.log` | 12/12 原始资产通过 |

初次实际窗口检查暴露同步 hitTest 引起的 SwiftUI 布局循环日志，已改为界面更新结束后刷新；最终窗口日志无此循环。最终截图 `scratch/editor-ui-qa/04-keyboard-regression.png` 和指针图 `scratch/editor-ui-qa/05-neutral-cursor.png` 已查看。受限运行无法访问 Metal/文件协调服务的失败不计为通过；上述图像与窗口结果来自本机权限运行。

保留原构建 `output/Printroom-0.3.2-build1.app` 与所有既有旧版。本次仅修改工具指针、快捷键与帮助文字；未重跑全尺寸导出/CPU-Metal 全套数值或性能量测，跨设备及用户手感仍待试用。

## ⌘C / ⌘V 快捷键补记（2026-09-08）

- 窗口内复制/应用参数改用 ⌘C/⌘V，长按不重复，文字输入保留原生复制/粘贴；菜单及按钮帮助同步提示。
- 为避开并行性能/吸管修改，以 HEAD 加本轮快捷键代码隔离构建 `output/Printroom-0.3.2-Shortcuts.app`（构建号 3），保留原应用。
- 隔离副本运行 `scripts/test.sh --filter 'EditorKeyboardRoutingTests|EditorIntegrationTests'`：15 项通过，覆盖快捷键快照、重复按键抑制、文本焦点、复制/批量应用/撤销/重开。初次沙箱运行受 Metal 不可用限制，最终沙箱外验证通过。
- release 构建、`--verify-resources`、`codesign --verify --deep --strict` 通过。日志位于 `scratch/parameter-shortcuts-*.log`。本轮未执行实际键鼠事件验收。
