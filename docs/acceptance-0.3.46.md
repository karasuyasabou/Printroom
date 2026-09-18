# 0.3.46 验收记录

日期：2026-09-19。本地 Apple M4；工作区已有未提交修改均保留，无推送或发布。交付 output/Printroom.app，版本0.3.46、构建1，固定应用标识不变。

## 变更

- 新卷双矩阵初值及已有项目保持规则见 interaction.md、architecture.md；系数和像素公式不改，算法v6、schema7保持。
- 主窗口关闭转正常退出，沿用导出和保存失败阻止退出；辅助窗口保持独立关闭。
- 自动裁切设置初始不勾选保留、每边内收1%，仅启动分析后才应用；检测算法不变。

## 验证

`scripts/test.sh --filter 'RollProjectTests|MatrixTests|MatrixEditingTests|AutoCropEditingTests|EditorWindowCloseTests'`：XCTest 38项，37通过、1项真实RAW校准按环境开关跳过；Swift Testing 13项通过。新卷保存重开采用两预设，显式Identity重开保持；矩阵事务/失败/撤销、自动裁切事务、窗口performClose发起退出及取消时拒绝关闭、主窗口独立安装均通过。

矩阵切换测试显式创建Identity起点；历史schema3测试显式构造旧初值，缺单侧矩阵断言按已有兼容规则核对保留另一侧值。

首轮受沙盒Metal/文件协调限制失败；后续沙盒外复验通过。测试日志：/tmp/printroom-046-tests.log。

`scripts/build-app.sh`成功，正式包ICC/LUT及四输出profile、Metal Apple M4、SDR预览资源验证通过，codesign严格验证通过后覆盖固定交付路径。日志：/tmp/printroom-046-build.log。

## 未执行

实际SwiftUI窗口点击关闭后的进程退出、导出阻止和保存失败提示尚未人工端到端验收；本轮自动测试验证关闭路由，沿用既有AppDelegate退出检查。自动裁切设置视觉和新卷默认图像观感待用户验收。不把上述工程测试视为色彩外观确认。未追加历史全量真实RAW或TIFF导出验收。
