# 0.3.62 色罩分析统一首张LUT

混合LUT的胶卷统一以分析快照中第一张照片的LUT分析，应用目标同时覆盖LUT；勾选保留已调色时，保护照片的完整设置。具体契约见pipeline.md、interaction.md，分析版本roll-timing-v2，项目与渲染算法版本保持。

## 验证

- `scripts/test.sh --filter 'RollTiming|CineonLUTTests'`：本机环境5项XCTest、10项Swift Testing全部通过。日志`/tmp/printroom-roll-lut-tests.log`。
- 新增多亮度合成TIFF验证：混合LUT与全部使用首张LUT的Timing一致；首张改用另一LUT，结果确实不同；首张缺失时仍使用该帧保存的LUT，缺失帧不参与样本。
- 整卷覆盖与保存重开、一次撤销/重做包含LUT；保留已调色语义、取消、过期结果及源文件变化保护通过；既有LUT的Metal预览、混合导出回读及迁移回归通过。
- 首轮沙箱内Metal不可用；本机环境重跑。新增测试修正临时TIFF已存在问题，并将单色白点样本换成多亮度样本，以区分已做相同白点对齐的两份LUT。最终全部通过。
- `git diff --check`通过。
- `scripts/build-app.sh`：release构建、ICC/LUT与输出profile验证、Metal渲染及签名检查通过，已替换`output/Printroom.app`（0.3.62/1），应用标识保持。日志`/tmp/printroom-0.3.62-build.log`。

## 待验收

真实混合LUT胶卷的主观观感待用户验收；本轮没有修改原始资产或用户胶卷。
