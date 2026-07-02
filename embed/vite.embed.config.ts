import path from "node:path";
import { defineConfig, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import { viteSingleFile } from "vite-plugin-singlefile";

const r = (p: string) => path.resolve(__dirname, p);
const STUB = r("./src/embed-tauri-stub.ts");

// 产物 html 的入口名是 index-embed.html，重命名为 index.html（原生要求单文件 index.html）。
function renameEmbedHtml(): Plugin {
  return {
    name: "rename-embed-html",
    enforce: "post",
    generateBundle(_options, bundle) {
      for (const fileName of Object.keys(bundle)) {
        if (fileName.endsWith("index-embed.html")) {
          const asset = bundle[fileName];
          asset.fileName = "index.html";
          delete bundle[fileName];
          bundle["index.html"] = asset;
        }
      }
    },
  };
}

// 目标产物：原生 App 的 WKWebView 单文件面板。
// scripts/build-embed.sh 通过 CC_USAGE_WEB_PANEL_OUT 指回 cc-usage 仓库的
// Sources/App/web-panel；手动构建时缺省产出到 cc-switch 仓库根的 dist-embed/。
// Output dir for the single-file panel consumed by the native WKWebView.
// scripts/build-embed.sh sets CC_USAGE_WEB_PANEL_OUT; defaults to ./dist-embed.
const OUT_DIR = process.env.CC_USAGE_WEB_PANEL_OUT ?? r("./dist-embed");

export default defineConfig({
  // root 保持仓库根目录（默认），index-embed.html 在此处
  base: "./",
  plugins: [react(), viteSingleFile(), renameEmbedHtml()],
  resolve: {
    // 顺序敏感：更具体的 @tauri-apps/api/xxx 必须排在裸 @tauri-apps/api 之前，
    // 否则 rollup-alias 的前缀匹配会把子路径也吞进裸包别名。
    alias: [
      // 数据桥接：invoke → WKWebView / mock
      { find: "@tauri-apps/api/core", replacement: r("./src/embed-invoke-shim.ts") },
      // 其余 Tauri 原生模块 → 空实现桩
      { find: "@tauri-apps/api/event", replacement: STUB },
      { find: "@tauri-apps/api/webviewWindow", replacement: STUB },
      { find: "@tauri-apps/api/window", replacement: STUB },
      { find: "@tauri-apps/api/app", replacement: STUB },
      { find: "@tauri-apps/api/path", replacement: STUB },
      { find: "@tauri-apps/api", replacement: STUB },
      { find: "@tauri-apps/plugin-dialog", replacement: STUB },
      { find: "@tauri-apps/plugin-process", replacement: STUB },
      { find: "@tauri-apps/plugin-updater", replacement: STUB },
      { find: "@tauri-apps/plugin-store", replacement: STUB },
      // 保留 @/ 别名（放最后，避免影响上面的精确匹配）
      { find: "@", replacement: r("./src") },
    ],
  },
  build: {
    outDir: OUT_DIR,
    emptyOutDir: true,
    // 全部资源内联为 data URI，配合 singlefile 产出单个 index.html
    assetsInlineLimit: 100_000_000,
    cssCodeSplit: false,
    chunkSizeWarningLimit: 100_000,
    rollupOptions: {
      input: r("./index-embed.html"),
    },
  },
  envPrefix: ["VITE_", "TAURI_"],
});
