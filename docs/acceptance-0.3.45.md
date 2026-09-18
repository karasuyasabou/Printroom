# 0.3.45 画布箭头与直方图悬停

2026-09-18，本机Apple M4。用户确认后实现：普通画布箭头，实际拖动时闭合抓手；悬停照片在直方图上用RGB细线及底部三角标出邻域中位数。范围、阶段与剪切规则见pipeline.md，交互见interaction.md。算法v6、schema7保持，不改照片或导出参数。

## 验证

- `scripts/test.sh --filter 'PreviewCanvasTests|EditorRefinementTests|ImageServiceTests'`：30项Swift Testing测试、4个suite全部通过。新增剪切点/偶数中位数、已显示参数快照/阶段切换/裁剪拒绝、默认箭头/按下不变/实际拖动抓手/松开恢复；回归邻域边缘、预览与原片比例、画布、吸管和异步取消。既有布局测试154点固定断言不适用于此前Filmstrip高度调整，改为140–165点的布局空间约束，三种窗口尺寸通过。
- `bash scripts/editor-window-qa.sh --release --skip-build --histogram`：正式release代码和隔离合成TIFF窗口通过。Final/Density悬停标记、面板排除、拖动隐藏/抓手与松开恢复、折叠/展开均通过；检查了1060×720窗口的27-histogram-hover-final.png和28-histogram-hover-density.png，三色细线/三角无布局遮挡。
- `scripts/build-app.sh`：release、ICC/LUT/四输出profile、Metal渲染、SDR预览、严格签名通过后替换`output/Printroom.app`。包内版本0.3.45 / 1，应用标识保持。
- `git diff --check`通过。已有工作区修改保留；未修改原始TIFF/ICC/LUT。

首次沙箱测试无Metal上下文，改为本机会话后通过。窗口脚本首次与测试并发运行触发SwiftPM模块缓存冲突，停止并发后恢复；生成合成TIFF的嵌套flatMap引起编译器类型推断超时，改为显式循环后窗口验证通过。日志位于/tmp/printroom-hover-{tests-final,ui,build}.log，截图与合成卷位于scratch/editor-ui-qa，仅为可清理测试产物。

未执行：真实RAW/照片的悬停手感验收、跨设备测试、全尺寸导出回归；本次未改动图像及导出算法，不把合成窗口验证视为用户照片观感验收。

## 构建2：减弱标记线

按用户反馈改为45%不透明度，移除黑色描边和底部三角；顶部按各通道已绘制直方图相邻点高度插值，截止于曲线。仅展示变更，取样不变。

`bash scripts/editor-window-qa.sh --release --histogram`完成release编译；首次窗口运行因上次合成TIFF同名而停止，测试脚本改用UUID隔离目录后，`bash scripts/editor-window-qa.sh --release --skip-build --histogram`全部通过。检查Final/Density两张截图，半透明线无三角、未贯穿图表，拖动和面板排除回归通过。本轮未新增或重跑数值测试。

`scripts/build-app.sh`的资源、Metal/SDR及严格签名验证通过，固定应用已替换为0.3.45 / 2，`git diff --check`通过。日志为/tmp/printroom-hover-subtle-ui.log、/tmp/printroom-hover-subtle-build.log。真实照片上的样式观感待用户确认。

## 构建3：曲线交点圆点（2026-09-19）

按用户反馈在三条短线顶端增加对应RGB颜色圆点，带细浅色描边；位置与高度沿用现有中位数和曲线插值。保留半透明短线。仅展示变更，未改取样或图像算法。

`bash scripts/editor-window-qa.sh --release --histogram`通过；查看Final/Density两张截图，三色圆点清晰位于各自曲线上，面板排除、拖动隐藏/松开恢复与折叠/展开回归通过。`scripts/build-app.sh`资源、Metal/SDR和严格签名验证通过后更新固定应用，包内0.3.45 / 3。`git diff --check`通过。本轮未重跑数值测试；真实照片观感待用户确认。

日志：/tmp/printroom-hover-dots-ui.log、/tmp/printroom-hover-dots-build.log；截图沿用scratch/editor-ui-qa/27-histogram-hover-final.png与28-histogram-hover-density.png。
