# 0.3.12 最近胶卷验收

日期：2026-09-10。基于已有未提交工作区增量实现，未创建提交；保留其他修改。交付 output/Printroom.app，版本0.3.12、构建1、固定bundle identifier。算法v3/schema5不变。

## 已执行

- `scripts/test.sh --filter 'RecentRollsTests|EditingV2Tests'`：12项测试通过。覆盖最近记录持久化、20条上限、同目录去重和置顶、删除/撤销顺序、重新定位替换历史、打开指定照片及重开恢复active、删除不改项目字节/原片、失败不新增，以及既有编辑/方向/切帧/保存重开/导出快照回归。
- `bash scripts/editor-window-qa.sh --release --appearance`：1060×720真实NSHostingView生成窗口位图；使用隔离UserDefaults和虚构卷路径，不写用户历史。已检查六行列表、长中文名称和路径、不可用状态及移除后撤销提示。首轮发现裁切，缩小图形/行距后复查完整可见。截图 scratch/editor-ui-qa/13-recent-rolls.png、14-recent-removed.png。
- `scripts/build-app.sh`：release构建、四ICC/LUT资源、Apple M4 Metal冒烟和签名验证成功后替换唯一正式应用。最后布局修正后重新打包成功。
- `git diff --check` 通过。

## 执行限制与待验证

首次沙盒内测试因Metal/文件协调环境失败；经本机权限重跑上述12项全部通过。debug窗口脚本遇到现有bash空数组问题，采用已有release路径完成窗口验证。

外置盘真实拔插、重新定位系统面板的端到端键鼠操作、菜单/悬停/右键真实事件及6秒撤销到期仍未实机操作验收；窗口位图与模型测试不替代这些验证。未重跑不相关全尺寸图像算法/RAW套件。历史记录从新版成功打开开始积累，旧版未保存的历史无法回填。
