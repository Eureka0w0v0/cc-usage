import Foundation
import SQLite3

// 内置模型定价表——cc-switch 的 `model_pricing` 兜底。
//
// 为什么需要：cc-switch 的定价来自它自己的内置 seed，新模型发布到上游 seed 跟进
// 之间有空窗期（例如 Claude Opus 5 发布后，上游 v3.18.0 仍未收录）。空窗期内
// cc-switch 入库时查不到价 → total_cost_usd 写 0 → 面板显示「未定价」，且该值是
// 入库时写死的，后续即使上游补了 seed 也要等它自己回填才会变。
//
// 本表让 CC Usage 不必干等上游：db 的 model_pricing 查不到时回落到这里，聚合成本
// 里 total_cost_usd <= 0 的行也按本表现场补算（只读，绝不写 cc-switch 的库）。
// db 里已有的定价**始终优先**——用户在 cc-switch 里改过的价永远不会被本表覆盖。
//
// 数据来源：cc-switch `seed_model_pricing`（src-tauri/src/database/schema.rs），
// 单位为每百万 token 的美元价。上游新增/调价后，重跑 scripts/sync-pricing.sh 同步。
public enum ModelPricing {

    public struct Row: Sendable {
        public let input: Double
        public let output: Double
        public let cacheRead: Double
        public let cacheCreation: Double
    }

    /// 表字面量用的简写构造（顺序：输入 / 输出 / 缓存读 / 缓存写）。
    private static func R(_ i: Double, _ o: Double, _ cr: Double, _ cw: Double) -> Row {
        Row(input: i, output: o, cacheRead: cr, cacheCreation: cw)
    }

    /// 对齐 cc-switch seed_model_pricing 的 178 条内置定价。
    public static let table: [String: Row] = [
        "claude-fable-5": R(10, 50, 1, 12.5),  // Claude Fable 5
        "claude-mythos-5": R(10, 50, 1, 12.5),  // Claude Mythos 5
        "claude-opus-5": R(5, 25, 0.5, 6.25),  // Claude Opus 5
        "claude-opus-4-8": R(5, 25, 0.5, 6.25),  // Claude Opus 4.8
        "claude-sonnet-5": R(3, 15, 0.3, 3.75),  // Claude Sonnet 5
        "claude-opus-4-7": R(5, 25, 0.5, 6.25),  // Claude Opus 4.7
        "claude-opus-4-6-20260206": R(5, 25, 0.5, 6.25),  // Claude Opus 4.6
        "claude-sonnet-4-6-20260217": R(3, 15, 0.3, 3.75),  // Claude Sonnet 4.6
        "claude-opus-4-5-20251101": R(5, 25, 0.5, 6.25),  // Claude Opus 4.5
        "claude-sonnet-4-5-20250929": R(3, 15, 0.3, 3.75),  // Claude Sonnet 4.5
        "claude-haiku-4-5-20251001": R(1, 5, 0.1, 1.25),  // Claude Haiku 4.5
        "claude-opus-4-20250514": R(15, 75, 1.5, 18.75),  // Claude Opus 4
        "claude-opus-4-1-20250805": R(15, 75, 1.5, 18.75),  // Claude Opus 4.1
        "claude-sonnet-4-20250514": R(3, 15, 0.3, 3.75),  // Claude Sonnet 4
        "claude-3-5-haiku-20241022": R(0.8, 4, 0.08, 1),  // Claude 3.5 Haiku
        "claude-3-5-sonnet-20241022": R(3, 15, 0.3, 3.75),  // Claude 3.5 Sonnet
        "gpt-5.6-sol": R(5, 30, 0.5, 6.25),  // GPT-5.6 Sol
        "gpt-5.6-terra": R(2.5, 15, 0.25, 3.125),  // GPT-5.6 Terra
        "gpt-5.6-luna": R(1, 6, 0.1, 1.25),  // GPT-5.6 Luna
        "gpt-5.6": R(5, 30, 0.5, 6.25),  // GPT-5.6 Sol
        "gpt-5.6-low": R(5, 30, 0.5, 6.25),  // GPT-5.6 Sol
        "gpt-5.6-medium": R(5, 30, 0.5, 6.25),  // GPT-5.6 Sol
        "gpt-5.6-high": R(5, 30, 0.5, 6.25),  // GPT-5.6 Sol
        "gpt-5.6-xhigh": R(5, 30, 0.5, 6.25),  // GPT-5.6 Sol
        "gpt-5.6-minimal": R(5, 30, 0.5, 6.25),  // GPT-5.6 Sol
        "gpt-5.5": R(5, 30, 0.5, 0),  // GPT-5.5
        "gpt-5.5-low": R(5, 30, 0.5, 0),  // GPT-5.5
        "gpt-5.5-medium": R(5, 30, 0.5, 0),  // GPT-5.5
        "gpt-5.5-high": R(5, 30, 0.5, 0),  // GPT-5.5
        "gpt-5.5-xhigh": R(5, 30, 0.5, 0),  // GPT-5.5
        "gpt-5.5-minimal": R(5, 30, 0.5, 0),  // GPT-5.5
        "gpt-5.4": R(2.5, 15, 0.25, 0),  // GPT-5.4
        "gpt-5.4-mini": R(0.75, 4.5, 0.075, 0),  // GPT-5.4 Mini
        "gpt-5.4-nano": R(0.2, 1.25, 0.02, 0),  // GPT-5.4 Nano
        "gpt-5.2": R(1.75, 14, 0.175, 0),  // GPT-5.2
        "gpt-5.2-low": R(1.75, 14, 0.175, 0),  // GPT-5.2
        "gpt-5.2-medium": R(1.75, 14, 0.175, 0),  // GPT-5.2
        "gpt-5.2-high": R(1.75, 14, 0.175, 0),  // GPT-5.2
        "gpt-5.2-xhigh": R(1.75, 14, 0.175, 0),  // GPT-5.2
        "gpt-5.2-codex": R(1.75, 14, 0.175, 0),  // GPT-5.2 Codex
        "gpt-5.2-codex-low": R(1.75, 14, 0.175, 0),  // GPT-5.2 Codex
        "gpt-5.2-codex-medium": R(1.75, 14, 0.175, 0),  // GPT-5.2 Codex
        "gpt-5.2-codex-high": R(1.75, 14, 0.175, 0),  // GPT-5.2 Codex
        "gpt-5.2-codex-xhigh": R(1.75, 14, 0.175, 0),  // GPT-5.2 Codex
        "gpt-5.3-codex": R(1.75, 14, 0.175, 0),  // GPT-5.3 Codex
        "gpt-5.3-codex-low": R(1.75, 14, 0.175, 0),  // GPT-5.3 Codex
        "gpt-5.3-codex-medium": R(1.75, 14, 0.175, 0),  // GPT-5.3 Codex
        "gpt-5.3-codex-high": R(1.75, 14, 0.175, 0),  // GPT-5.3 Codex
        "gpt-5.3-codex-xhigh": R(1.75, 14, 0.175, 0),  // GPT-5.3 Codex
        "gpt-5.1": R(1.25, 10, 0.125, 0),  // GPT-5.1
        "gpt-5.1-low": R(1.25, 10, 0.125, 0),  // GPT-5.1
        "gpt-5.1-medium": R(1.25, 10, 0.125, 0),  // GPT-5.1
        "gpt-5.1-high": R(1.25, 10, 0.125, 0),  // GPT-5.1
        "gpt-5.1-minimal": R(1.25, 10, 0.125, 0),  // GPT-5.1
        "gpt-5.1-codex": R(1.25, 10, 0.125, 0),  // GPT-5.1 Codex
        "gpt-5.1-codex-mini": R(1.25, 10, 0.125, 0),  // GPT-5.1 Codex
        "gpt-5.1-codex-max": R(1.25, 10, 0.125, 0),  // GPT-5.1 Codex
        "gpt-5.1-codex-max-high": R(1.25, 10, 0.125, 0),  // GPT-5.1 Codex
        "gpt-5.1-codex-max-xhigh": R(1.25, 10, 0.125, 0),  // GPT-5.1 Codex
        "gpt-5": R(1.25, 10, 0.125, 0),  // GPT-5
        "gpt-5-low": R(1.25, 10, 0.125, 0),  // GPT-5
        "gpt-5-medium": R(1.25, 10, 0.125, 0),  // GPT-5
        "gpt-5-high": R(1.25, 10, 0.125, 0),  // GPT-5
        "gpt-5-minimal": R(1.25, 10, 0.125, 0),  // GPT-5
        "gpt-5-codex": R(1.25, 10, 0.125, 0),  // GPT-5 Codex
        "gpt-5-codex-low": R(1.25, 10, 0.125, 0),  // GPT-5 Codex
        "gpt-5-codex-medium": R(1.25, 10, 0.125, 0),  // GPT-5 Codex
        "gpt-5-codex-high": R(1.25, 10, 0.125, 0),  // GPT-5 Codex
        "gpt-5-codex-mini": R(1.25, 10, 0.125, 0),  // GPT-5 Codex
        "gpt-5-codex-mini-medium": R(1.25, 10, 0.125, 0),  // GPT-5 Codex
        "gpt-5-codex-mini-high": R(1.25, 10, 0.125, 0),  // GPT-5 Codex
        "o3": R(2, 8, 0.5, 0),  // OpenAI o3
        "o4-mini": R(1.1, 4.4, 0.275, 0),  // OpenAI o4-mini
        "gpt-4.1": R(2, 8, 0.5, 0),  // GPT-4.1
        "gpt-4.1-mini": R(0.4, 1.6, 0.1, 0),  // GPT-4.1 Mini
        "gpt-4.1-nano": R(0.1, 0.4, 0.025, 0),  // GPT-4.1 Nano
        "gemini-3.6-flash": R(1.5, 7.5, 0.15, 0),  // Gemini 3.6 Flash
        "gemini-3.5-flash": R(1.5, 9, 0.15, 0),  // Gemini 3.5 Flash
        "gemini-3.1-pro-preview": R(2, 12, 0.2, 0),  // Gemini 3.1 Pro Preview
        "gemini-3.1-flash-lite": R(0.25, 1.5, 0.025, 0),  // Gemini 3.1 Flash Lite
        "gemini-3.1-flash-lite-preview": R(0.25, 1.5, 0.025, 0),  // Gemini 3.1 Flash Lite Preview
        "gemini-3-pro-preview": R(2, 12, 0.2, 0),  // Gemini 3 Pro Preview
        "gemini-3-flash-preview": R(0.5, 3, 0.05, 0),  // Gemini 3 Flash Preview
        "gemini-2.5-pro": R(1.25, 10, 0.125, 0),  // Gemini 2.5 Pro
        "gemini-2.5-flash": R(0.3, 2.5, 0.03, 0),  // Gemini 2.5 Flash
        "gemini-2.5-flash-lite": R(0.1, 0.4, 0.01, 0),  // Gemini 2.5 Flash Lite
        "gemini-2.0-flash": R(0.1, 0.4, 0.025, 0),  // Gemini 2.0 Flash
        "step-3.7-flash": R(0.19, 1.13, 0.04, 0),  // Step 3.7 Flash
        "step-3.5-flash": R(0.1, 0.3, 0.02, 0),  // Step 3.5 Flash
        "step-3.5-flash-2603": R(0.1, 0.3, 0.02, 0),  // Step 3.5 Flash 2603
        "doubao-seed-2-1-pro": R(0.84, 4.2, 0.17, 0),  // Doubao Seed 2.1 Pro
        "doubao-seed-2-1-turbo": R(0.42, 2.1, 0.08, 0),  // Doubao Seed 2.1 Turbo
        "doubao-seed-code": R(0.17, 1.11, 0.02, 0),  // Doubao Seed Code
        "doubao-seed-2-0-pro": R(0.47, 2.37, 0.09, 0),  // Doubao Seed 2.0 Pro
        "doubao-seed-2-0-code": R(0.47, 2.37, 0.09, 0),  // Doubao Seed 2.0 Code
        "doubao-seed-2-0-code-preview-latest": R(0.47, 2.37, 0.09, 0),  // Doubao Seed 2.0 Code Preview
        "doubao-seed-2-0-lite": R(0.08, 0.5, 0.017, 0),  // Doubao Seed 2.0 Lite
        "doubao-seed-2-0-mini": R(0.03, 0.31, 0.0056, 0),  // Doubao Seed 2.0 Mini
        "deepseek-v3.2": R(0.28, 0.42, 0.028, 0),  // DeepSeek V3.2
        "deepseek-v3.1": R(0.55, 1.67, 0.055, 0),  // DeepSeek V3.1
        "deepseek-v3": R(0.28, 1.11, 0.028, 0),  // DeepSeek V3
        "deepseek-chat": R(0.27, 1.1, 0.07, 0),  // DeepSeek Chat
        "deepseek-reasoner": R(0.55, 2.19, 0.14, 0),  // DeepSeek Reasoner
        "deepseek-v4-flash": R(0.14, 0.28, 0.0028, 0),  // DeepSeek V4 Flash
        "deepseek-v4-pro": R(0.435, 0.87, 0.003625, 0),  // DeepSeek V4 Pro
        "kimi-k2-thinking": R(0.55, 2.2, 0.1, 0),  // Kimi K2 Thinking
        "kimi-k2-0905": R(0.55, 2.2, 0.1, 0),  // Kimi K2
        "kimi-k2-turbo": R(1.11, 8.06, 0.14, 0),  // Kimi K2 Turbo
        "kimi-k2.5": R(0.6, 3, 0.1, 0),  // Kimi K2.5
        "kimi-k2.6": R(0.95, 4, 0.16, 0),  // Kimi K2.6
        "kimi-k2.7-code": R(0.95, 4, 0.19, 0),  // Kimi K2.7 Code
        "kimi-k3": R(3, 15, 0.3, 0),  // Kimi K3
        "k3": R(3, 15, 0.3, 0),  // Kimi K3
        "hunyuan-hy3": R(0.14, 0.56, 0.035, 0),  // Hunyuan Hy3
        "hy3": R(0.14, 0.56, 0.035, 0),  // Hunyuan Hy3
        "minimax-m2.1": R(0.27, 0.95, 0.03, 0),  // MiniMax M2.1
        "minimax-m2.1-lightning": R(0.27, 2.33, 0.03, 0),  // MiniMax M2.1 Lightning
        "minimax-m2": R(0.27, 0.95, 0.03, 0),  // MiniMax M2
        "minimax-m2.5": R(0.15, 0.95, 0.03, 0),  // MiniMax M2.5
        "minimax-m2.5-lightning": R(0.3, 2.4, 0.03, 0),  // MiniMax M2.5 Lightning
        "minimax-m2.7": R(0.3, 1.2, 0.06, 0.375),  // MiniMax M2.7
        "minimax-m2.7-highspeed": R(0.6, 2.4, 0.06, 0.375),  // MiniMax M2.7 Highspeed
        "minimax-m3": R(0.6, 2.4, 0.12, 0),  // MiniMax M3
        "glm-4.7": R(0.6, 2.2, 0.11, 0),  // GLM-4.7
        "glm-4.6": R(0.6, 2.2, 0.11, 0),  // GLM-4.6
        "glm-5": R(1, 3.2, 0.2, 0),  // GLM-5
        "glm-5.1": R(1.4, 4.4, 0.26, 0),  // GLM-5.1
        "glm-5.2": R(1.4, 4.4, 0.26, 0),  // GLM-5.2
        "mimo-v2-flash": R(0.09, 0.29, 0.009, 0),  // MiMo V2 Flash
        "mimo-v2-pro": R(0.435, 0.87, 0.0036, 0),  // MiMo V2 Pro
        "mimo-v2.5": R(0.14, 0.29, 0.0028, 0),  // MiMo V2.5
        "mimo-v2.5-pro": R(0.435, 0.87, 0.0036, 0),  // MiMo V2.5 Pro
        "qwen3.7-max": R(2.5, 7.5, 0.25, 0),  // Qwen3.7 Max
        "qwen3.7-plus": R(0.4, 1.6, 0.08, 0),  // Qwen3.7 Plus
        "qwen3.6-plus": R(0.325, 1.95, 0.065, 0),  // Qwen3.6 Plus
        "qwen3.5-plus": R(0.26, 1.56, 0.052, 0),  // Qwen3.5 Plus
        "qwen3-max": R(0.78, 3.9, 0, 0),  // Qwen3 Max
        "qwen3-235b-a22b": R(0.7, 8.4, 0, 0),  // Qwen3 235B-A22B
        "qwen3-coder-plus": R(0.65, 3.25, 0.13, 0),  // Qwen3 Coder Plus
        "qwen3-coder-480b": R(0.65, 3.25, 0, 0),  // Qwen3 Coder 480B
        "qwen3-coder-480b-a35b-instruct": R(0.65, 3.25, 0, 0),  // Qwen3 Coder 480B-A35B Instruct
        "qwen3-coder-flash": R(0.195, 0.975, 0.039, 0),  // Qwen3 Coder Flash
        "qwen3-coder-next": R(0.12, 0.75, 0, 0),  // Qwen3 Coder Next
        "qwq-plus": R(0.8, 2.4, 0, 0),  // QwQ Plus
        "qwq-32b": R(0.2, 0.6, 0, 0),  // QwQ 32B
        "qwen3-32b": R(0.16, 0.64, 0, 0),  // Qwen3 32B
        "grok-4.5": R(2, 6, 0.5, 0),  // Grok 4.5
        // Grok Build 的 cache read 实测 0.30（上游按 costUsdTicks 反推），非挂牌 0.50
        "grok-4.5-build": R(2, 6, 0.30, 0),  // Grok 4.5 Build
        "grok-4.3": R(1.25, 2.5, 0.2, 0),  // Grok 4.3
        "grok-4.20-0309-reasoning": R(1.25, 2.5, 0.2, 0),  // Grok 4.20 Reasoning
        "grok-4.20-0309-non-reasoning": R(1.25, 2.5, 0.2, 0),  // Grok 4.20
        "grok-4-1-fast-reasoning": R(0.2, 0.5, 0.05, 0),  // Grok 4.1 Fast Reasoning
        "grok-4-1-fast-non-reasoning": R(0.2, 0.5, 0.05, 0),  // Grok 4.1 Fast
        "grok-4": R(3, 15, 0.75, 0),  // Grok 4
        "grok-code-fast-1": R(1, 2, 0.2, 0),  // Grok Build 0.1 (Code Fast Alias)
        "grok-build-0.1": R(1, 2, 0.2, 0),  // Grok Build 0.1
        "grok-3": R(3, 15, 0.75, 0),  // Grok 3
        "grok-3-mini": R(0.25, 0.5, 0.075, 0),  // Grok 3 Mini
        "mistral-medium-3.5": R(1.5, 7.5, 0, 0),  // Mistral Medium 3.5
        "mistral-small-4": R(0.1, 0.3, 0.01, 0),  // Mistral Small 4
        "devstral-small-2-2512": R(0.1, 0.3, 0.01, 0),  // Devstral Small 2
        "magistral-small": R(0.5, 1.5, 0, 0),  // Magistral Small
        "codestral-2508": R(0.3, 0.9, 0.03, 0),  // Codestral
        "devstral-small-1.1": R(0.07, 0.28, 0.01, 0),  // Devstral Small 1.1
        "devstral-2-2512": R(0.4, 2, 0.04, 0),  // Devstral 2
        "devstral-medium": R(0.4, 2, 0.04, 0),  // Devstral Medium
        "mistral-large-3-2512": R(0.5, 1.5, 0.05, 0),  // Mistral Large 3
        "mistral-medium-3.1": R(0.4, 2, 0.04, 0),  // Mistral Medium 3.1
        "mistral-small-3.2-24b": R(0.075, 0.2, 0.01, 0),  // Mistral Small 3.2
        "magistral-medium": R(2, 5, 0, 0),  // Magistral Medium
        "command-a": R(2.5, 10, 0, 0),  // Cohere Command A
        "command-r-plus": R(2.5, 10, 0, 0),  // Cohere Command R+
        "command-r": R(0.15, 0.6, 0, 0),  // Cohere Command R
        "o3-pro": R(20, 80, 0, 0),  // OpenAI o3-pro
        "o3-mini": R(0.55, 2.2, 0.55, 0),  // OpenAI o3-mini
        "o1": R(15, 60, 7.5, 0),  // OpenAI o1
        "o1-mini": R(0.55, 2.2, 0.55, 0),  // OpenAI o1-mini
        "codex-mini": R(0.75, 3, 0.025, 0),  // Codex Mini
        "gpt-5-mini": R(0.25, 2, 0.025, 0),  // GPT-5 Mini
        "gpt-5-nano": R(0.05, 0.4, 0.005, 0),  // GPT-5 Nano
    ]

    /// 按 SessionOverlay 的候选归一化（命名空间/日期尾/[1m] 等）查内置表。
    public static func lookup(_ modelId: String) -> Row? {
        for candidate in SessionOverlay.pricingCandidates(modelId) {
            if let row = table[candidate] { return row }
        }
        // 前缀兜底：与 find_model_pricing_row 同门槛，取最短命中。
        for candidate in SessionOverlay.pricingCandidates(modelId)
        where SessionOverlay.shouldTryPrefixMatch(candidate) {
            if let hit = prefixIds.first(where: { $0.hasPrefix(candidate + "-") }) {
                return table[hit]
            }
        }
        return nil
    }

    /// 前缀匹配用（短 id 优先，对齐 LENGTH ASC）。
    private static let prefixIds: [String] = table.keys.sorted { $0.count < $1.count }

    /// 在连接上建 TEMP 兜底定价表，供聚合 SQL 现场补算未定价行。
    /// 只读连接同样可建 temp 表（temp 库独立于主库）；建表失败不致命——
    /// 调用方的 SQL 用 LEFT JOIN，表缺失时回退成「未定价按 0 计」的旧行为。
    @discardableResult
    public static func installFallbackTable(_ db: OpaquePointer) -> Bool {
        let ddl = """
        CREATE TEMP TABLE IF NOT EXISTS \(fallbackTable) (
            model_id TEXT PRIMARY KEY, inp REAL NOT NULL, outp REAL NOT NULL,
            cr REAL NOT NULL, cw REAL NOT NULL
        )
        """
        guard sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK else { return false }

        // 已灌过就跳过（同一连接内复用）。
        var countStmt: OpaquePointer?
        var alreadyFilled = false
        if sqlite3_prepare_v2(db, "SELECT 1 FROM \(fallbackTable) LIMIT 1", -1, &countStmt, nil) == SQLITE_OK {
            alreadyFilled = sqlite3_step(countStmt) == SQLITE_ROW
        }
        sqlite3_finalize(countStmt)
        if alreadyFilled { return true }

        let sql = "INSERT OR IGNORE INTO \(fallbackTable) VALUES (?,?,?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for (id, row) in table {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT_DEST)
            sqlite3_bind_double(stmt, 2, row.input)
            sqlite3_bind_double(stmt, 3, row.output)
            sqlite3_bind_double(stmt, 4, row.cacheRead)
            sqlite3_bind_double(stmt, 5, row.cacheCreation)
            _ = sqlite3_step(stmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        return true
    }

    public static let fallbackTable = "ccu_fallback_pricing"

    /// 归一化 model 列的 SQL 表达式：小写 + 去 [1m] 上下文标记 + 去首尾空白。
    /// 覆盖 Claude 会话日志的主流形态；更复杂的别名由 db 侧 model_pricing 命中。
    public static func normalizedModelSQL(_ effectiveModel: String) -> String {
        "TRIM(REPLACE(LOWER(\(effectiveModel)), '[1m]', ''))"
    }

    /// 成本表达式：db 已有正成本优先，未定价行按内置表现场补算（含倍率）。
    /// alias 为表别名；multiplier 传倍率列（rollups 表无该列，传 "1.0"）。
    /// 补算口径逐条对齐 cc-switch `maybe_backfill_log_costs`：各维度 token × 单价
    /// ÷ 1e6 得基础成本，倍率只作用于最终总价。
    public static func costSQL(alias a: String, effectiveModel: String,
                               multiplier: String) -> String {
        """
        CASE WHEN CAST(\(a).total_cost_usd AS REAL) > 0
             THEN CAST(\(a).total_cost_usd AS REAL)
             ELSE COALESCE((
                 SELECT (\(a).input_tokens * f.inp + \(a).output_tokens * f.outp
                       + \(a).cache_read_tokens * f.cr + \(a).cache_creation_tokens * f.cw) / 1000000.0
                       * \(multiplier)
                 FROM \(fallbackTable) f
                 WHERE f.model_id = \(normalizedModelSQL(effectiveModel))
             ), 0)
        END
        """
    }

    /// 单行补算（面板明细表用）：db 成本为 0 时按内置表算出四个分项与总价，
    /// 返回 nil 表示保持原值（已有成本，或内置表也没有该模型）。
    public static func backfilledCosts(
        model: String, multiplier: Double,
        input: Int64, output: Int64, cacheRead: Int64, cacheCreation: Int64
    ) -> (input: String, output: String, cacheRead: String, cacheCreation: String, total: String)? {
        guard let p = lookup(model) else { return nil }
        let ic = Double(input) * p.input / 1_000_000
        let oc = Double(output) * p.output / 1_000_000
        let crc = Double(cacheRead) * p.cacheRead / 1_000_000
        let ccc = Double(cacheCreation) * p.cacheCreation / 1_000_000
        let mult = multiplier == 0 ? 1.0 : multiplier
        let fmt = { (v: Double) in String(format: "%.6f", v) }
        return (fmt(ic), fmt(oc), fmt(crc), fmt(ccc), fmt((ic + oc + crc + ccc) * mult))
    }
}
