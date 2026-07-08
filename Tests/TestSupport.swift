import Foundation
import SQLite3

// 测试夹具：临时 cc-switch.db（最小 schema，列名与真库一致）+ 指向空目录的 SessionOverlay。
// 全部落在系统临时目录，与真实 ~/.cc-switch / ~/.claude/projects 完全隔离。
enum Fixture {
    static let schema = """
    CREATE TABLE proxy_request_logs(
      request_id TEXT PRIMARY KEY,
      provider_id TEXT DEFAULT '',
      app_type TEXT DEFAULT 'claude',
      model TEXT DEFAULT '',
      request_model TEXT,
      pricing_model TEXT,
      cost_multiplier TEXT DEFAULT '1',
      input_tokens INTEGER DEFAULT 0,
      output_tokens INTEGER DEFAULT 0,
      cache_read_tokens INTEGER DEFAULT 0,
      cache_creation_tokens INTEGER DEFAULT 0,
      input_cost_usd TEXT DEFAULT '0',
      output_cost_usd TEXT DEFAULT '0',
      cache_read_cost_usd TEXT DEFAULT '0',
      cache_creation_cost_usd TEXT DEFAULT '0',
      total_cost_usd TEXT DEFAULT '0',
      is_streaming INTEGER DEFAULT 0,
      latency_ms INTEGER DEFAULT 0,
      first_token_ms INTEGER,
      duration_ms INTEGER,
      status_code INTEGER DEFAULT 200,
      error_message TEXT,
      created_at INTEGER DEFAULT 0,
      data_source TEXT DEFAULT 'session_log'
    );
    CREATE TABLE usage_daily_rollups(
      date TEXT,
      app_type TEXT DEFAULT 'claude',
      model TEXT DEFAULT '',
      pricing_model TEXT,
      request_count INTEGER DEFAULT 0,
      input_tokens INTEGER DEFAULT 0,
      output_tokens INTEGER DEFAULT 0,
      cache_read_tokens INTEGER DEFAULT 0,
      cache_creation_tokens INTEGER DEFAULT 0,
      total_cost_usd TEXT DEFAULT '0'
    );
    CREATE TABLE providers(id TEXT, name TEXT, app_type TEXT);
    CREATE TABLE session_log_sync(
      file_path TEXT PRIMARY KEY,
      last_modified INTEGER DEFAULT 0,
      last_line_offset INTEGER DEFAULT 0
    );
    CREATE TABLE model_pricing(
      model_id TEXT PRIMARY KEY,
      input_cost_per_million TEXT DEFAULT '0',
      output_cost_per_million TEXT DEFAULT '0',
      cache_read_cost_per_million TEXT DEFAULT '0',
      cache_creation_cost_per_million TEXT DEFAULT '0'
    );
    """

    /// 固定时区日历：让「本地日」相关断言与跑测试的机器时区无关。
    static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    /// 固定时区下组装 epoch 秒。
    static func ts(_ y: Int, _ mo: Int, _ d: Int,
                   _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Int64 {
        var comp = DateComponents()
        comp.year = y; comp.month = mo; comp.day = d
        comp.hour = h; comp.minute = mi; comp.second = s
        return Int64(cal.date(from: comp)!.timeIntervalSince1970)
    }

    static func makeDB(_ name: String) throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ccusage-test-\(name)-\(UUID().uuidString).db")
        try exec(path, schema)
        return path
    }

    static func exec(_ path: String, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let handle = db else {
            throw NSError(domain: "fixture", code: 1)
        }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(handle))
            throw NSError(domain: "fixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    /// 明细行插入（测试关心的列，其余走 DEFAULT）。
    static func insertLog(_ path: String, id: String,
                          app: String = "claude", model: String = "claude-sonnet-5",
                          input: Int64 = 0, output: Int64 = 0,
                          cacheRead: Int64 = 0, cacheCreation: Int64 = 0,
                          cost: Double = 0, createdAt: Int64,
                          dataSource: String = "session_log",
                          status: Int = 200, providerId: String = "_session") throws {
        try exec(path, """
        INSERT INTO proxy_request_logs(request_id, provider_id, app_type, model,
          input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
          total_cost_usd, status_code, created_at, data_source)
        VALUES('\(id)','\(providerId)','\(app)','\(model)',
          \(input),\(output),\(cacheRead),\(cacheCreation),
          '\(cost)',\(status),\(createdAt),'\(dataSource)');
        """)
    }

    static func insertRollup(_ path: String, date: String,
                             app: String = "claude", model: String = "claude-sonnet-5",
                             requests: Int64 = 1, input: Int64 = 0, output: Int64 = 0,
                             cacheRead: Int64 = 0, cacheCreation: Int64 = 0,
                             cost: Double = 0) throws {
        try exec(path, """
        INSERT INTO usage_daily_rollups(date, app_type, model, request_count,
          input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, total_cost_usd)
        VALUES('\(date)','\(app)','\(model)',\(requests),
          \(input),\(output),\(cacheRead),\(cacheCreation),'\(cost)');
        """)
    }

    /// 指向空临时目录的 overlay：测试不去扫真实会话日志。
    static func emptyOverlay() throws -> SessionOverlay {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ccusage-test-projects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return SessionOverlay(projectsDir: dir)
    }

    static func store(_ dbPath: String) throws -> UsageStore {
        UsageStore(path: dbPath, overlay: try emptyOverlay())
    }
}
