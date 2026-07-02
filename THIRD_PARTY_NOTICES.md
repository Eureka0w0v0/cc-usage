# Third-Party Notices / 第三方声明

CC Usage 是 [cc-switch](https://github.com/farion1231/cc-switch) 的二次开发项目。本文件列出随本仓库分发的第三方代码及其许可证。
CC Usage is a derivative work of [cc-switch](https://github.com/farion1231/cc-switch). This file lists third-party code redistributed with this repository and their licenses.

---

## cc-switch

- Source: <https://github.com/farion1231/cc-switch>
- Usage in this project / 在本项目中的使用:
  - `Sources/App/web-panel/index.html` is a compiled single-file bundle of cc-switch's real frontend (its Usage dashboard React components, styles and i18n), built together with the bridge entry files in `embed/`.
    `Sources/App/web-panel/index.html` 是由 cc-switch 真实前端(Usage 面板 React 组件、样式与 i18n)与 `embed/` 桥接入口共同编译出的单文件产物。
  - The Swift data layer (`Sources/Shared/UsageStore.swift`) reimplements the aggregation semantics of cc-switch's `usage_stats.rs` to keep numbers identical.
    Swift 数据层逐条复刻了 cc-switch `usage_stats.rs` 的统计口径。

```
MIT License

Copyright (c) 2025 Jason Young

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

The compiled `web-panel` bundle additionally embeds cc-switch's frontend dependencies (React, Recharts, TanStack Query, i18next, Tailwind CSS, framer-motion, lucide-react, etc.), each under their respective MIT/ISC licenses; see cc-switch's `package.json` for the full dependency list.
编译产物 `web-panel` 同时内嵌了 cc-switch 的前端依赖(React、Recharts、TanStack Query、i18next、Tailwind CSS、framer-motion、lucide-react 等),均为 MIT/ISC 许可,完整清单见 cc-switch 的 `package.json`。
