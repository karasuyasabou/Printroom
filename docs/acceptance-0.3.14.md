# 0.3.14 预览工具栏验收

日期：2026-09-10。已有未提交工作区增量修改，保留并包含0.3.13 RAW代理工作；无提交、远端或发布。交付固定 output/Printroom.app，0.3.14 / 1，bundle identifier不变。

## 变更

方向/管线预览共用原生Menu及外观组件，裁剪与缩放统一尺寸，三组淡分隔、灰色默认状态、选中金色。管线预览仅线性（L2）、密度（D3）、输出（Final）；实际视口回报缩放选中状态。交互唯一规范见interaction.md；图像算法和项目结构保持。

## 已执行

- `scripts/test.sh --filter 'PreviewCanvasTests|EditingV2Tests'`：16项通过。包含新增实际视口回报测试（适应、1:1、1:1平移、自定义缩放、双击恢复、适应比例但偏移），以及原有布局裁切、阶段切换/过期直方图、方向/撤销/保存、导出快照等回归。测试经本机权限运行。
- `bash scripts/editor-window-qa.sh --release --appearance`：1060×720真实NSHostingView位图检查，线性、密度、输出三种标签完整显示，工具栏未溢出。首轮borderless菜单吞掉当前选项且将箭头放到左边，改用button菜单样式及plain按钮后复查正常。截图位于scratch/editor-ui-qa/15-toolbar-linear.png、16-toolbar-density.png、17-toolbar-output.png。使用内存合成渐变，仅用于布局，不证明三阶段图像数值或真实照片外观。
- `scripts/build-app.sh`：release构建、包内ICC/LUT及四输出profile、Apple M4 Metal冒烟、UInt16展示格式与签名验证通过，成功后覆盖唯一正式应用。
- `git diff --check`通过。

## 边界

最初直接swift build缺少脚本的缓存环境，因沙盒缓存路径不可写失败；采用工程脚本后编译通过。位图流程有系统服务警告但成功产出全部图像。未执行真实菜单展开/点击/悬停的端到端事件验收，实际手感及用户视觉接受待试用；未重复与此次UI无关的全尺寸图像算法/RAW回归。
