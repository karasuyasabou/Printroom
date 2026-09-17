# 0.3.40 自动裁切设置与检查流程验收

日期：2026-09-17。当前环境 Apple M4、macOS 26.6.2 / SDK macOS 27.0、Swift 6.4。最终应用固定为 `output/Printroom.app`，bundle identifier 继续使用 `studio.printroom.local.v3.3`。

## 变更

自动裁切从“裁剪”下拉菜单移到其左侧独立按钮。设置对话框默认勾选“保留已裁切”，保护旧版、手动、手动全图及上次自动生成的裁切；取消勾选后重算整卷。每边内收下拉框提供0%、1%、2%、3%、4%、5%六档，检测框宽高分别乘以 `1-2p/100`，不改变中心、角度、比例或检查判定。分析期间对话框保留并显示进度，可取消，整批结果仍一次提交和撤销。

完成后如有待检查照片，自动进入第一张并默认仅看待检查。待检查数量、筛选和确认按钮全部位于裁切栏；待检查为零时隐藏。Filmstrip 不显示人工检查状态或操作。卷内第一张和最后一张非缺失照片必须四边均超过原支持度阈值才自动通过，其他照片仍允许三边通过；严格规则只改变检查分流，不改变检测框。

## 已执行

- `scripts/test.sh --filter AutoCropTests`：4项中3项通过，76帧可选对照因未设置 `PRINTROOM_AUTOCROP_STUDY` 跳过。新增合成样本确认同一三边检测框作为中间帧可自动通过，作为首尾帧进入检查，裁切几何完全相同。
- 本机权限环境运行 `scripts/test.sh --no-parallel --filter AutoCropEditingTests`：7项全部通过。覆盖每边2.5%内收、全部已有裁切来源的保留、取消保留后覆盖、整组撤销、检查队列、取消和迟到结果、并发冲突及不完整结果拒绝。
- 本机权限环境运行 `scripts/test.sh --no-parallel --filter 'AutoCropTests|AutoCropProjectTests|CropTests|CropCanvasTests'`：25项 XCTest 中24项通过、1项可选76帧对照跳过；15项 Swift Testing 全部通过。覆盖schema迁移、自由比例、D4、预览/导出采样、边角拖动和最小窗口裁切栏。
- 真实 `output/Printroom.app` 打开 scratch 三帧测试卷：确认“自动裁切”位于“裁剪”左侧；设置 sheet 显示默认勾选、0.0%–5.0%滑杆和开始/取消；取消保留后运行完成自动进入低置信度帧，仅看待检查默认勾选，待检查数量及确认按钮位于裁切栏，Filmstrip 标题行无检查控件。测试卷位于被忽略的 `scratch/`。
- 最终 `scripts/build-app.sh` 在本机权限环境成功。四份输出 ICC、两份 LUT、Apple M4 Metal 渲染、16-bit `sdr-uint16-v1` 预览和 ad-hoc 签名通过；验证后原子覆盖 `output/Printroom.app`。版本 0.3.40，构建号 1。
- `git diff --check` 通过。

## 环境说明

首次在受限沙箱运行打包和应用模型测试时 Metal 上下文不可用，打包脚本按约定保留旧应用。随后以本机权限运行同一命令，模型测试和最终打包全部通过。未重跑需要显式 `PRINTROOM_AUTOCROP_STUDY` 的两卷76帧代理对照；检测位置算法未改，新增首尾判定已有独立合成数值测试。未在用户真实胶卷项目中执行自动裁切或覆盖操作。

## 构建2：精简内收选项

按用户反馈将内收滑杆改为六档下拉框（0%至5%），默认0%；删除待裁切数量和整卷重算说明小字，并收窄对话框。保留运行进度。此次未使用 computer use 验收。`scripts/build-app.sh`编译、ICC/LUT资源、Apple M4 Metal与16-bit预览自检、签名验证通过，已覆盖固定应用，版本0.3.40、构建2；`git diff --check`通过。此前窗口检查仅对应构建1，本次界面视觉效果待用户试用。
