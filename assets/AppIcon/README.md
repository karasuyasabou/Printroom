# Printroom 应用图标

深灰圆角底、香槟金叠放相纸；由 AppKit 矢量路径绘制，未使用外部图片。
`Printroom.png` 为 1024 px 预览，`Printroom.icns` 为随包交付资源，iconset 包含标准 16–1024 px 表示。

重建：

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" swift scripts/generate-app-icon.swift
iconutil -c icns assets/AppIcon/Printroom.iconset -o assets/AppIcon/Printroom.icns
scripts/build-app.sh
```
