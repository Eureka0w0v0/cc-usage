/**
 * Embed 入口：把 cc-switch v4.0.20 的用量页（只读精简版）跑在 CC Usage 主窗口的 WKWebView 里。
 *
 * 照 src/components/usage/UsageDashboard.tsx（v4.0.20，#8711 重排之后）改写：页头 → 范围栏（时间 → 应用 →
 * 供应商 / 模型级联菜单）→ 概览面板（指标条 + 图表，点指标换图表画的指标）→ 明细面板（请求日志 / 供应商 /
 * 模型三个页签，带数量）→ 点一条请求看详情。与上游的差异：
 * - 只读：不要同步按钮、用量设置抽屉（数据来源 / 显示 / 定价）、重建 Codex、空状态——它们都会写
 *   cc-switch 的库或设置（2026-10-15 与用户逐项确认，2026-10-26 升 v4.0.20 时沿用）；
 * - 页头右侧：CC Usage 自己的刷新间隔（关 / 5 / 10 / 30 / 60 秒，默认 5 秒，存原生 UserDefaults、和菜单栏
 *   同步）、趋势图样式（柱形 / 面积；上游放在设置抽屉的「显示」里，我们没有抽屉）、官方额度徽标；
 * - 热力图常驻（2026-10-10 用户选定）：非「全部」范围时在趋势图下方，「全部」范围只显示热力图；
 * - 显示设置（请求日志列显隐、图表样式）存本应用的 UserDefaults，应用码片按 cc-switch「应用」页的显示设置
 *   过滤（原生 get_settings 只读镜像 settings.json 的 visibleApps）；
 * - 记住的选择（时间范围、页签、指标、每页条数）：上游记在 localStorage，WKWebView 的 file:// localStorage
 *   不保证跨启动保留 → 渲染前从原生灌回 localStorage，之后每次改写同时写原生；
 * - 刷新：子组件都不轮询（refreshIntervalMs=0），这里按间隔统一失效重查（原生每次查询都会顺带续读会话日志
 *   叠加层），窗口不可见时暂停、回来立刻补一次；
 * - 固定深色主题 + 英文（与用户 cc-switch 的设置一致）。
 */

import "./index.css";

import React, { useEffect, useMemo, useState } from "react";
import ReactDOM from "react-dom/client";
import { invoke } from "@tauri-apps/api/core";
import { useTranslation } from "react-i18next";
import { MotionConfig } from "framer-motion";
import {
  ChartArea,
  ChartColumn,
  Check,
  ChevronDown,
  ChevronRight,
  Clock,
  ListFilter,
  ListTree,
  RefreshCw,
} from "lucide-react";
import {
  QueryClientProvider,
  focusManager,
  useQueryClient,
} from "@tanstack/react-query";

import i18n from "@/i18n";
import { queryClient } from "@/lib/query/queryClient";
import { useSettingsQuery } from "@/lib/query";
import { ThemeProvider } from "@/components/theme-provider";
import { TooltipProvider } from "@/components/ui/tooltip";
import { Toaster } from "@/components/ui/sonner";
import { AppPageHeader } from "@/components/shell/AppPageHeader";
import { AppGlyph, APP_DISPLAY_NAME } from "@/components/shell/AppGlyph";
import { HelpTip } from "@/components/ui/help-tip";
import { PageTabs } from "@/components/ui/page-tabs";
import { Button } from "@/components/ui/button";
import { HoverTip } from "@/components/ui/hover-tip";
import {
  SegmentThumb,
  useSlidingIndicator,
} from "@/components/ui/sliding-indicator";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuPortal,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { DEFAULT_VISIBLE_APPS } from "@/config/appConfig";
import type { Settings, UsageDisplaySettings } from "@/types";
import {
  KNOWN_APP_TYPES,
  type AppTypeFilter,
  type UsageRangePreset,
  type UsageRangeSelection,
} from "@/types/usage";
import {
  usageKeys,
  useModelStats,
  useProviderStats,
  useRequestLogs,
} from "@/lib/query/usage";
import { useUsageEventBridge } from "@/hooks/useUsageEventBridge";
import { getUsageRangePresetLabel, resolveUsageRange } from "@/lib/usageRange";
import { cn } from "@/lib/utils";
import { UsageHero } from "@/components/usage/UsageHero";
import { UsageTrendChart } from "@/components/usage/UsageTrendChart";
import { UsageHeatmap } from "@/components/usage/UsageHeatmap";
import { RequestLogTable } from "@/components/usage/RequestLogTable";
import { ProviderStatsTable } from "@/components/usage/ProviderStatsTable";
import { ModelStatsTable } from "@/components/usage/ModelStatsTable";
import { RequestDetailPanel } from "@/components/usage/RequestDetailPanel";
import { RequestLogColumnsMenu } from "@/components/usage/RequestLogColumnsMenu";
import { resolveRequestLogColumns } from "@/components/usage/requestLogColumns";
import { UsageDateRangePicker } from "@/components/usage/UsageDateRangePicker";
import {
  LOG_PAGE_SIZES,
  type LogPageSize,
  USAGE_CHOICE_KEYS,
  USAGE_METRICS,
  type UsageMetric,
  readRememberedChoice,
  writeRememberedChoice,
} from "@/components/usage/rememberedChoice";
import {
  TREND_CHART_TYPES,
  fmtInt,
  getLocaleFromLanguage,
  resolveTrendChartType,
} from "@/components/usage/format";
import {
  getUsageProviderLabel,
  usageProviderTitle,
} from "@/components/usage/providerLabel";
import { useElementWidth } from "@/components/usage/usageTable";

/* ───────── 刷新间隔（CC Usage 自己的，和菜单栏联动） ───────── */

// 0 表示关闭自动刷新。默认 5 秒（与菜单栏一致）。选择结果写 localStorage（快路径，首帧免闪）+
// 原生 UserDefaults（权威，WKWebView 的 file:// localStorage 偶发不跨启动持久），并经 set_setting
// 把菜单栏的原生刷新节奏同步成同一个值。
const REFRESH_INTERVAL_OPTIONS_MS = [0, 5000, 10000, 30000, 60000] as const;
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

const refreshLabel = (ms: number) => (ms > 0 ? `${ms / 1000}s` : "Off");

/**
 * 按刷新间隔统一失效重查。子组件都不轮询（同 v4：它们拿到的 refreshIntervalMs 是 0），由这里定时让
 * 整页重查；原生每次查询都会顺带续读会话日志叠加层，所以新用量跟着出现。窗口不可见时停，重新可见时
 * 立刻补一次（节奏同 v4 的 useUsageAutoRefresh）。
 */
function useEmbedAutoRefresh(refreshIntervalMs: number) {
  const queryClientInstance = useQueryClient();
  useEffect(() => {
    if (refreshIntervalMs <= 0) return;
    const refresh = () => {
      if (focusManager.isFocused()) {
        void queryClientInstance.invalidateQueries({ queryKey: usageKeys.all });
      }
    };
    const timer = window.setInterval(refresh, refreshIntervalMs);
    const unsubscribe = focusManager.subscribe((focused) => {
      if (focused) refresh();
    });
    return () => {
      window.clearInterval(timer);
      unsubscribe();
    };
  }, [queryClientInstance, refreshIntervalMs]);
}

/* ───────── 记住的选择：localStorage 快路径 + 原生 UserDefaults 权威 ───────── */

// 上游 rememberedChoice 的 localStorage 键 → 原生 set_setting 的键（UserDefaults 里是 embed.<键>）。
const NATIVE_CHOICE_KEYS: Record<string, string> = {
  [USAGE_CHOICE_KEYS.tab]: "usage.tab",
  [USAGE_CHOICE_KEYS.range]: "usage.rangePreset",
  [USAGE_CHOICE_KEYS.trendMetric]: "usage.trendMetric",
  [USAGE_CHOICE_KEYS.logPageSize]: "usage.logPageSize",
};

/** 记下一个选择：写 localStorage（上游的 readRememberedChoice 读它），同时写原生。 */
function rememberChoice(key: string, value: string) {
  writeRememberedChoice(key, value);
  const nativeKey = NATIVE_CHOICE_KEYS[key];
  if (nativeKey) {
    void invoke("set_setting", { key: nativeKey, value }).catch(() => {});
  }
}

/** 同上游 useRememberedChoice，只是改写时经 rememberChoice 一并写原生。 */
function useNativeRememberedChoice<T extends string>(
  key: string,
  allowed: readonly T[],
  fallback: T,
) {
  const [value, setValue] = useState<T>(() =>
    readRememberedChoice(key, allowed, fallback),
  );
  const update = (next: T) => {
    setValue(next);
    rememberChoice(key, next);
  };
  return [value, update] as const;
}

/** 渲染前把原生存的选择灌进 localStorage；原生没回话（如浏览器冒烟）就按默认渲染，最多等 timeoutMs。 */
async function hydrateRememberedChoices(timeoutMs: number) {
  const load = Promise.all(
    Object.entries(NATIVE_CHOICE_KEYS).map(async ([storageKey, nativeKey]) => {
      const value = await invoke<unknown>("get_setting", { key: nativeKey });
      if (typeof value !== "string") return;
      try {
        window.localStorage.setItem(storageKey, value);
      } catch {
        /* 写不了就按默认 */
      }
    }),
  ).catch(() => {});
  await Promise.race([
    load,
    new Promise((resolve) => window.setTimeout(resolve, timeoutMs)),
  ]);
}

/* ───────── 官方额度徽标（页头右侧，数据来自原生 get_quota） ───────── */

type QuotaTierData = {
  name: string;
  utilization: number; // 0–100
  resetsAt?: string | null;
  planLabel?: string | null;
};

// 连续渐变配色：用量 0→100% 时色相从 140°(绿) 平滑过渡到 0°(红)，途中经过黄绿/黄/橙。
function quotaColor(util: number): string {
  const t = Math.min(1, Math.max(0, util / 100));
  const hue = Math.round(140 * (1 - t));
  return `hsl(${hue}, 72%, 48%)`;
}

// 重置倒计时：3d12h / 2h30m / 45m；已重置 / 无数据返回 null
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

// 轮询原生 get_quota。稳态节奏跟随面板刷新间隔（最低 5s；关闭自动刷新时回落 5 分钟），与菜单栏读同一份
// QuotaCache，两边数字一致；真正是否打官方接口由原生 5 分钟节流决定，轮询再快也不会被限流。
// 拿到数据前每 20s 重试（首屏碰上限流或缓存冷时不至于空 5 分钟）。失败 / 空保留上次值。
const QUOTA_REFETCH_INTERVAL_MS = 5 * 60 * 1000;
const QUOTA_MIN_POLL_MS = 5 * 1000;
const QUOTA_FAST_RETRY_MS = 20 * 1000;

function useQuotaTiers(pollMs: number): QuotaTierData[] {
  const [tiers, setTiers] = useState<QuotaTierData[]>([]);
  useEffect(() => {
    let alive = true;
    let timer: number | undefined;
    let gotData = false;
    const steadyMs =
      pollMs > 0 ? Math.max(pollMs, QUOTA_MIN_POLL_MS) : QUOTA_REFETCH_INTERVAL_MS;
    const tick = async () => {
      try {
        const data = await invoke<QuotaTierData[]>("get_quota");
        if (alive && Array.isArray(data) && data.length) {
          setTiers(data);
          gotData = true;
        }
      } catch {
        /* 保留上次值，不清空 */
      }
      if (!alive) return;
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

// 顺序即展示序，与原生 ClaudeQuotaParser.knownTiers 一致。5H / Week 无数据也占位（否则首屏会先塌再弹）；
// 模型专属的 Fable / Opus / Sonnet 只在接口真给了数据时出现。
const QUOTA_BADGES: { name: string; label: string; always: boolean }[] = [
  { name: "five_hour", label: "5H", always: true },
  { name: "seven_day", label: "Week", always: true },
  { name: "seven_day_fable", label: "Fable", always: false },
  { name: "seven_day_opus", label: "Opus", always: false },
  { name: "seven_day_sonnet", label: "Sonnet", always: false },
];

function QuotaBadge({ label, tier }: { label: string; tier?: QuotaTierData }) {
  const pct = tier ? Math.round(tier.utilization) : null;
  const frac = tier ? Math.min(1, Math.max(0, tier.utilization / 100)) : 0;
  const color = tier ? quotaColor(tier.utilization) : undefined;
  const countdown = tier ? quotaCountdown(tier.resetsAt) : null;
  const title = tier
    ? [`${label} · ${pct}%`, countdown ? `resets in ${countdown}` : null, tier.planLabel || null]
        .filter(Boolean)
        .join(" · ")
    : `${label}: no data`;

  return (
    <div
      title={title}
      className="flex h-[34px] shrink-0 flex-col justify-center gap-0.5 rounded-control border border-border bg-surface px-2.5 text-caption"
    >
      <div className="flex items-center gap-1.5">
        <span className="font-medium text-fg-2">{label}</span>
        <span
          className={cn("font-semibold tabular-nums", pct == null && "text-fg-3")}
          style={color ? { color } : undefined}
        >
          {pct == null ? "—" : `${pct}%`}
        </span>
        <div className="relative h-1.5 w-8 overflow-hidden rounded-full bg-subtle">
          <div
            className="absolute inset-y-0 left-0 rounded-full transition-[width]"
            style={{ width: `${frac * 100}%`, backgroundColor: color ?? "transparent" }}
          />
        </div>
      </div>
      {/* 重置倒计时行；无数据 / 已重置时占位「—」，徽标高度不跳 */}
      <div className="flex items-center gap-1 text-[10px] leading-none tabular-nums text-fg-3">
        <Clock className="h-2.5 w-2.5 shrink-0" />
        <span>{countdown ?? "—"}</span>
      </div>
    </div>
  );
}

function QuotaBadges({ pollMs }: { pollMs: number }) {
  const tiers = useQuotaTiers(pollMs);
  // 倒计时本地步进：额度最慢 5 分钟才轮询一次，这里每 30s 重渲染让倒计时继续走（纯本地计算）
  const [, setTick] = useState(0);
  useEffect(() => {
    const id = window.setInterval(() => setTick((n) => n + 1), 30_000);
    return () => window.clearInterval(id);
  }, []);
  return (
    <div className="flex shrink-0 items-center gap-1.5">
      {QUOTA_BADGES.map(({ name, label, always }) => {
        const tier = tiers.find((t) => t.name === name);
        if (!tier && !always) return null;
        return <QuotaBadge key={name} label={label} tier={tier} />;
      })}
    </div>
  );
}

/* ───────── 用量页（照 v4.0.20 UsageDashboard，只读） ───────── */

const STATUS_CODE_OPTIONS = [200, 400, 401, 429, 500] as const;

type UsageTab = "logs" | "providers" | "models";
const TABS: UsageTab[] = ["logs", "providers", "models"];
/** 记住的时间范围只认预设：自定义的起止日期过几天就不是用户想看的了，选自定义时不改记下的预设（同上游） */
const REMEMBERED_RANGE_PRESETS: UsageRangePreset[] = [
  "today",
  "1d",
  "7d",
  "14d",
  "30d",
  "all",
];
const LOG_PAGE_SIZE_OPTIONS = LOG_PAGE_SIZES.map(Number);

const menuContentClass =
  "min-w-[200px] max-w-[320px] rounded-panel border-border bg-surface p-1 shadow-v7-md";
const menuItemClass = "h-[30px] gap-2 rounded-control px-2 text-body";

function MenuCheck({ checked }: { checked: boolean }) {
  return (
    <Check
      aria-hidden="true"
      strokeWidth={1.75}
      className={cn("h-3.5 w-3.5 shrink-0", !checked && "invisible")}
    />
  );
}

function MenuMeta({ children }: { children: React.ReactNode }) {
  return (
    <span className="ms-auto ps-3 text-caption tabular-nums text-fg-3">
      {children}
    </span>
  );
}

/** 级联菜单第二级：某个供应商（或全部供应商）名下的模型，展开时才查（同上游） */
function ScopeModelItems({
  range,
  appType,
  providerName,
  providerCount,
  active,
  selectedModel,
  locale,
  onPick,
}: {
  range: UsageRangeSelection;
  appType: AppTypeFilter;
  providerName: string | undefined;
  providerCount: number;
  /** 这一级就是当前选中的供应商（勾才画在它的模型上） */
  active: boolean;
  selectedModel: string | undefined;
  locale: string;
  onPick: (model: string | undefined) => void;
}) {
  const { t } = useTranslation();
  const { data } = useModelStats(
    range,
    { appType, providerName },
    { refetchInterval: false },
  );
  const options = useMemo(() => {
    const counts = new Map<string, number>();
    for (const stat of data ?? []) {
      counts.set(stat.model, (counts.get(stat.model) ?? 0) + stat.requestCount);
    }
    // 数据刷新后选中项可能掉出列表（如改了时间范围）；补回去保证看得见、能清除
    if (selectedModel && !counts.has(selectedModel)) {
      counts.set(selectedModel, 0);
    }
    return Array.from(counts, ([name, count]) => ({ name, count })).sort(
      (a, b) => b.count - a.count,
    );
  }, [data, selectedModel]);

  return (
    <>
      <DropdownMenuItem className={menuItemClass} onSelect={() => onPick(undefined)}>
        <MenuCheck checked={active && selectedModel == null} />
        {t("usage.allModels")}
        <MenuMeta>{fmtInt(providerCount, locale)}</MenuMeta>
      </DropdownMenuItem>
      {options.map((option) => (
        <DropdownMenuItem
          key={option.name}
          className={menuItemClass}
          title={option.name}
          onSelect={() => onPick(option.name)}
        >
          <MenuCheck checked={active && selectedModel === option.name} />
          <span className="min-w-0 truncate font-mono text-caption">{option.name}</span>
          <MenuMeta>{fmtInt(option.count, locale)}</MenuMeta>
        </DropdownMenuItem>
      ))}
    </>
  );
}

function EmbedUsagePanel() {
  const { t, i18n: i18nInstance } = useTranslation();
  const queryClientInstance = useQueryClient();
  const [range, setRange] = useState<UsageRangeSelection>(() => ({
    preset: readRememberedChoice(USAGE_CHOICE_KEYS.range, REMEMBERED_RANGE_PRESETS, "today"),
  }));
  const applyRange = (next: UsageRangeSelection) => {
    setRange(next);
    if (next.preset !== "custom") rememberChoice(USAGE_CHOICE_KEYS.range, next.preset);
  };
  const [appType, setAppType] = useState<AppTypeFilter>("all");
  const [providerName, setProviderName] = useState<string | undefined>(undefined);
  const [model, setModel] = useState<string | undefined>(undefined);
  const [statusCode, setStatusCode] = useState<number | undefined>(undefined);
  const [tab, setTab] = useNativeRememberedChoice<UsageTab>(USAGE_CHOICE_KEYS.tab, TABS, "logs");
  // 指标条选中的指标，也是趋势图 / 热力图画的指标
  const [metric, setMetric] = useNativeRememberedChoice<UsageMetric>(
    USAGE_CHOICE_KEYS.trendMetric,
    USAGE_METRICS,
    "tokens",
  );
  // 请求日志每页几条：页签计数的查询也用它，和表格合并成一次请求（同上游）
  const [logPageSizeChoice, setLogPageSizeChoice] = useNativeRememberedChoice<LogPageSize>(
    USAGE_CHOICE_KEYS.logPageSize,
    LOG_PAGE_SIZES,
    "20",
  );
  const logPageSize = Number(logPageSizeChoice);
  const [detailRequestId, setDetailRequestId] = useState<string | null>(null);
  const [refreshIntervalMs, setRefreshIntervalMs] = useState(loadStoredRefreshIntervalMs);
  const [scopeMenuOpen, setScopeMenuOpen] = useState(false);
  const [containerRef, measuredWidth] = useElementWidth<HTMLDivElement>();
  // 测量不到时按宽窗口排
  const compact = (measuredWidth || 1000) < 720;

  // 显示设置（列显隐、趋势图样式）与 cc-switch「应用」页的显示设置：原生 get_settings 拼好给过来。
  // UsageTrendChart 自己也经同一个查询读图表样式，所以改完要让这个查询重取。
  const { data: settings } = useSettingsQuery();
  const usageDisplay = settings?.usageDisplay;
  const logColumns = resolveRequestLogColumns(usageDisplay?.requestLogColumns);
  const chartType = resolveTrendChartType(usageDisplay);
  const saveUsageDisplay = async (next: UsageDisplaySettings): Promise<boolean> => {
    queryClientInstance.setQueryData<Settings>(["settings"], (prev) =>
      prev ? { ...prev, usageDisplay: next } : prev,
    );
    try {
      await invoke("set_setting", { key: "usageDisplay", value: JSON.stringify(next) });
      return true;
    } catch {
      return false;
    } finally {
      void queryClientInstance.invalidateQueries({ queryKey: ["settings"] });
    }
  };

  // 启动时向原生要权威值（UserDefaults）：file:// 场景 localStorage 偶发不跨启动持久。
  // 浏览器冒烟（没有原生桥）时静默跳过。
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

  // 后端写入新日志时 emit `usage-log-recorded`（embed 里是空实现，刷新靠下面的定时失效）
  useUsageEventBridge();
  useEmbedAutoRefresh(refreshIntervalMs);

  // 切应用时清掉下游筛选，避免留下一个在新范围内查无数据的「幽灵」组合
  const changeAppType = (next: AppTypeFilter) => {
    setAppType(next);
    if (next !== appType) {
      setProviderName(undefined);
      setModel(undefined);
    }
  };
  // 供应商和模型一次选定（级联菜单）
  const pickScope = (nextProvider: string | undefined, nextModel: string | undefined) => {
    setProviderName(nextProvider);
    setModel(nextModel);
    setScopeMenuOpen(false);
  };

  const changeRefreshInterval = (next: number) => {
    setRefreshIntervalMs(next);
    try {
      window.localStorage.setItem(REFRESH_INTERVAL_STORAGE_KEY, String(next));
    } catch {
      /* ignore */
    }
    // 写穿原生：持久化到 UserDefaults，并把菜单栏刷新节奏同步成同一个值
    void invoke("set_setting", { key: "refreshIntervalMs", value: next }).catch(() => {});
    void queryClientInstance.invalidateQueries({ queryKey: usageKeys.all });
  };

  const language = i18nInstance.resolvedLanguage || i18nInstance.language || "en";
  const locale = getLocaleFromLanguage(language);
  const resolvedRange = useMemo(() => resolveUsageRange(range), [range]);
  const rangeLabel = useMemo(() => {
    if (range.preset !== "custom") {
      return getUsageRangePresetLabel(range.preset, t);
    }
    const startStr = new Date(resolvedRange.startDate * 1000).toLocaleString(locale);
    if (range.liveEndTime) {
      return `${startStr} → ${t("usage.liveEndTimeNow", "现在")}`;
    }
    const endStr = new Date(resolvedRange.endDate * 1000).toLocaleString(locale);
    return `${startStr} - ${endStr}`;
  }, [locale, range, resolvedRange.endDate, resolvedRange.startDate, t]);

  // 级联菜单第一级：供应商列表只跟应用 / 时间范围走（不受自身选中值影响）。都不轮询，由
  // useEmbedAutoRefresh 统一失效重查。
  const refetch = { refetchInterval: false as const };
  const { data: providerOptionsData } = useProviderStats(range, { appType }, refetch);

  const providerOptions = useMemo(() => {
    const counts = new Map<string, number>();
    for (const stat of providerOptionsData ?? []) {
      counts.set(stat.providerName, (counts.get(stat.providerName) ?? 0) + stat.requestCount);
    }
    // 数据刷新后选中项可能掉出列表（如改了时间范围）；补回去保证用户看得见、能清除
    if (providerName && !counts.has(providerName)) counts.set(providerName, 0);
    return Array.from(counts, ([name, count]) => ({ name, count })).sort(
      (a, b) => b.count - a.count,
    );
  }, [providerOptionsData, providerName]);

  const providerTotal = providerOptions.reduce((sum, p) => sum + p.count, 0);
  // 触发器：「供应商 / 模型」，哪一级选了就换成选中的名字
  const providerText = providerName
    ? getUsageProviderLabel(providerName, t).label
    : t("usage.providerFilter.label");
  const scopeLabel = `${providerText} / ${model ?? t("usage.modelFilter.label")}`;
  const scopeTitle = `${
    providerName
      ? usageProviderTitle(getUsageProviderLabel(providerName, t))
      : t("usage.providerFilter.all")
  } / ${model ?? t("usage.allModels")}`;

  // ── 页头右侧：刷新间隔 + 趋势图样式 + 官方额度徽标 ─────────────────────
  const ChartTypeIcon = chartType === "area" ? ChartArea : ChartColumn;
  const headerActions = (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button
            type="button"
            variant="quiet"
            size="regular"
            className="shrink-0 gap-1.5 pe-2 ps-2.5 text-fg-2"
            title="Refresh interval"
            aria-label={`Refresh interval: ${refreshLabel(refreshIntervalMs)}`}
          >
            <RefreshCw className="h-3.5 w-3.5" />
            {refreshLabel(refreshIntervalMs)}
            <ChevronDown className="h-3.5 w-3.5" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className={cn(menuContentClass, "min-w-[150px]")}>
          {REFRESH_INTERVAL_OPTIONS_MS.map((ms) => (
            <DropdownMenuItem
              key={ms}
              className={menuItemClass}
              onSelect={() => changeRefreshInterval(ms)}
            >
              <MenuCheck checked={refreshIntervalMs === ms} />
              {ms > 0 ? `Every ${ms / 1000}s` : "Off"}
            </DropdownMenuItem>
          ))}
        </DropdownMenuContent>
      </DropdownMenu>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button
            type="button"
            variant="quiet"
            size="regular"
            className="shrink-0 gap-1.5 pe-2 ps-2.5 text-fg-2"
            title={t("usage.display.trendChartType")}
            aria-label={`${t("usage.display.trendChartType")}: ${t(`usage.display.trendChartTypes.${chartType}`)}`}
          >
            <ChartTypeIcon className="h-3.5 w-3.5" />
            {t(`usage.display.trendChartTypes.${chartType}`)}
            <ChevronDown className="h-3.5 w-3.5" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className={cn(menuContentClass, "min-w-[150px]")}>
          {TREND_CHART_TYPES.map((type) => (
            <DropdownMenuItem
              key={type}
              className={menuItemClass}
              onSelect={() => {
                if (type !== chartType) void saveUsageDisplay({ ...usageDisplay, trendChartType: type });
              }}
            >
              <MenuCheck checked={chartType === type} />
              {t(`usage.display.trendChartTypes.${type}`)}
            </DropdownMenuItem>
          ))}
        </DropdownMenuContent>
      </DropdownMenu>
      <QuotaBadges pollMs={refreshIntervalMs} />
    </>
  );

  // ── 范围栏（照 v4.0.20）：时间排第一，图表和指标都跟着它 ─────────────────
  // 只列 cc-switch「应用」页设为显示的应用；Claude Code 的用量在 Claude Desktop 显示时也算，
  // DeepSeek Harness（Web 与 Desktop 的会话用量合并记在 dsh 下）在 Desktop 显示时也算，
  // 当前选中的即使被隐藏也留着，免得筛选状态无处可见
  const filterApps = useMemo(() => {
    const visible = { ...DEFAULT_VISIBLE_APPS, ...settings?.visibleApps };
    return KNOWN_APP_TYPES.filter(
      (app) =>
        visible[app] || (app === "claude" && visible["claude-desktop"]) || app === appType,
    );
  }, [settings?.visibleApps, appType]);
  const appFilterIndicator = useSlidingIndicator<HTMLDivElement>('[aria-pressed="true"]', appType);
  const chipClass = (pressed: boolean) =>
    cn(
      "relative inline-flex h-[26px] shrink-0 items-center gap-1.5 whitespace-nowrap rounded-[5px] px-2 text-body transition-colors duration-150",
      pressed ? "font-semibold text-fg-1" : "font-medium text-fg-2 hover:text-fg-1",
    );

  const filterRow = (
    <div className="flex min-h-12 shrink-0 flex-wrap items-center gap-2 px-6 py-2">
      <UsageDateRangePicker selection={range} triggerLabel={rangeLabel} onApply={applyRange} />
      <span aria-hidden="true" className="mx-1 h-4 w-px bg-border" />
      <div
        ref={appFilterIndicator.ref}
        role="group"
        aria-label={t("usage.appFilter.label")}
        className="relative flex h-8 shrink-0 items-center gap-0.5 rounded-[8px] border border-border-strong bg-surface p-[2px]"
      >
        <SegmentThumb
          rect={appFilterIndicator.rect}
          animate={appFilterIndicator.animate}
          // 和旁边的按钮同一套（卡片底 + 描边），选中项是按钮里凹下去的一块（同上游）
          className="rounded-[5px] bg-subtle shadow-none"
        />
        <button
          type="button"
          aria-pressed={appType === "all"}
          className={chipClass(appType === "all")}
          onClick={() => changeAppType("all")}
        >
          {t("usage.appFilter.all")}
        </button>
        {/* 应用只露图标，名字放悬停提示和 aria-label */}
        {filterApps.map((app) => (
          <HoverTip key={app} content={APP_DISPLAY_NAME[app]}>
            <button
              type="button"
              aria-pressed={appType === app}
              aria-label={APP_DISPLAY_NAME[app]}
              className={cn(chipClass(appType === app), "w-[30px] justify-center px-0")}
              onClick={() => changeAppType(app)}
            >
              <AppGlyph
                app={app}
                size={16}
                badgeClassName={appType === app ? "bg-subtle" : "bg-surface"}
              />
            </button>
          </HoverTip>
        ))}
      </div>
      {/* 供应商 / 模型是上下级：级联菜单，悬停供应商展开它名下的模型；点供应商本身＝只按供应商筛（全部模型） */}
      <DropdownMenu open={scopeMenuOpen} onOpenChange={setScopeMenuOpen}>
        <DropdownMenuTrigger asChild>
          <Button
            type="button"
            variant="neutral"
            size="regular"
            className="min-w-0 max-w-[260px] shrink gap-1.5 pe-2 ps-2.5"
            title={scopeTitle}
          >
            <ListTree aria-hidden="true" className="h-4 w-4 shrink-0 text-fg-3" />
            <span className="min-w-0 truncate">{scopeLabel}</span>
            <ChevronDown className="h-3.5 w-3.5 shrink-0 text-fg-2" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent
          align="start"
          aria-label={t("usage.providerFilter.title")}
          className={cn(menuContentClass, "max-h-[360px] overflow-y-auto")}
        >
          {[{ name: undefined, count: providerTotal }, ...providerOptions].map((option) => {
            const label = option.name == null ? null : getUsageProviderLabel(option.name, t);
            const active = providerName === option.name;
            return (
              <DropdownMenuSub key={option.name ?? ""}>
                <DropdownMenuSubTrigger
                  className={menuItemClass}
                  title={label ? usageProviderTitle(label) : undefined}
                  onClick={() => pickScope(option.name, undefined)}
                >
                  <MenuCheck checked={active} />
                  <span className="min-w-0 truncate">
                    {label ? label.label : t("usage.providerFilter.all")}
                  </span>
                  <MenuMeta>{fmtInt(option.count, locale)}</MenuMeta>
                  <ChevronRight aria-hidden="true" className="-me-0.5 h-3.5 w-3.5 shrink-0 text-fg-3" />
                </DropdownMenuSubTrigger>
                <DropdownMenuPortal>
                  <DropdownMenuSubContent
                    // 子菜单默认顶边对齐触发项；减去自身 1px 边框 + 4px 内边距，第一项才和触发项同一行
                    alignOffset={-5}
                    aria-label={t("usage.modelFilter.title")}
                    className={cn(menuContentClass, "max-h-[360px] overflow-y-auto")}
                  >
                    <ScopeModelItems
                      range={range}
                      appType={appType}
                      providerName={option.name}
                      providerCount={option.count}
                      active={active}
                      selectedModel={active ? model : undefined}
                      locale={locale}
                      onPick={(next) => pickScope(option.name, next)}
                    />
                  </DropdownMenuSubContent>
                </DropdownMenuPortal>
              </DropdownMenuSub>
            );
          })}
        </DropdownMenuContent>
      </DropdownMenu>
    </div>
  );

  // ── 明细面板（照 v4.0.20，去掉定价）──────────────────────────────────
  const scopedAppType = appType === "all" ? undefined : appType;

  // 页签上的计数：和各表格同样的查询参数，react-query 会合并成一次请求。三个页签都查，换筛选时
  // 沿用上一份数据直到新数到达，页签栏不会抖（同上游 28a2ebc0）
  const logCount = useRequestLogs({
    filters: { appType: scopedAppType, providerName, model, statusCode },
    range,
    page: 0,
    pageSize: logPageSize,
    options: refetch,
  });
  const providerCount = useProviderStats(range, { appType, providerName, model }, refetch);
  const modelCount = useModelStats(range, { appType, providerName, model }, refetch);
  const tabCount: Record<UsageTab, number | undefined> = {
    logs: logCount.data?.total,
    providers: providerCount.data?.length,
    models: modelCount.data?.length,
  };
  const tabLabel: Record<UsageTab, string> = {
    logs: t("usage.requestLogs"),
    providers: t("usage.tabs.providers"),
    models: t("usage.tabs.models"),
  };
  const statusLabel =
    statusCode == null ? t("usage.statusFilter.all") : `${t("usage.statusCode")} ${statusCode}`;

  // 工具栏两类入口：左边「筛选」（漏斗图标 + 当前条件，生效时实心底）改的是看哪些行；
  // 竖线右边「显示的列」改的是表怎么显示，是存下来的偏好
  const tabTrailing =
    tab === "logs" ? (
      <div className="flex items-center gap-2">
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button
              type="button"
              variant="quiet"
              size="compact"
              className={cn(
                "gap-1.5 pe-1.5 ps-2 text-caption",
                statusCode == null ? "text-fg-2" : "bg-subtle font-medium text-fg-1",
              )}
              aria-label={`${t("usage.statusCode")}: ${statusLabel}`}
            >
              <ListFilter aria-hidden="true" className="h-3.5 w-3.5" />
              {statusCode == null
                ? t("usage.statusCode")
                : `${t("usage.statusCode")} · ${statusCode}`}
              <ChevronDown aria-hidden="true" className="h-3.5 w-3.5" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" className={cn(menuContentClass, "min-w-[160px]")}>
            <DropdownMenuItem className={menuItemClass} onSelect={() => setStatusCode(undefined)}>
              <MenuCheck checked={statusCode == null} />
              {t("usage.statusFilter.all")}
            </DropdownMenuItem>
            {STATUS_CODE_OPTIONS.map((code) => (
              <DropdownMenuItem key={code} className={menuItemClass} onSelect={() => setStatusCode(code)}>
                <MenuCheck checked={statusCode === code} />
                <span className="tabular-nums">{code}</span>
              </DropdownMenuItem>
            ))}
          </DropdownMenuContent>
        </DropdownMenu>
        <span aria-hidden="true" className="h-4 w-px bg-border" />
        <RequestLogColumnsMenu value={usageDisplay} onChange={saveUsageDisplay} />
      </div>
    ) : null;

  const detailPanel = (
    <section
      aria-label={t("usage.tabs.label")}
      className="flex shrink-0 flex-col overflow-hidden rounded-panel border border-border bg-surface"
    >
      <PageTabs<UsageTab>
        aria-label={t("usage.tabs.label")}
        className="h-11 pe-2 ps-4"
        items={TABS.map((id) => ({
          value: id,
          label: (
            <span className="inline-flex items-center gap-1.5">
              {tabLabel[id]}
              {tabCount[id] != null && (
                <span className="rounded-[4px] bg-subtle px-1.5 text-caption font-medium tabular-nums text-fg-3">
                  {fmtInt(tabCount[id], locale)}
                </span>
              )}
            </span>
          ),
        }))}
        value={tab}
        onValueChange={setTab}
        idPrefix="usage-tab"
        controls="usage-tabpanel"
        trailing={tabTrailing}
      />
      <div role="tabpanel" id="usage-tabpanel" aria-labelledby={`usage-tab-${tab}`}>
        {tab === "logs" && (
          <RequestLogTable
            range={range}
            appType={appType}
            providerName={providerName}
            model={model}
            statusCode={statusCode}
            refreshIntervalMs={0}
            onOpenDetail={setDetailRequestId}
            columns={logColumns}
            pageSize={logPageSize}
            pageSizeOptions={LOG_PAGE_SIZE_OPTIONS}
            onPageSizeChange={(size) => setLogPageSizeChoice(String(size) as LogPageSize)}
          />
        )}
        {tab === "providers" && (
          <ProviderStatsTable
            range={range}
            appType={appType}
            providerName={providerName}
            model={model}
            refreshIntervalMs={0}
          />
        )}
        {tab === "models" && (
          <ModelStatsTable
            range={range}
            appType={appType}
            providerName={providerName}
            model={model}
            refreshIntervalMs={0}
          />
        )}
      </div>
    </section>
  );

  // 概览面板：指标条和图表是同一块面，点指标换图表画的指标。热力图常驻（用户选定）：短范围时在
  // 趋势图下方；「全部」范围下趋势图和热力图重复，只留热力图（同上游）
  const overviewPanel = (
    <section className="shrink-0 overflow-hidden rounded-panel border border-border bg-surface">
      <UsageHero
        range={range}
        appType={scopedAppType}
        providerName={providerName}
        model={model}
        refreshIntervalMs={0}
        compact={compact}
        metric={metric}
        onMetricChange={setMetric}
      />
      {range.preset !== "all" && (
        <UsageTrendChart
          range={range}
          metric={metric}
          appType={appType}
          providerName={providerName}
          model={model}
          refreshIntervalMs={0}
        />
      )}
      <div className={cn(range.preset !== "all" && "border-t border-border")}>
        <UsageHeatmap
          metric={metric}
          appType={appType}
          providerName={providerName}
          model={model}
          refreshIntervalMs={0}
        />
      </div>
    </section>
  );

  return (
    <div ref={containerRef} className="flex h-screen min-h-0 min-w-0 flex-col">
      {/* 顶部 46pt 留白：原生拖动条和红绿灯在这里，网页控件放进来点不到 */}
      <div aria-hidden="true" className="h-[46px] shrink-0" />
      <AppPageHeader
        icon={<ChartColumn className="h-5 w-5" strokeWidth={1.5} />}
        title={t("nav.usage")}
        titleExtra={<HelpTip title={t("nav.usage")}>{t("usage.subtitle")}</HelpTip>}
        actions={headerActions}
      />
      {filterRow}
      {/* relative：让内容区成为绝对定位元素的参照。表格里的 sr-only 文字是 position:absolute，
          没有带定位的祖先时会以整页为参照，逃出这里的滚动裁剪、把整个文档撑高，出现第二层滚动条 */}
      <div
        id="main-content"
        className="relative flex min-h-0 flex-1 flex-col gap-8 overflow-y-auto scroll-stable px-6 pb-6 pt-1"
      >
        {overviewPanel}
        {detailPanel}
      </div>
      <RequestDetailPanel requestId={detailRequestId} onClose={() => setDetailRequestId(null)} />
    </div>
  );
}

/* ────────────────────────── bootstrap ────────────────────────── */

// 固定深色主题 + 英文文案；macOS 专属样式（v4 main.tsx 同样在 body 上挂 is-mac）。
document.documentElement.classList.add("dark");
document.body.classList.add("is-mac");
try {
  window.localStorage.setItem("language", "en");
} catch {
  /* localStorage 不可用时忽略 */
}
void i18n.changeLanguage("en");

// 先从原生灌回记住的选择（最多等 400ms），再渲染：上游的 readRememberedChoice 是同步读 localStorage。
void hydrateRememberedChoices(400).then(() => {
  ReactDOM.createRoot(document.getElementById("root")!).render(
    <React.StrictMode>
      <QueryClientProvider client={queryClient}>
        <ThemeProvider defaultTheme="dark" storageKey="cc-usage-embed-theme">
          <MotionConfig reducedMotion="user">
            <TooltipProvider delayDuration={0} skipDelayDuration={0}>
              <EmbedUsagePanel />
            </TooltipProvider>
          </MotionConfig>
          <Toaster />
        </ThemeProvider>
      </QueryClientProvider>
    </React.StrictMode>,
  );
});
