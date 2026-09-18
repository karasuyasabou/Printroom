# 0.3.43 相对尺寸中性点吸管

用户确认方形边长为未裁原片长边0.8%。算法与取整唯一规范见pipeline.md §15；TIFF与RAW统一使用未调色预览网格，新采样版本neutral-relative-008-v1。既有Timing不重算，schema和密度算法保持。

## 验证

- `scripts/test.sh --filter 'ImageServiceTests|EditorRefinementTests|NeutralTimingTests|RAWGeometryTests'`：本机权限环境通过，16项XCTest中1项缺失参考TIFF而跳过、其余通过；Swift Testing报告23项，其中真实Adobe用例按默认开关跳过，其余通过。日志：`scratch/neutral-008-tests-host.log`。
- 新增分辨率不变性、横竖图边缘截短、3200像素TIFF读取实际1600预览样本、169点求解及170点拒绝；更新裁剪旋转坐标预期。既有中性容差、亮度、Metal/四输出profile、撤销保存、取消、源变更及过期保护通过。
- 首次沙盒运行无法创建Metal上下文，导致依赖预览的测试失败；本机环境复跑通过，未修改测试容差或跳过失败断言。
- 应用构建验证状态见下方交付记录。

## 边界

本轮未重新执行真实Adobe转换或原始参考TIFF全图导出；本地TEST目录缺失，相关真实TIFF用例保持跳过。实际照片选点观感待用户试用。范围为0.8%在采样网格上的整数近似，1600长边时12.8取为13，边缘截短；不是全部原始像素密集统计。

## 交付

`scripts/build-app.sh` 成功；包内ICC/LUT、四输出profile、Apple M4 Metal、UInt16预览与ad-hoc签名验证通过后替换固定`output/Printroom.app`。版本0.3.43、构建1，应用标识保持。日志：`scratch/neutral-008-build.log`。`git diff --check`通过。
