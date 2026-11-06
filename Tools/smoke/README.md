# 无头 Chrome 冒烟

真前端（`Sources/App/web-panel/index.html`）+ 真桥接（`PanelWebView.handle` + `BridgePayload`）+ 冻结库，逐个页签点开、
打开请求详情。缺字段时前端在渲染时才炸，单测看不到页面，所以改桥接后跑一遍。

```bash
python3 Tools/dump/freeze.py /tmp/ccusage/frozen     # 冻结数据，见 Tools/dump/README.md
bash Tools/smoke/smoke.sh /tmp/ccusage/frozen /tmp/ccusage/smoke
```

输出目录里有每个页签的截图和 `report.json`（调过哪些命令、失败项）；有页面异常、`console.error`、桥接错误或白屏时退出码非 0。

- `extract_handle.py` 把 `handle` 那段 switch 原样抠出来，包成不依赖 WebKit 的类，走的是发版的代码。
- 额度给假数据，不读钥匙串、不联网；设置类命令存在脚本内存里，不写 UserDefaults；Chrome 用临时配置目录。
