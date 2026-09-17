# 0.3.39 自动裁切与自由比例验收

日期：2026-09-17。当前环境 macOS27.0（26A428）、Apple Silicon、Swift6.4。最终应用固定为`output/Printroom.app`，bundle identifier保持`studio.printroom.local.v3.3`。

## 变更

原生整卷自动裁切沿用用户认可的两卷实验；不依赖片基校准，不拒绝漏光。自由比例承接实际测得宽高，并支持独立边角拖拽。增加普通保留手动裁剪/覆盖重算、进度取消、建议检查标记/筛选/确认下一张、整组撤销。schema7保存自由比例及来源/检查状态，旧项目首次覆盖自动备份。具体规则以pipeline、interaction、architecture为准。

## 已执行

- 76张已缓存线性代理只读对照（`PRINTROOM_AUTOCROP_STUDY=$PWD/scratch/autocrop-study scripts/test.sh -c release --filter AutoCropTests`包含在首轮组合命令中）：两卷分流均与实验完全一致，32/36与39/40自动通过。最大中心差0.25875分析像素（约0.52代理像素），最大角度差0.09903°；原生两遍分析实测约12.33/13.89秒，不含首次RAW解码。支持度不是正确概率，不能把分流比例当成准确率。记录`scratch/autocrop-study/native-parity.json`及`release-tests.log`。
- 旋转合成样本校正方向、无边缘建议检查、两遍复用seed结果相同通过。
- `scripts/test.sh -c release --filter 'AutoCropEditingTests|AutoCropProjectTests|CropTests|CropCanvasTests|ProjectMigrationRelocationTests|CineonLUTTests|EditorKeyboardRoutingTests'`：33项XCTest中32通过、1项可选76帧检查跳过（已在前轮执行）；Swift Testing 32项通过。涵盖7项自动裁切事务、迁移/备份、自由几何/样本/分块导出、画布与快捷键等。记录`transactions-tests.log`。
- 首轮发现两项旧断言未随已交付的色彩v6/旧单矩阵迁移更新；仅修正断言到现行契约，复跑通过，未改色彩或矩阵迁移行为。首轮沙箱下文件协调/Metal不可用的失败不计通过，后续在可用环境运行。
- `PRINTROOM_CROP_QA_SOURCE=<已校验代理路径> bash scripts/crop-window-qa.sh --release --autocrop`：临时卷含两张代理副本及一张合成低对比帧。真实1060×720 EditorView与753×462画布，验证原生自动批量、琥珀标记、仅待检查筛选、确认最后一张、自由右边拖动保持高度、整组撤销/重做、JSON重开。只截测试窗口，照片不上传。截图`scratch/crop-qa/auto-01-before.png`至`auto-06-reviewed.png`；日志`window-qa.log`含PASS。
- 查看完成、检查模式及自由拖拽截图；修正最小窗口裁剪文字压缩后重新截图，按钮文字完整且检查控件未挤占顶部裁剪栏。状态/筛选控件位于Filmstrip既有标题行。
- 新Xcode默认SwiftBuild目录与既有打包/窗口脚本预期不同，因此这两个脚本显式使用`--build-system native`，维持现有资源与独立窗口链接布局；不新增运行时依赖。

## 最终检查

异步进度回调捕获修正后，`scripts/test.sh --build-system native -c release --filter AutoCropEditingTests`的7项模型测试全部通过，见`final-model-tests.log`。`scripts/build-app.sh`成功：release编译、四输出ICC与两份LUT资源校验、Apple M4 Metal渲染与16-bit预览校验、ad-hoc签名严格验证通过；验证后已覆盖`output/Printroom.app`，版本0.3.39、构建1。日志`build-app.log`。`git diff --check`通过。

## 验证边界

未在真实用户胶卷项目中应用或覆盖裁剪；真实照片验证读取已缓存代理，人工可在正式包中自行运行。没有新增严格漏光检测，片头及片尾即使自动通过仍可人工浏览。独立实验的6px内收对照不作为默认自动裁剪。旧TEST目录已不在工作区，本轮没有重跑依赖该目录的全尺寸原始TIFF资产全套验收；自由裁剪的解析/合成分块输出与D4/预览数值契约已执行，不宣称跨机型和未运行的色彩外观验收。其他任务已有修改和删除保持。
