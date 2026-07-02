/**
 * Embed 数据桥接 shim（替换 `@tauri-apps/api/core`）。
 *
 * - WKWebView 场景：`window.webkit.messageHandlers.invoke` 存在时，通过
 *   WKScriptMessageHandlerWithReply 把 `{cmd, args}` 抛给原生 Swift，postMessage
 *   返回 Promise<result>（原生 replyHandler 回填 JSON）。
 * - 普通浏览器冒烟测试：回退到本地 mock 假数据，便于验证渲染。
 *
 * 只在 usage 面板需要的命令上提供 mock，其余返回空/默认。
 */

type InvokeArgs = Record<string, unknown> | undefined;

interface WebkitReplyBridge {
  postMessage(msg: unknown): Promise<unknown>;
}

function getNativeBridge(): WebkitReplyBridge | undefined {
  const w = window as unknown as {
    webkit?: { messageHandlers?: { invoke?: WebkitReplyBridge } };
  };
  return w?.webkit?.messageHandlers?.invoke;
}

export async function invoke<T = unknown>(
  cmd: string,
  args?: InvokeArgs,
): Promise<T> {
  const bridge = getNativeBridge();
  if (bridge) {
    // WKScriptMessageHandlerWithReply：postMessage 返回 Promise<result>
    const result = await bridge.postMessage({ cmd, args: args ?? {} });
    return result as T;
  }
  return mockInvoke(cmd, args) as T;
}

// api/core 的其它导出可能被间接引用，提供无害占位，避免命名导入解析失败。
export const isTauri = (): boolean => !!getNativeBridge();
export function convertFileSrc(filePath: string): string {
  return filePath;
}
export function transformCallback(): number {
  return 0;
}
export class Channel<T = unknown> {
  onmessage: ((message: T) => void) | null = null;
  id = 0;
}
export class PluginListener {
  plugin = "";
  event = "";
  channelId = 0;
  async unregister(): Promise<void> {}
}

export default { invoke, isTauri, convertFileSrc, transformCallback, Channel };

/* ────────────────────────── 浏览器 mock 数据 ────────────────────────── */

function mockInvoke(cmd: string, args?: InvokeArgs): unknown {
  switch (cmd) {
    case "get_usage_summary_by_app":
      return [{ appType: "claude", summary: mockSummary() }];
    case "get_usage_summary":
      return mockSummary();
    case "get_usage_trends":
      return mockTrends(args);
    case "get_provider_stats":
      return mockProviders();
    case "get_model_stats":
      return mockModels();
    case "get_usage_data_sources":
      return [
        {
          dataSource: "session_log",
          requestCount: 128,
          totalCostUsd: "1.234560",
        },
      ];
    case "get_request_logs":
      return { data: [], total: 0, page: 0, pageSize: 20 };
    case "get_model_pricing":
      return [];
    case "check_provider_limits":
      return {
        providerId: String((args as { providerId?: string })?.providerId ?? ""),
        dailyUsage: "0",
        dailyExceeded: false,
        monthlyUsage: "0",
        monthlyExceeded: false,
      };
    case "sync_session_usage":
      return { imported: 0, skipped: 0, filesScanned: 0, errors: [] };
    case "get_quota":
      return mockQuota();
    case "get_init_error":
      return null;
    default:
      return null;
  }
}

// 浏览器预览用的 5H / Week 假额度（WKWebView 里由原生 get_quota 覆盖）
function mockQuota() {
  const iso = (h: number) => new Date(Date.now() + h * 3600_000).toISOString();
  return [
    { name: "five_hour", utilization: 42, resetsAt: iso(2), planLabel: "max" },
    { name: "seven_day", utilization: 78, resetsAt: iso(50), planLabel: "max" },
  ];
}

function mockSummary() {
  const input = 1_234_567;
  const output = 234_567;
  const cacheCreation = 345_678;
  const cacheRead = 2_345_678;
  const cacheableInput = input + cacheCreation + cacheRead;
  return {
    totalRequests: 128,
    totalCost: "1.234560",
    totalInputTokens: input,
    totalOutputTokens: output,
    totalCacheCreationTokens: cacheCreation,
    totalCacheReadTokens: cacheRead,
    successRate: 100,
    realTotalTokens: input + output + cacheCreation + cacheRead,
    cacheHitRate: cacheRead / cacheableInput,
  };
}

function mockTrends(args?: InvokeArgs) {
  const now = Math.floor(Date.now() / 1000);
  const a = args as { startDate?: number; endDate?: number } | undefined;
  const start = Number(a?.startDate) || now - 24 * 3600;
  const end = Number(a?.endDate) || now;
  const span = Math.max(end - start, 3600);
  const hourly = span <= 24 * 3600;
  const step = hourly ? 3600 : 24 * 3600;
  const count = Math.min(Math.max(Math.ceil(span / step), 1), 200);

  const out = [];
  for (let i = 0; i < count; i++) {
    const ts = start + i * step;
    const input = Math.round(40000 + 30000 * Math.abs(Math.sin(i / 3)));
    const output = Math.round(8000 + 6000 * Math.abs(Math.cos(i / 4)));
    const cacheCreation = Math.round(12000 + 9000 * Math.abs(Math.sin(i / 5)));
    const cacheRead = Math.round(60000 + 50000 * Math.abs(Math.cos(i / 2)));
    const cost =
      (input * 3 + output * 15 + cacheCreation * 3.75 + cacheRead * 0.3) / 1e6;
    out.push({
      date: new Date(ts * 1000).toISOString(),
      requestCount: 3 + (i % 7),
      totalCost: cost.toFixed(6),
      totalTokens: input + output,
      totalInputTokens: input,
      totalOutputTokens: output,
      totalCacheCreationTokens: cacheCreation,
      totalCacheReadTokens: cacheRead,
    });
  }
  return out;
}

function mockProviders() {
  return [
    {
      providerId: "p1",
      providerName: "Claude (Session)",
      requestCount: 96,
      totalTokens: 3_200_000,
      totalCost: "0.981200",
      successRate: 100,
      avgLatencyMs: 0,
    },
    {
      providerId: "p2",
      providerName: "PackyCode",
      requestCount: 32,
      totalTokens: 960_000,
      totalCost: "0.253360",
      successRate: 98,
      avgLatencyMs: 1200,
    },
  ];
}

function mockModels() {
  return [
    {
      model: "claude-sonnet-4-5",
      requestCount: 80,
      totalTokens: 2_800_000,
      totalCost: "0.800000",
      avgCostPerRequest: "0.010000",
    },
    {
      model: "claude-opus-4-1",
      requestCount: 48,
      totalTokens: 1_360_000,
      totalCost: "0.434560",
      avgCostPerRequest: "0.009053",
    },
  ];
}
