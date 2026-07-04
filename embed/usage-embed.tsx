/**
 * Embed 入口：把 cc-switch 真实的 Usage 面板（精简版）跑在 WKWebView 里。
 *
 * 只渲染：顶部工具栏（app 图标筛选 + 来源/模型/刷新下拉 + 日期选择器）
 * + <UsageHero> + <UsageTrendChart>。跳过下方 Tabs 与 Pricing。
 *
 * 工具栏 JSX / state 照抄自 src/components/usage/UsageDashboard.tsx。
 */

import "./index.css";

import React, { useEffect, useMemo, useState } from "react";
import ReactDOM from "react-dom/client";
import { invoke } from "@tauri-apps/api/core";
import { useTranslation } from "react-i18next";
import { motion } from "framer-motion";
import {
  RefreshCw,
  LayoutGrid,
  ListFilter,
  Activity,
  BarChart3,
  Clock,
} from "lucide-react";
import {
  QueryClientProvider,
  useQueryClient,
} from "@tanstack/react-query";

import i18n from "@/i18n";
import { queryClient } from "@/lib/query/queryClient";
import { UsageHero } from "@/components/usage/UsageHero";
import { UsageTrendChart } from "@/components/usage/UsageTrendChart";
import { UsageDateRangePicker } from "@/components/usage/UsageDateRangePicker";
import { RequestLogTable } from "@/components/usage/RequestLogTable";
import { ProviderStatsTable } from "@/components/usage/ProviderStatsTable";
import { ModelStatsTable } from "@/components/usage/ModelStatsTable";
import { ProviderIcon } from "@/components/ProviderIcon";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { usageKeys, useModelStats, useProviderStats } from "@/lib/query/usage";
import { useUsageEventBridge } from "@/hooks/useUsageEventBridge";
import { cn } from "@/lib/utils";
import { getUsageRangePresetLabel, resolveUsageRange } from "@/lib/usageRange";
import { getLocaleFromLanguage } from "@/components/usage/format";
import {
  KNOWN_APP_TYPES,
  type AppType,
  type AppTypeFilter,
  type UsageRangeSelection,
} from "@/types/usage";

const APP_FILTER_OPTIONS: AppTypeFilter[] = ["all", ...KNOWN_APP_TYPES];

// 0 表示关闭自动刷新（refetchInterval=false）
const REFRESH_INTERVAL_OPTIONS_MS = [0, 5000, 10000, 30000, 60000] as const;

// 刷新间隔持久化：默认 5s（与菜单栏一致）。选择结果写 localStorage（快路径，
// 首帧免闪）+ 原生 UserDefaults（权威，WKWebView 的 file:// localStorage 偶发
// 不跨启动持久），并经 set_setting 把菜单栏的原生刷新节奏同步成同一个值。
const REFRESH_INTERVAL_STORAGE_KEY = "embed.refreshIntervalMs";
const DEFAULT_REFRESH_INTERVAL_MS = 5000;

function isRefreshOption(
  v: number,
): v is (typeof REFRESH_INTERVAL_OPTIONS_MS)[number] {
  return (REFRESH_INTERVAL_OPTIONS_MS as readonly number[]).includes(v);
}

function loadStoredRefreshIntervalMs(): number {
  try {
    const raw = window.localStorage.getItem(REFRESH_INTERVAL_STORAGE_KEY);
    if (raw != null) {
      const v = Number(raw);
      if (Number.isFinite(v) && isRefreshOption(v)) return v;
    }
  } catch {
    /* localStorage 不可用时用默认值 */
  }
  return DEFAULT_REFRESH_INTERVAL_MS;
}

// 与 AppSwitcher 的 appIconName 保持一致（codex 复用 openai 图标）
const APP_FILTER_ICON: Record<AppType, string> = {
  claude: "claude",
  codex: "openai",
  gemini: "gemini",
  opencode: "opencode",
};

const DYNAMIC_OPTION_PREFIX = "v:";
const encodeOptionValue = (name: string) => `${DYNAMIC_OPTION_PREFIX}${name}`;
const decodeOptionValue = (value: string) =>
  value === "all" ? undefined : value.slice(DYNAMIC_OPTION_PREFIX.length);

/* ───────── 5H / Week 官方额度徽标（渲染进面板工具栏，数据来自原生 get_quota） ───────── */

type QuotaTierData = {
  name: string;
  utilization: number; // 0–100
  resetsAt?: string | null;
  planLabel?: string | null;
};

// 连续渐变配色：用量 0→100% 时色相从 140°(绿) 平滑过渡到 0°(红)，
// 途中经过黄绿/黄/橙 → 5% 与 68% 一眼可辨（比 cc-switch 的三段粗档更直观）。
function quotaColor(util: number): string {
  const t = Math.min(1, Math.max(0, util / 100));
  const hue = Math.round(140 * (1 - t)); // 140°绿 → 0°红
  return `hsl(${hue}, 72%, 48%)`;
}

// 重置倒计时（用于 tooltip）：3d12h / 2h30m / 45m；已重置/无数据返回 null
function quotaCountdown(resetsAt?: string | null): string | null {
  if (!resetsAt) return null;
  const ms = new Date(resetsAt).getTime() - Date.now();
  if (!Number.isFinite(ms) || ms <= 0) return null;
  const totalMin = Math.floor(ms / 60000);
  const h = Math.floor(totalMin / 60);
  const m = totalMin % 60;
  if (h > 24) return `${Math.floor(h / 24)}d${h % 24}h`;
  if (h > 0) return `${h}h${m}m`;
  return `${m}m`;
}

// 轮询原生 get_quota 刷新徽标。稳态轮询跟随面板刷新间隔（最低 5s；面板关闭
// 自动刷新时回落 5 分钟）——与菜单栏同节奏读同一份 QuotaCache，两边数字始终
// 一致（此前徽标拿到数据后 5 分钟才再读，会与菜单栏最多分叉 5 分钟）。
// 真正是否命中官方接口由原生 QuotaCache 的 5 分钟节流窗口决定（缓存优先、
// 失败保留上次值），故轮询再快也绝不会把 /api/oauth/usage 打限流。
// 读不到凭据/失败返回 []（徽标降级显示 "—"）。
const QUOTA_REFETCH_INTERVAL_MS = 5 * 60 * 1000; // 无面板间隔可跟随时的兜底
const QUOTA_MIN_POLL_MS = 5 * 1000;
// 拿到数据前的快速重试间隔：面板加载时若正好赶上限流/缓存冷会拿到空值(徽标显示 "—")，
// 每 20s 重试直到有数据再降到 5 分钟慢刷——这样就不会「菜单栏已恢复、面板还空 5 分钟」。
// 原生 QuotaCache 已把真实 /api/oauth/usage 节流到 5 分钟，前端多读几次只命中缓存、不会打限流。
const QUOTA_FAST_RETRY_MS = 20 * 1000;

function useQuotaTiers(pollMs: number): QuotaTierData[] {
  const [tiers, setTiers] = useState<QuotaTierData[]>([]);
  useEffect(() => {
    let alive = true;
    let timer: number | undefined;
    let gotData = false;
    // 稳态节奏：跟随面板刷新间隔（下限 5s）；面板关闭自动刷新时回落 5 分钟兜底
    const steadyMs =
      pollMs > 0 ? Math.max(pollMs, QUOTA_MIN_POLL_MS) : QUOTA_REFETCH_INTERVAL_MS;
    const tick = async () => {
      try {
        const data = await invoke<QuotaTierData[]>("get_quota");
        // 只在拿到非空数据时更新；失败/空(如 429 限流)保留上次值，不空成 "—"
        if (alive && Array.isArray(data) && data.length) {
          setTiers(data);
          gotData = true;
        }
      } catch {
        /* 保留上次值，不清空 */
      }
      if (!alive) return;
      // 拿到数据前每 20s 重试；拿到后按稳态节奏轮询（只读原生缓存，成本≈0）
      timer = window.setTimeout(
        () => void tick(),
        gotData ? steadyMs : QUOTA_FAST_RETRY_MS,
      );
    };
    void tick();
    return () => {
      alive = false;
      if (timer !== undefined) window.clearTimeout(timer);
    };
  }, [pollMs]);
  return tiers;
}

function QuotaBadge({ label, tier }: { label: string; tier?: QuotaTierData }) {
  const pct = tier ? Math.round(tier.utilization) : null;
  const frac = tier ? Math.min(1, Math.max(0, tier.utilization / 100)) : 0;
  const color = tier ? quotaColor(tier.utilization) : undefined;
  const countdown = tier ? quotaCountdown(tier.resetsAt) : null;

  const title = tier
    ? [
        `${label} · ${pct}%`,
        countdown ? `resets in ${countdown}` : null,
        tier.planLabel || null,
      ]
        .filter(Boolean)
        .join(" · ")
    : `${label}: no data`;

  return (
    <div
      title={title}
      className="flex h-9 flex-col justify-center gap-0.5 rounded-md border border-border/50 bg-background px-2.5 text-xs"
    >
      <div className="flex items-center gap-1.5">
        <span className="font-medium text-muted-foreground">{label}</span>
        <span
          className={cn(
            "font-semibold tabular-nums",
            pct == null && "text-muted-foreground",
          )}
          style={color ? { color } : undefined}
        >
          {pct == null ? "—" : `${pct}%`}
        </span>
        <div className="relative h-1.5 w-8 overflow-hidden rounded-full bg-muted">
          <div
            className="absolute inset-y-0 left-0 rounded-full transition-[width]"
            style={{ width: `${frac * 100}%`, backgroundColor: color ?? "transparent" }}
          />
        </div>
      </div>
      {/* 重置倒计时行（Clock + "2h28m"，样式对齐 cc-switch TierBadge 的 inline 倒计时）。
          无数据/已重置时占位 "—"，保持徽标高度稳定不跳动。 */}
      <div className="flex items-center gap-1 text-[10px] leading-none text-muted-foreground/70 tabular-nums">
        <Clock className="h-2.5 w-2.5 shrink-0" />
        <span>{countdown ?? "—"}</span>
      </div>
    </div>
  );
}

function QuotaBadges({ pollMs }: { pollMs: number }) {
  const tiers = useQuotaTiers(pollMs);
  // 倒计时行的本地步进：额度数据最慢 5 分钟才轮询一次（面板关闭自动刷新时），
  // 若只靠轮询重渲染，倒计时会"停走"最多 5 分钟。这里每 30s 强制重渲染一次让
  // quotaCountdown 重算——纯本地计算，不碰 get_quota、更不碰官方接口。
  const [, setTick] = useState(0);
  useEffect(() => {
    const id = window.setInterval(() => setTick((n) => n + 1), 30_000);
    return () => window.clearInterval(id);
  }, []);
  const fiveHour = tiers.find((t) => t.name === "five_hour");
  const weekly = tiers.find((t) => t.name === "seven_day");
  return (
    <div className="flex items-center gap-1.5">
      <QuotaBadge label="5H" tier={fiveHour} />
      <QuotaBadge label="Week" tier={weekly} />
    </div>
  );
}

function EmbedUsagePanel() {
  const { t, i18n: i18nInstance } = useTranslation();
  const queryClientInstance = useQueryClient();
  const [range, setRange] = useState<UsageRangeSelection>({ preset: "today" });
  const [appType, setAppType] = useState<AppTypeFilter>("all");
  const [providerName, setProviderName] = useState<string | undefined>(
    undefined,
  );
  const [model, setModel] = useState<string | undefined>(undefined);
  const [refreshIntervalMs, setRefreshIntervalMs] = useState(
    loadStoredRefreshIntervalMs,
  );

  // 启动时向原生要权威值（UserDefaults）：file:// 场景 localStorage 偶发不跨启动
  // 持久，以原生存的为准兜底；两边一致时无感。浏览器冒烟（无桥）静默跳过。
  useEffect(() => {
    let alive = true;
    invoke<number | null>("get_setting", { key: "refreshIntervalMs" }).then(
      (v) => {
        if (!alive || typeof v !== "number" || !isRefreshOption(v)) return;
        setRefreshIntervalMs(v);
        try {
          window.localStorage.setItem(REFRESH_INTERVAL_STORAGE_KEY, String(v));
        } catch {
          /* ignore */
        }
      },
      () => {
        /* 桥不可用时忽略 */
      },
    );
    return () => {
      alive = false;
    };
  }, []);

  const changeAppType = (next: AppTypeFilter) => {
    setAppType(next);
    if (next !== appType) {
      setProviderName(undefined);
      setModel(undefined);
    }
  };
  const changeProviderName = (next: string | undefined) => {
    setProviderName(next);
    if (next !== providerName) {
      setModel(undefined);
    }
  };

  useUsageEventBridge();

  const changeRefreshInterval = (next: number) => {
    setRefreshIntervalMs(next);
    try {
      window.localStorage.setItem(REFRESH_INTERVAL_STORAGE_KEY, String(next));
    } catch {
      /* ignore */
    }
    // 写穿原生：持久化到 UserDefaults，并把菜单栏刷新节奏同步成同一个值
    void invoke("set_setting", {
      key: "refreshIntervalMs",
      value: next,
    }).catch(() => {});
    queryClientInstance.invalidateQueries({ queryKey: usageKeys.all });
  };

  const language =
    i18nInstance.resolvedLanguage || i18nInstance.language || "en";
  const locale = getLocaleFromLanguage(language);
  const resolvedRange = useMemo(() => resolveUsageRange(range), [range]);
  const rangeLabel = useMemo(() => {
    if (range.preset !== "custom") {
      return getUsageRangePresetLabel(range.preset, t);
    }

    const startStr = new Date(resolvedRange.startDate * 1000).toLocaleString(
      locale,
    );

    if (range.liveEndTime) {
      return `${startStr} → ${t("usage.liveEndTimeNow", "现在")}`;
    }

    const endStr = new Date(resolvedRange.endDate * 1000).toLocaleString(
      locale,
    );
    return `${startStr} - ${endStr}`;
  }, [locale, range, resolvedRange.endDate, resolvedRange.startDate, t]);

  const optionsRefetch = {
    refetchInterval:
      refreshIntervalMs > 0 ? refreshIntervalMs : (false as const),
  };
  const { data: providerOptionsData } = useProviderStats(
    range,
    { appType },
    optionsRefetch,
  );
  const { data: modelOptionsData } = useModelStats(
    range,
    { appType, providerName },
    optionsRefetch,
  );

  const providerOptions = useMemo(() => {
    const names = new Set<string>();
    for (const stat of providerOptionsData ?? []) {
      names.add(stat.providerName);
    }
    if (providerName) names.add(providerName);
    return Array.from(names);
  }, [providerOptionsData, providerName]);

  const modelOptions = useMemo(() => {
    const names = new Set<string>();
    for (const stat of modelOptionsData ?? []) {
      names.add(stat.model);
    }
    if (model) names.add(model);
    return Array.from(names);
  }, [modelOptionsData, model]);

  return (
    <motion.div
      initial={{ opacity: 0, y: 10 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.4 }}
      className="space-y-8 pb-8"
    >
      <div className="flex flex-col lg:flex-row lg:items-end justify-between gap-4 mb-2">
        <div className="flex flex-col gap-1">
          <h2 className="text-2xl font-bold tracking-tight">
            {t("usage.title")}
          </h2>
          <p className="text-sm text-muted-foreground">{t("usage.subtitle")}</p>
        </div>

        <div className="flex items-center gap-2">
          <div className="flex items-center p-1 bg-muted/30 rounded-lg border border-border/50">
            {APP_FILTER_OPTIONS.map((type) => {
              const label = t(`usage.appFilter.${type}`);
              return (
                <button
                  key={type}
                  type="button"
                  onClick={() => changeAppType(type)}
                  title={label}
                  aria-label={label}
                  className={cn(
                    "flex h-8 items-center justify-center px-2.5 rounded-md transition-all",
                    appType === type
                      ? "bg-background text-primary shadow-sm"
                      : "text-muted-foreground hover:text-foreground hover:bg-muted/50",
                  )}
                >
                  {type === "all" ? (
                    <LayoutGrid className="h-4 w-4" />
                  ) : (
                    <ProviderIcon
                      icon={APP_FILTER_ICON[type]}
                      name={label}
                      size={16}
                    />
                  )}
                </button>
              );
            })}
          </div>

          <Select
            value={
              providerName != null ? encodeOptionValue(providerName) : "all"
            }
            onValueChange={(v) => changeProviderName(decodeOptionValue(v))}
          >
            <SelectTrigger
              className="h-9 w-[100px] bg-background text-xs focus:border-border-default [&>span]:min-w-0 [&>span]:truncate"
              title={providerName ?? t("usage.filterBySource")}
            >
              <SelectValue />
            </SelectTrigger>
            <SelectContent className="max-w-[280px]">
              <SelectItem value="all">{t("usage.allSources")}</SelectItem>
              {providerOptions.map((name) => (
                <SelectItem
                  key={name}
                  value={encodeOptionValue(name)}
                  title={name}
                  className="[&>span]:min-w-0 [&>span]:truncate"
                >
                  {name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>

          <Select
            value={model != null ? encodeOptionValue(model) : "all"}
            onValueChange={(v) => setModel(decodeOptionValue(v))}
          >
            <SelectTrigger
              className="h-9 w-[100px] bg-background text-xs focus:border-border-default [&>span]:min-w-0 [&>span]:truncate"
              title={model ?? t("usage.filterByModel")}
            >
              <SelectValue />
            </SelectTrigger>
            <SelectContent className="max-w-[280px]">
              <SelectItem value="all">{t("usage.allModels")}</SelectItem>
              {modelOptions.map((name) => (
                <SelectItem
                  key={name}
                  value={encodeOptionValue(name)}
                  title={name}
                  className="[&>span]:min-w-0 [&>span]:truncate"
                >
                  {name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>

          <div className="flex items-center gap-2 ml-auto lg:ml-0">
            <Select
              value={String(refreshIntervalMs)}
              onValueChange={(v) => changeRefreshInterval(Number(v))}
            >
              <SelectTrigger
                className="h-9 w-[100px] bg-background text-xs focus:border-border-default"
                title={t("usage.refreshInterval")}
                aria-label={t("usage.refreshInterval")}
              >
                <span className="flex items-center gap-2">
                  <RefreshCw className="h-3.5 w-3.5 shrink-0" />
                  <SelectValue />
                </span>
              </SelectTrigger>
              <SelectContent>
                {REFRESH_INTERVAL_OPTIONS_MS.map((ms) => (
                  <SelectItem key={ms} value={String(ms)}>
                    {ms > 0 ? `${ms / 1000}s` : t("usage.refreshOff")}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>

            <UsageDateRangePicker
              selection={range}
              triggerLabel={rangeLabel}
              onApply={(nextRange) => setRange(nextRange)}
            />

            {/* 5H / Week 官方额度徽标，并入右侧 ml-auto 组末尾 → 顶到最右、同一排 */}
            <QuotaBadges pollMs={refreshIntervalMs} />
          </div>
        </div>
      </div>

      <UsageHero
        range={range}
        appType={appType === "all" ? undefined : appType}
        providerName={providerName}
        model={model}
        refreshIntervalMs={refreshIntervalMs}
      />

      <UsageTrendChart
        range={range}
        rangeLabel={rangeLabel}
        appType={appType}
        providerName={providerName}
        model={model}
        refreshIntervalMs={refreshIntervalMs}
      />

      {/* 下半部 Tabs：Request Logs / Provider Stats / Model Stats
          结构照抄 UsageDashboard.tsx；传参用面板现有 state（与 Dashboard 一致）。 */}
      <div className="space-y-4">
        <Tabs defaultValue="logs" className="w-full">
          <div className="flex items-center justify-between mb-4">
            <TabsList className="bg-muted/50">
              <TabsTrigger value="logs" className="gap-2">
                <ListFilter className="h-4 w-4" />
                {t("usage.requestLogs")}
              </TabsTrigger>
              <TabsTrigger value="providers" className="gap-2">
                <Activity className="h-4 w-4" />
                {t("usage.providerStats")}
              </TabsTrigger>
              <TabsTrigger value="models" className="gap-2">
                <BarChart3 className="h-4 w-4" />
                {t("usage.modelStats")}
              </TabsTrigger>
            </TabsList>
          </div>

          <motion.div
            initial={{ opacity: 0, y: 10 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.2 }}
          >
            <TabsContent value="logs" className="mt-0">
              <RequestLogTable
                range={range}
                rangeLabel={rangeLabel}
                appType={appType}
                providerName={providerName}
                model={model}
                refreshIntervalMs={refreshIntervalMs}
                onRangeChange={setRange}
              />
            </TabsContent>

            <TabsContent value="providers" className="mt-0">
              <ProviderStatsTable
                range={range}
                appType={appType}
                providerName={providerName}
                model={model}
                refreshIntervalMs={refreshIntervalMs}
              />
            </TabsContent>

            <TabsContent value="models" className="mt-0">
              <ModelStatsTable
                range={range}
                appType={appType}
                providerName={providerName}
                model={model}
                refreshIntervalMs={refreshIntervalMs}
              />
            </TabsContent>
          </motion.div>
        </Tabs>
      </div>
    </motion.div>
  );
}

/* ────────────────────────── bootstrap ────────────────────────── */

// 强制深色主题 + 英文文案（"Tokens Processed" / "Fresh Input" 等）。
document.documentElement.classList.add("dark");
try {
  window.localStorage.setItem("language", "en");
} catch {
  /* localStorage 不可用时忽略 */
}
void i18n.changeLanguage("en");

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      {/* 顶部额外留白 ~46px：避开原生窗口左上角交通灯（.hiddenTitleBar，内容边到边） */}
      <div className="px-4 pb-4 md:px-6 md:pb-6" style={{ paddingTop: 46 }}>
        <EmbedUsagePanel />
      </div>
    </QueryClientProvider>
  </React.StrictMode>,
);
