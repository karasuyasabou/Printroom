# 0.3.4 统一同步验收

日期：2026-09-09；本地 Apple M4。交付 `output/Printroom.app`，包内版本 0.3.4 / 1，固定标识 `studio.printroom.local.v3.3`。工作区未提交，保留既有修改及同期面板顺序调整；无推送或发布。算法 density-v2、schema 3、几何版本 2 保持。

## 变更

统一 Filmstrip 同步入口；每次浮层默认不勾选，来源为当前已提交设置，目标排除来源，可选调色、裁剪或两者。单事务覆盖与撤销，裁剪保留目标方向；裁剪栏只提交当前帧。复制/粘贴调色保留 ⌘C/⌘V 与快照，移入编辑/右键菜单。规范见 interaction.md，事务见 architecture.md。

## 已执行

- `scripts/test.sh --filter PrintroomAppTests`：最终运行通过，报告 80 tests / 13 suites；4 项条件跳过（3 项性能量测及 full 开关限定的实际全尺寸导出）。日志 `/tmp/printroom-sync-verified.log`。
- 新增集成案例覆盖每次打开不勾选、空选不提交、使用当前调色而非旧复制快照、排除来源、两项一次撤销/重做、方向与校准保留、相同结果无额外撤销、最后一个目标 TIFF 损坏时整组不改、调色单独应用、全图清除目标裁剪及保存重开。
- 自有 EditorWindowQA：1060×720 窗口，截图检查默认同步浮层、底部入口、目标数、禁用应用按钮，以及裁剪栏移除旧同步后布局。截图位于 `scratch/editor-ui-qa/01-final-minimum-window.png`、`07-sync-popover-21366.png`、`08-crop-without-sync.png`；同时捕获直方图及导出/保存失败临时状态。
- 窗口程序通过 `bash scripts/editor-window-qa.sh --release --skip-build` 编译；发现原脚本在 Bash 空数组下退出，已修复分支。已编译程序直接执行 `scratch/editor-ui-qa/window-qa` 成功，日志 `/tmp/printroom-sync-ui.log`。
- `scripts/build-app.sh`：release 编译、包内 ICC/LUT/四输出 profile、Metal Apple M4 和 UInt16 预览验证、ad-hoc 严格签名验证通过后替换应用；日志 `/tmp/printroom-sync-build-final.log`。Info.plist 回读版本 0.3.4。
- `shasum -a 256 -c assets/SHA256SUMS`：12/12 通过。`git diff --check` 通过。

## 失败与修正

初次沙箱执行无法创建 Metal 上下文，改为允许本机图形资源访问后运行通过。新增测试的临时损坏 TIFF 恢复触发现有禁止覆盖保护，改为删除该临时测试文件后重写；重开后文件指纹合理变化，因此持久化断言按稳定 ID、调色、裁剪、方向逐项检查。窗口测试改用公开裁剪命令，并修复上述 shell 空数组兼容问题。

## 未执行范围

未进行用户真实照片上的人工操作手感验收；本轮未执行真实键鼠事件脚本、十张原片全尺寸输出、性能量测或跨设备显示检查。截图证明布局与默认状态，模型测试证明事务行为；不把二者视为完整人工使用验收。历史待验证范围不自动补做。
