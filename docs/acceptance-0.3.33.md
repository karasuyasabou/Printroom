# 0.3.33 移除相纸 LUT 验收

2026-09-14，用户明确不需要五个相纸LUT，要求删除。

- 已移除五个枚举选项及运行加载/导出资源，删除三个历史生成版本共15份派生cube。仅保留原始Kodak2383/Fujifilm3513DI；桌面DiVERE与Printroom原始TEST/ICC/LUT保持。
- 可复用转换脚本、源数据和历史SHA/数值结论保留，不随包提供；曲线绘图工具移除固定七表数量假设。
- 已知五个旧选择解码为Kodak2383，首次保存前原字节备份到.printroom-retired-paper-luts-UUID.json，其他调色保持。未知LUT仍拒绝解码，避免吞掉损坏数据。
- scripts/test.sh --filter 'RetiredPaperLUTTests|CineonLUTTests|DirectLUTTests'：3项XCTest、3项Swift Testing通过；覆盖全部旧标识回退、精确备份且仅一次、重开、两LUT直接CPU/Metal、同步/复制/撤销、保存和混合16位TIFF导出回读。
- scripts/build-app.sh成功：资源、四输出ICC、Metal Apple M4、UInt16预览和严格签名通过。最终包复核仅两份原始cube，无DiVERE源数据。

交付output/Printroom.app，版本0.3.33/1，固定名称/标识。schema6、密度v5保持。未重新做全尺寸实图导出或窗口视觉验收，本轮没有新增布局。
