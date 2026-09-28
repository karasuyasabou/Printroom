# 0.3.52 入口整理与JPG导出验收

日期：2026-09-19。交付：output/Printroom.app，0.3.52（构建1），固定应用标识与名称保持。

## 变更

- 打开文件夹仅在主页提供，移除顶部打开胶卷及File通用打开/⌘O；主页选择器只允许目录。最近胶卷恢复保留。
- 顶部重置调色左侧依次加入自动裁切、色罩分析，移除旧入口；沿用既有资格检查、设置、确认、分析和应用流程。
- 顶部导出改名，删除编号说明行；新增真正的8-bit JPG，保留16-bit TIFF及现有编号行为。
- 数值、交互、持久化兼容与内存边界分别以pipeline.md、interaction.md、architecture.md为准。

## 已执行

- `scripts/test.sh --filter 'ExportColorTests|ExportProfileOptionsTests|CineonLUTTests'`：20项XCTest及5项Swift Testing通过；包含五ICC的JPG格式/8-bit/尺寸回读、ICC完整数据匹配、解析转换样本的有损容差、重复导出无覆盖、源文件字节保持、取消临时清理，以及原TIFF并发、命名、取消和LUT回归。日志：`/tmp/printroom-0352-tests-unsandboxed.log`。
- 增加项目保存重开断言后，单独复验`ExportColorTests.testJPEGExportProfilesNumberingAndNoOverwrite`通过。日志：`/tmp/printroom-0352-persistence.log`。
- `bash scripts/editor-window-qa.sh --release --skip-build --export-layout --appearance`：1060×720编辑器与主页，以及TIFF/JPG导出选项离屏渲染成功。查看工具栏与两个格式截图，按钮和字段完整、编号行消失、JPG下压缩禁用。截图：`scratch/editor-ui-qa/0352-*.png`；日志：`/tmp/printroom-0352-window.log`。
- `scripts/build-app.sh`：release构建、ICC/LUT及五输出profile、Metal Apple M4、16-bit预览资源检查、ad-hoc签名与验证通过后替换固定应用。日志：`/tmp/printroom-0352-package.log`。
- `git diff --check`通过；源检索确认openPanel只由主页按钮调用。

初次沙盒内回归因macOS目录协调及Metal资源上下文受限失败；在批准的沙盒外复验通过。未改写TEST/ICC/LUT原始资产或用户胶卷。

## 尚未执行

- 真实胶卷全尺寸JPG的性能、峰值内存及主观外观验收。
- 系统目录选择器的人工点击验收；目录限定已由源码检查确认，未将离屏渲染视作真实点击结果。
- 旧系统及其他显示器验收。JPG有损编码不承诺与TIFF逐像素一致。
