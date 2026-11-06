# 离屏渲染对拍

设置面板和菜单栏合成图是 App 层唯一没有单测的 UI。改它们之前留一份输出，改完逐字节比：

```bash
bash Tools/render/render.sh . /tmp/ccusage/render-base     # 改之前
bash Tools/render/render.sh . /tmp/ccusage/render-new      # 改之后
diff -r -x build /tmp/ccusage/render-base /tmp/ccusage/render-new
```

- `settings-*.png`：MenuBarSettingsView，默认、全展开（有无额度数据）、部分展开四种状态。
- `labels.txt`：MenuBarLabel 的合成图（尺寸、自然宽度、字节哈希、VoiceOver 文案），覆盖占位、额度条 / 数字、告警、截断。

不起 App，窗口不上屏；额度开关只从 UserDefaults 设，不走 didSet（那会去拉官方额度）。同一份代码跑两遍结果逐字节相同。
`compat.swift` 随 PanelModel 的 API 走，换 API 时跟着改；比旧版本时用那个版本自己的 `Tools/render`。
