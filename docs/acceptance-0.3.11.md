# 0.3.11 直方图折叠验收

日期：2026-09-09。交付：output/Printroom.app，版本 0.3.11 / 构建 1，固定应用标识。工作区包含此前未提交修改，本轮保留它们，仅追加直方图展示交互与对应文档、验证脚本。

- 直方图箭头收起，紧凑“直方图”入口展开；默认展开，AppStorage 保存本机状态。收起同时关闭详情浮层。宽度由浮层自身管理，收起不再保留 248 点面板。
- `scripts/build-app.sh`：release 构建成功，ICC/LUT、四输出 profile、Apple M4 Metal 渲染、UInt16 展示格式和 ad-hoc 签名验证通过，成功替换应用。首次沙盒内无法创建 Metal 上下文，保留旧包；沙盒外重跑成功。
- `bash scripts/editor-window-qa.sh --release --skip-build --appearance`：通过。1060×720 合成预览，隔离 UserDefaults 驱动展开→收起→展开，离屏渲染截图已目视检查：收起仅余右上角小按钮，展开通道、图表、坐标轴完整，照片布局保持。截图位于 scratch/editor-ui-qa/11-histogram-collapsed.png 与 12-histogram-expanded.png。
- `git diff --check`：通过。

本轮未执行真实鼠标点击、跨进程重启偏好恢复或全套图像数值回归；不将离屏布局检查当作这些验证。图像处理和统计代码未改动。用户实机试用待确认。
