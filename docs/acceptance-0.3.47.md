# 0.3.47 自动裁切尺寸验收

日期：2026-09-19。范围按用户要求仅包含多候选边界和整卷尺寸识别；不改逐帧位置/角度优化、自动检查规则、内收和UI。检测版本roll-edge-v2，图像算法v6、schema7、几何版本2保持。公式与工程阈值唯一来源为pipeline.md。

## 变更

每侧保留多个边界峰，用候选外侧的片基一致性、外侧条带稳定性及持续向内密度上升降低夹具条纹权重。整卷以一帧一票的尺寸共识选择宽高，避免把不同物理边界混入中位数。第一遍只额外保留有界候选，第二遍沿用原seed与fit；无合格尺寸配对时保留旧建议回退，不视作尺寸成功。已保存项目不自动重算。

## 已执行验证

- `PRINTROOM_AUTOCROP_STUDY="$PWD/scratch/autocrop-v2" scripts/test.sh --build-system native -c release --filter AutoCropTests`：当时5项测试全部通过，包含两卷76张现有线性代理；没有重新解码用户RAW或写入项目。输入清单重新定位至当前缓存，历史实验结果保留作为参考。
- 2026-09-01-1：32/36自动通过，分流变化0；相对旧实验最大中心差0.307125分析像素、角度差0.066643°。2026-09-01-2：39/40自动通过，分流变化0；最大中心差0.777729分析像素、角度差0.099020°。原尺寸、中心、角度及分流断言未放宽；日志`scratch/autocrop-v2/tests.log`。
- `PRINTROOM_AUTOCROP_SIZE_STUDY="$PWD/scratch/autocrop-v2/may" scripts/test.sh --build-system native -c release --filter 'AutoCropTests.testFilmBaseOuterEdgeRollSize|AutoCropTests.testRollSizeRejectsStrongerFixtureStripes|AutoCropEditingTests|AutoCropProjectTests'`：3项XCTest与7项Swift Testing全部通过。包括15张问题卷的独立尺寸范围、已知675×500画幅的强夹具/弱边缘/逐帧曝光变化合成样本、两遍seed、反序尺寸一致、项目迁移及保存、整组撤销、取消/迟到结果和并发修改保护。日志`integration.log`。
- 2026-05-15实际卷：检测模板由701.5×514.885改为674.5×514.885分析像素；输入分析网格800×533，宽度有14帧贡献，和原图可见左右画面边界一致。只读复算报告`scratch/autocrop-v2/may/native-v2.json`。全部15张裁框已叠加于未调色代理检查，新旧均按每边1%内收显示；对照图`scratch/autocrop-v2/comparison.jpg`，放大图DSC04270/04276/04277。诊断负片图只用于看边界，不是Final色彩验收。
- `git diff --check`通过。本轮未写用户原片、旁存项目或原资产；所有分析/测试产物在scratch或临时目录。

## 尚未解决与边界

尺寸正确不等于逐帧中心正确。DSC04269、04276、04277、04279、04283仍被原fit目标拉向右侧外沿；本次只改尺寸，未调整其定位目标、起点或三边通过规则。这5张的偏移在新旧对照图中仍可见。不得将本次交付称作整卷裁切全部修复。真实应用手动运行与用户最终观感待验收；不自动覆盖用户已存裁剪。

未验证其他扫描布局、极窄片基、超出既定搜索带或大角度的普适识别。没有对全卷建立像素级人工真值；分流比例不是正确率。

首轮使用默认SwiftBuild时dSYM生成遇到Operation not permitted，未计为通过。其后切换已有native构建命令；受限进程状态检查曾导致等待已退出进程的锁，停止本次等待进程后在本机权限环境完成上述验证。

## 应用交付

`scripts/build-app.sh`成功，release构建、捆绑ICC/LUT与四输出profile、Apple M4 Metal渲染、16-bit预览及ad-hoc严格签名验证通过；验证成功后已覆盖固定`output/Printroom.app`，版本0.3.47、构建1，应用标识仍为`studio.printroom.local.v3.3`。日志`scratch/autocrop-v2/build-app.log`。
