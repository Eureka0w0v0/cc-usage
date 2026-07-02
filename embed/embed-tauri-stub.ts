/**
 * Tauri 原生模块的空实现桩，供 embed 打包时替换以下模块，避免它们在模块
 * 加载期访问 Tauri 运行时（WKWebView 里没有 Tauri）：
 *   @tauri-apps/api/event  window  webviewWindow  app  path  （bare）api
 *   @tauri-apps/plugin-dialog / plugin-process / plugin-updater / plugin-store
 *
 * 精简面板实际只用到 event.listen（useUsageEventBridge）。其余导出仅为防止
 * 潜在的间接命名导入在构建期解析失败，全部为无害占位。
 */

export type UnlistenFn = () => void;
export type EventName = string;
export interface Event<T> {
  event: string;
  id: number;
  payload: T;
}
export type EventCallback<T> = (event: Event<T>) => void;

/** 事件系统：返回一个 no-op unlisten。 */
export async function listen<T = unknown>(
  _event: string,
  _handler: EventCallback<T>,
): Promise<UnlistenFn> {
  return () => {};
}

export async function once<T = unknown>(
  _event: string,
  _handler: EventCallback<T>,
): Promise<UnlistenFn> {
  return () => {};
}

export async function emit(_event: string, _payload?: unknown): Promise<void> {}
export async function emitTo(
  _target: string,
  _event: string,
  _payload?: unknown,
): Promise<void> {}

export const TauriEvent: Record<string, string> = {};

/* ── window / webviewWindow ── */
function noopWindowProxy() {
  return new Proxy(
    {},
    {
      get() {
        return () => Promise.resolve(undefined);
      },
    },
  );
}
export function getCurrentWindow() {
  return noopWindowProxy();
}
export function getCurrentWebviewWindow() {
  return noopWindowProxy();
}
export function getAllWindows() {
  return [];
}

/* ── app ── */
export async function getVersion(): Promise<string> {
  return "0.0.0-embed";
}
export async function getName(): Promise<string> {
  return "cc-usage-embed";
}
export async function getTauriVersion(): Promise<string> {
  return "0.0.0";
}

/* ── path ── */
export async function homeDir(): Promise<string> {
  return "/";
}
export async function appDataDir(): Promise<string> {
  return "/";
}
export async function join(...parts: string[]): Promise<string> {
  return parts.join("/");
}

/* ── plugin-dialog ── */
export async function message(_message: string, _options?: unknown): Promise<void> {}
export async function ask(_message: string, _options?: unknown): Promise<boolean> {
  return false;
}
export async function confirm(_message: string, _options?: unknown): Promise<boolean> {
  return false;
}
export async function open(_options?: unknown): Promise<null> {
  return null;
}
export async function save(_options?: unknown): Promise<null> {
  return null;
}

/* ── plugin-process ── */
export async function exit(_code?: number): Promise<void> {}
export async function relaunch(): Promise<void> {}

/* ── plugin-updater ── */
export async function check(): Promise<null> {
  return null;
}

/* ── plugin-store ── */
export class Store {
  static async load(): Promise<Store> {
    return new Store();
  }
  async get(): Promise<null> {
    return null;
  }
  async set(): Promise<void> {}
  async save(): Promise<void> {}
  async delete(): Promise<boolean> {
    return false;
  }
}
export async function load(): Promise<Store> {
  return new Store();
}

export default {};
