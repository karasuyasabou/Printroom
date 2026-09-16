# 0.3.34 管理缓存验收

2026-09-15。本轮在既有大量未提交修改上增量实现，保留原修改和原始资产。算法v5、schema6保持。

- 移除顶部三个点及其两项清理浮层；File增加管理缓存窗口，显示实际总量/上限，GB输入应用或Enter保存，3/7/30天/永不即时保存。本机默认8.0GB/30天。
- 系统缩略图与RAW已提交缓存统一预算、按最后使用LRU/TTL清理。RAW沿用后台合并队列与跨进程独占锁，等待读者/转换结束；启动、每小时、读写和设置变动触发。原片、设置、用户导出不进入扫描。
- `scripts/test.sh --filter 'DiskCachePolicyTests|RAWSourceServiceTests|ThumbnailMigrationTests|ImageServiceTests'`：23项XCTest零失败；Swift Testing报告13项，其中真实Adobe代理取样1项按环境开关跳过，其余通过。覆盖预算跨类型淘汰、偏好/非法值、期限/永不、符号链接与陌生文件保护，以及既有19项RAW故障/取消/锁与维护测试、缩略图迁移和像素/缓存回归。
- 增补5天/14天缓存边界并明确系统目录URL后，`scripts/test.sh --filter 'DiskCachePolicyTests|ThumbnailMigrationTests'` 再次4项XCTest与6项Swift Testing通过。
- 初次受限环境执行中编辑器AppAssets为空；在可访问本机Metal的环境重跑以上回归通过，未修改资源或放宽断言。
- `bash scripts/cache-window-qa.sh --skip-build` 真实独立窗口截图成功，人工查看中文布局、容量2.5/8.0GB、输入/应用和30天选择均完整，无截断。截图位于scratch/cache-ui-qa/cache-manager.png。未自动操作实际File菜单和下拉选项，设置/清理行为由单元及集成测试验证。
- 最终 `scripts/build-app.sh` 成功，资源、四输出ICC、Metal Apple M4、UInt16预览及严格签名验证通过。包内版本回读0.3.34/1，固定output/Printroom.app与studio.printroom.local.v3.3。`git diff --check`通过。

尚未实测跨天长时间运行、实际大卷持续读写下淘汰体验、更多macOS设备；未重跑真实RAW全尺寸导出或图像外观验收。用户界面试用待确认。清理是异步目标，活动RAW任务期间可暂时超限，应用退出期间不运行清理。


## 构建2：主页入口与说明精简（2026-09-15）

- 主页打开文件夹右侧新增硬盘图标“管理缓存”次级按钮，调用既有cache-manager窗口；移除截图所示整段缓存说明。
- `bash scripts/editor-window-qa.sh --release --skip-build --appearance`通过；检查1060×720空历史及含8条最近胶卷的布局截图，两个按钮完整显示，列表无重叠。离屏截图为非激活窗口，未用于验收激活态主按钮颜色。
- `bash scripts/cache-window-qa.sh --skip-build`成功；查看真实缓存窗口截图，说明已删除，用量、输入、应用和期限显示完整。
- `scripts/build-app.sh`首次在沙箱中编译成功、Metal验证不可用，未替换旧包；在可访问本机GPU的环境重跑成功，资源、四输出ICC、Metal Apple M4、UInt16预览和严格签名通过，交付0.3.34/2到固定路径。
- 本轮仅改界面入口和文案，未重跑缓存策略或图像算法测试；未自动点击正式主页入口，窗口路由经代码核对，用户实际交互与观感待试用。
