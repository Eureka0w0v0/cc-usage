/**
 * Embed 入口：把 cc-switch v4.0.12 的用量页（只读精简版）跑在 CC Usage 主窗口的 WKWebView 里。
 *
 * 照 src/components/usage/UsageDashboard.tsx（v4.0.12）改写：页头 → 筛选行 → 指标 → 走势图 / 热力图 →
 * 子页签（请求日志 / 供应商 / 模型），点一条请求看详情。与上游的差异（2026-10-15 与用户逐项确认）：
 * - 只读：不要「立即同步」、「数据来源」抽屉（自动扫描开关 / 重建 Codex）、「定价」页签和空状态，
 *   它们都会写 cc-switch 的库或设置；
 * - 页头右侧换成 CC Usage 自己的刷新间隔（关 / 5 / 10 / 30 / 60 秒，默认 5 秒，存原生 UserDefaults、
 *   和菜单栏同步）和官方额度徽标；
 * - 热力图常驻在走势图下方（2026-10-10 用户选定），选「全部」时只显示热力图；
 * - 刷新：子组件都不轮询（refreshIntervalMs=0），这里按间隔统一失效重查（原生每次查询都会顺带续读
 *   会话日志叠加层），窗口不可见时暂停、回来立刻补一次；
 * - 固定深色主题 + 英文（与用户 cc-switch 的设置一致）。
 */

import "./index.css";

import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import ReactDOM from "react-dom/client";
import { invoke } from "@tauri-apps/api/core";
import { useTranslation } from "react-i18next";
import { MotionConfig } from "framer-motion";
import { ChartColumn, Check, ChevronDown, Clock, RefreshCw } from "lucide-react";
import {
  QueryClientProvider,
  focusManager,
  useQueryClient,
} from "@tanstack/react-query";

import i18n from "@/i18n";
import { queryClient } from "@/lib/query/queryClient";
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
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  KNOWN_APP_TYPES,
  type AppTypeFilter,
  type UsageRangeSelection,
} from "@/types/usage";
import { usageKeys, useModelStats, useProviderStats } from "@/lib/query/usage";
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
import { UsageDateRangePicker } from "@/components/usage/UsageDateRangePicker";
import { fmtInt, getLocaleFromLanguage } from "@/components/usage/format";
import {
  getUsageProviderLabel,
  usageProviderTitle,
} from "@/components/usage/providerLabel";

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

/* ───────── 用量页（照 v4.0.12 UsageDashboard，只读） ───────── */

const STATUS_CODE_OPTIONS = [200, 400, 401, 429, 500] as const;

type UsageTab = "logs" | "providers" | "models";
const TABS: UsageTab[] = ["logs", "providers", "models"];

/** 容器宽度（ResizeObserver）；测量不到时返回 0。 */
function useContainerWidth<T extends HTMLElement>() {
  const ref = useRef<T | null>(null);
  const [width, setWidth] = useState(0);
  useLayoutEffect(() => {
    const element = ref.current;
    if (!element) return;
    const measure = () => setWidth(element.getBoundingClientRect().width);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  return [ref, width] as const;
}

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

function EmbedUsagePanel() {
  const { t, i18n: i18nInstance } = useTranslation();
  const queryClientInstance = useQueryClient();
  const [range, setRange] = useState<UsageRangeSelection>({ preset: "today" });
  const [appType, setAppType] = useState<AppTypeFilter>("all");
  const [providerName, setProviderName] = useState<string | undefined>(undefined);
  const [model, setModel] = useState<string | undefined>(undefined);
  const [statusCode, setStatusCode] = useState<number | undefined>(undefined);
  const [tab, setTab] = useState<UsageTab>("logs");
  const [detailRequestId, setDetailRequestId] = useState<string | null>(null);
  const [refreshIntervalMs, setRefreshIntervalMs] = useState(
    loadStoredRefreshIntervalMs,
  );
  const [containerRef, measuredWidth] = useContainerWidth<HTMLDivElement>();
  // 测量不到时按宽窗口排
  const compact = (measuredWidth || 1000) < 720;

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

  // 切应用时清掉下游筛选，避免留下一个在新范围内查无数据的「幽灵」组合；切供应商同理清掉模型。
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

  const changeRefreshInterval = (next: number) => {
    setRefreshIntervalMs(next);
    try {
      window.localStorage.setItem(REFRESH_INTERVAL_STORAGE_KEY, String(next));
    } catch {
      /* ignore */
    }
    // 写穿原生：持久化到 UserDefaults，并把菜单栏刷新节奏同步成同一个值
    void invoke("set_setting", { key: "refreshIntervalMs", value: next }).catch(
      () => {},
    );
    void queryClientInstance.invalidateQueries({ queryKey: usageKeys.all });
  };

  const language =
    i18nInstance.resolvedLanguage || i18nInstance.language || "en";
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

  // 筛选下拉的选项池：供应商列表只跟应用 / 时间范围走，模型列表随所选供应商级联。都不轮询，
  // 由 useEmbedAutoRefresh 统一失效重查。
  const noPolling = { refetchInterval: false as const };
  const { data: providerOptionsData } = useProviderStats(range, { appType }, noPolling);
  const { data: modelOptionsData } = useModelStats(
    range,
    { appType, providerName },
    noPolling,
  );

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

  const modelOptions = useMemo(() => {
    const counts = new Map<string, number>();
    for (const stat of modelOptionsData ?? []) {
      counts.set(stat.model, (counts.get(stat.model) ?? 0) + stat.requestCount);
    }
    if (model && !counts.has(model)) counts.set(model, 0);
    return Array.from(counts, ([name, count]) => ({ name, count })).sort(
      (a, b) => b.count - a.count,
    );
  }, [modelOptionsData, model]);

  const providerTotal = providerOptions.reduce((sum, p) => sum + p.count, 0);
  const modelTotal = modelOptions.reduce((sum, m) => sum + m.count, 0);

  // ── 页头右侧：刷新间隔 + 官方额度徽标 ─────────────────────────────────
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
      <QuotaBadges pollMs={refreshIntervalMs} />
    </>
  );

  // ── 筛选行（照 v4）──────────────────────────────────────────────────
  const appFilterIndicator = useSlidingIndicator<HTMLDivElement>(
    '[aria-pressed="true"]',
    appType,
  );
  const chipClass = (pressed: boolean) =>
    cn(
      "relative inline-flex h-[26px] shrink-0 items-center gap-1.5 whitespace-nowrap rounded-[5px] px-2 text-body transition-colors duration-150",
      pressed ? "font-semibold text-fg-1" : "font-medium text-fg-2 hover:text-fg-1",
    );

  const filterRow = (
    <div className="flex min-h-12 shrink-0 flex-wrap items-center gap-1.5 px-6 py-2">
      <div
        ref={appFilterIndicator.ref}
        role="group"
        aria-label={t("usage.appFilter.label")}
        className="relative flex h-8 shrink-0 items-center gap-0.5 rounded-[8px] bg-subtle p-[3px]"
      >
        <SegmentThumb
          rect={appFilterIndicator.rect}
          animate={appFilterIndicator.animate}
          className="rounded-[5px]"
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
        {KNOWN_APP_TYPES.map((app) => (
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
                badgeClassName={appType === app ? "bg-surface" : "bg-subtle"}
              />
            </button>
          </HoverTip>
        ))}
      </div>
      <div className="min-w-2 flex-1" />
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button
            type="button"
            variant="neutral"
            size="regular"
            className="min-w-[78px] max-w-[156px] shrink gap-1 pe-2 ps-3"
            title={
              providerName
                ? usageProviderTitle(getUsageProviderLabel(providerName, t))
                : t("usage.providerFilter.title")
            }
          >
            <span className="min-w-0 truncate">
              {providerName
                ? getUsageProviderLabel(providerName, t).label
                : t("usage.providerFilter.label")}
            </span>
            <ChevronDown className="h-3.5 w-3.5 shrink-0 text-fg-2" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent
          align="end"
          aria-label={t("usage.providerFilter.title")}
          className={cn(menuContentClass, "max-h-[360px] overflow-y-auto")}
        >
          <DropdownMenuItem className={menuItemClass} onSelect={() => changeProviderName(undefined)}>
            <MenuCheck checked={providerName == null} />
            {t("usage.providerFilter.all")}
            <MenuMeta>{fmtInt(providerTotal, locale)}</MenuMeta>
          </DropdownMenuItem>
          {providerOptions.map((option) => {
            const label = getUsageProviderLabel(option.name, t);
            return (
              <DropdownMenuItem
                key={option.name}
                className={menuItemClass}
                title={usageProviderTitle(label)}
                onSelect={() => changeProviderName(option.name)}
              >
                <MenuCheck checked={providerName === option.name} />
                <span className="min-w-0 truncate">{label.label}</span>
                <MenuMeta>{fmtInt(option.count, locale)}</MenuMeta>
              </DropdownMenuItem>
            );
          })}
        </DropdownMenuContent>
      </DropdownMenu>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button
            type="button"
            variant="neutral"
            size="regular"
            className="min-w-[66px] max-w-[156px] shrink gap-1 pe-2 ps-3"
            title={model ?? t("usage.modelFilter.title")}
          >
            <span className="min-w-0 truncate">{model ?? t("usage.modelFilter.label")}</span>
            <ChevronDown className="h-3.5 w-3.5 shrink-0 text-fg-2" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent
          align="end"
          aria-label={t("usage.modelFilter.title")}
          className={cn(menuContentClass, "max-h-[360px] overflow-y-auto")}
        >
          <DropdownMenuItem className={menuItemClass} onSelect={() => setModel(undefined)}>
            <MenuCheck checked={model == null} />
            {t("usage.allModels")}
            <MenuMeta>{fmtInt(modelTotal, locale)}</MenuMeta>
          </DropdownMenuItem>
          {modelOptions.map((option) => (
            <DropdownMenuItem
              key={option.name}
              className={menuItemClass}
              title={option.name}
              onSelect={() => setModel(option.name)}
            >
              <MenuCheck checked={model === option.name} />
              <span className="min-w-0 truncate font-mono text-caption">{option.name}</span>
              <MenuMeta>{fmtInt(option.count, locale)}</MenuMeta>
            </DropdownMenuItem>
          ))}
        </DropdownMenuContent>
      </DropdownMenu>
      <UsageDateRangePicker
        selection={range}
        triggerLabel={rangeLabel}
        onApply={(nextRange) => setRange(nextRange)}
      />
    </div>
  );

  // ── 子页签（照 v4，去掉定价）────────────────────────────────────────
  const tabLabel: Record<UsageTab, string> = {
    logs: t("usage.requestLogs"),
    providers: t("usage.tabs.providers"),
    models: t("usage.tabs.models"),
  };
  const statusLabel =
    statusCode == null ? t("usage.statusFilter.all") : `${t("usage.statusCode")} ${statusCode}`;

  const tabTrailing =
    tab === "logs" ? (
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button
            type="button"
            variant="quiet"
            size="compact"
            className="gap-1 pe-1.5 ps-2 text-caption text-fg-2"
            aria-label={`${t("usage.statusCode")}: ${statusLabel}`}
          >
            {statusLabel}
            <ChevronDown className="h-3.5 w-3.5" />
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
    ) : (
      <span className="text-caption text-fg-3">{t("usage.sortedByRequests")}</span>
    );

  const scopedAppType = appType === "all" ? undefined : appType;

  const tabsSection = (
    <section aria-label={t("usage.tabs.label")} className="flex flex-col">
      <PageTabs<UsageTab>
        aria-label={t("usage.tabs.label")}
        items={TABS.map((id) => ({ value: id, label: tabLabel[id] }))}
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
        className="relative flex min-h-0 flex-1 flex-col gap-3.5 overflow-y-auto scroll-stable px-6 pb-6 pt-1"
      >
        <UsageHero
          range={range}
          appType={scopedAppType}
          providerName={providerName}
          model={model}
          refreshIntervalMs={0}
          compact={compact}
        />
        {/* 热力图常驻在走势图下方；「全部」范围下走势图会和热力图重复，只留热力图（同 v4） */}
        {range.preset !== "all" && (
          <UsageTrendChart
            range={range}
            rangeLabel={rangeLabel}
            appType={appType}
            providerName={providerName}
            model={model}
            refreshIntervalMs={0}
          />
        )}
        <UsageHeatmap
          appType={appType}
          providerName={providerName}
          model={model}
          refreshIntervalMs={0}
        />
        {tabsSection}
      </div>
      <RequestDetailPanel
        requestId={detailRequestId}
        onClose={() => setDetailRequestId(null)}
      />
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
