# 0.3.64 胶卷命名与独立导出设置验收

日期：2026-09-28。胶卷项目增加可选名称，编辑页铅笔和主页最近胶卷右键可修改；空名称回退文件夹名。导出设置移至独立对话框，目的地在对话框内选择，点击“导出”直接启动。前缀默认随卷名；手动前缀、目的地、格式、色彩空间和 TIFF 压缩按卷保存。范围由入口决定，不在对话框重复显示。项目 schema 升至 8，图像算法维持 v6。

验证：`scripts/test.sh --build-system native --filter 'RollProjectTests|ExportProfileOptionsTests|RecentRollsTests|AutoCropProjectTests'` 共 38 项通过，覆盖 schema7 原字节备份、旧最近卷记录和前缀跟随／自定义规则。首次在沙盒内运行文件协调测试受系统权限限制；在本机图形环境重跑通过。`bash scripts/editor-window-qa.sh --export-layout` 生成并目视检查 TIFF/JPG 设置视图；JPG 隐藏 TIFF 压缩。`scripts/build-app.sh` 在本机图形环境完成 release 打包、ICC/LUT 与五种 profile 校验、Apple M4 Metal 预览校验和签名验证，覆盖 `output/Printroom.app`，包内版本 0.3.64。沙盒内打包自检无法创建 Metal 上下文，未替换旧包；后续本机重跑成功。

待人工验收：实际点击命名、选择目的地、取消与再次打开设置、导出少量照片并检查名称；这些窗口交互没有通过自动脚本逐项点击。旧系统和 Intel 机器未实机验证。
