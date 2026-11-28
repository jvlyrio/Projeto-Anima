// conferir-partida: confere no servidor uma partida contra bot.
// Recebe o pacote gravado pelo aparelho (comeco + jogadas), monta a partida de novo com o motor do jogo
// da mesma versao, refaz turno a turno (srvConfere, que mora no proprio jogo) e grava o resultado conferido
// em partida_conf. A ranqueada contra bot e a EXP passam a valer por esse resultado (cfg conferir_bot).
const _fetch = globalThis.fetch.bind(globalThis);
const _Resp = Response, _JSON = JSON, _st = globalThis.setTimeout.bind(globalThis);
const SB = Deno.env.get("SUPABASE_URL")!, SRK = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const CORS: Record<string, string> = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const resp = (o: unknown, st = 200) => new _Resp(_JSON.stringify(o), { status: st, headers: { ...CORS, "Content-Type": "application/json" } });

async function rpc(fn: string, args: unknown) {
  const r = await _fetch(`${SB}/rest/v1/rpc/${fn}`, { method: "POST", headers: { apikey: SRK, Authorization: `Bearer ${SRK}`, "Content-Type": "application/json" }, body: _JSON.stringify(args) });
  const t = await r.text(); if (!r.ok) throw new Error(fn + " " + r.status + " " + t.slice(0, 200)); return t ? _JSON.parse(t) : null;
}
async function usuario(auth: string) {
  if (!/^Bearer\s+\S+/.test(auth)) return null;
  const r = await _fetch(`${SB}/auth/v1/user`, { headers: { apikey: ANON, Authorization: auth } });
  return r.ok ? await r.json() : null;
}

// ----- o motor do jogo, sem tela -----
function stub(): any { const f: any = function () { return P; }; const P: any = new Proxy(f, { get(t, k) { if (k === Symbol.toPrimitive) return () => ""; if (k === "length") return 0; if (k === Symbol.iterator) return function* () {}; if (k === "then") return undefined; if (k in t) return t[k]; return P; }, set() { return true; }, apply() { return P; }, construct() { return P; }, has() { return true; } }); return P; }
let ambiente = false, VER = "";
function montaAmbiente() {
  if (ambiente) return; ambiente = true;
  const g: any = globalThis, S = stub(), store: Record<string, string> = {};
  const ls = { getItem: (k: string) => (k in store ? store[k] : null), setItem: (k: string, v: string) => { store[k] = String(v); }, removeItem: (k: string) => { delete store[k]; }, key: (i: number) => Object.keys(store)[i] || null, get length() { return Object.keys(store).length; }, clear() { for (const k in store) delete store[k]; } };
  const doc = new Proxy({}, { get(_t, k) { if (k === "cookie") return ""; if (k === "readyState") return "complete"; if (k === "visibilityState") return "visible"; if (k === "querySelectorAll" || k === "getElementsByClassName" || k === "getElementsByTagName") return () => []; if (k === "createElement") return () => stub(); return S; }, set() { return true; } });
  const def = (k: string, v: unknown) => { try { Object.defineProperty(g, k, { value: v, writable: true, configurable: true }); } catch (_e) { /* fica o que ja existe */ } };
  def("window", g); def("self", g); def("document", doc); def("localStorage", ls); def("sessionStorage", ls);
  def("location", { href: "https://x/", search: "", hash: "", protocol: "https:", host: "x", hostname: "x", pathname: "/", origin: "https://x", reload() {} });
  def("matchMedia", () => ({ matches: false, addEventListener() {}, addListener() {} }));
  for (const k of ["Image", "Audio", "ResizeObserver", "IntersectionObserver", "MutationObserver", "HTMLElement", "Element", "Node"]) def(k, function () { return S; });
  def("requestAnimationFrame", () => 0); def("cancelAnimationFrame", () => {}); def("getComputedStyle", () => S); def("scrollTo", () => {});
  def("innerWidth", 1366); def("innerHeight", 800); def("devicePixelRatio", 1); def("screen", { width: 1366, height: 800, orientation: { type: "landscape" } });
  def("history", { replaceState() {}, pushState() {} }); def("alert", () => {}); def("confirm", () => false); def("prompt", () => null);
  // o jogo nao pode deixar nada agendado aqui (o que esta funcao usa ja foi guardado la em cima)
  def("setTimeout", () => 0); def("setInterval", () => 0); def("clearTimeout", () => {}); def("clearInterval", () => {});
}
async function motor(base: string, v: string): Promise<boolean> {
  if (VER === v) return true;
  const r = await _fetch(base + v + ".js"); if (!r.ok) return false;
  const code = await r.text(); if (code.length < 100000) return false;
  montaAmbiente(); VER = "";
  (0, eval)(code + "\n;globalThis.__aqui=(s)=>eval(s);");
  for (let i = 0; i < 300; i++) { const n = (globalThis as any).__aqui('typeof C!="undefined"&&C?Object.keys(C).length:0'); if (n) { VER = v; return true; } await new Promise((z) => _st(z, 10)); }
  return false;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new _Resp("ok", { headers: CORS });
  if (req.method !== "POST") return resp({ ok: false, motivo: "metodo" }, 405);
  try {
    const u = await usuario(req.headers.get("Authorization") || "");
    if (!u || !u.id) return resp({ ok: false, motivo: "sessao" }, 401);
    if (u.is_anonymous) return resp({ ok: false, motivo: "google" }, 403);
    let P: any; try { P = await req.json(); } catch (_e) { return resp({ ok: false, motivo: "pacote" }, 400); }
    const id = String(P && P.id || ""), v = String(P && P.v || "");
    if (!/^(rk-[a-z0-9]{1,16}-[a-z0-9]{1,12}|l:[a-z0-9]{4,40})$/.test(id)) return resp({ ok: false, motivo: "id" }, 400);
    if (!/^[A-Za-z0-9_-]{2,40}$/.test(v)) return resp({ ok: false, motivo: "versao" }, 400);
    const info = await rpc("partida_conf_info", { p_uid: u.id, p_partida: id });
    if (!info || !info.ok) return resp({ ok: false, motivo: (info && info.motivo) || "info", fim: true });
    if (info.ja) return resp({ ok: !!info.valeu, ja: true, res: info.res, motivo: info.motivo || null, fim: true });
    if (!(await motor(String(info.base || ""), v))) return resp({ ok: false, motivo: "versao" });
    const opc: Record<string, unknown> = { gid: id };
    if (info.tipo === "rk" && Number.isInteger(info.sv)) opc.cur = info.sv & 1;
    const r = (globalThis as any).__aqui("srvConfere")(P, opc);
    await rpc("partida_conf_grava", { p_uid: u.id, p_partida: id, p_ok: !!r.ok, p_res: r.res || null, p_time: r.time || null, p_dest: r.dest || null, p_turnos: r.turnos || 0, p_motivo: r.motivo || null });
    return resp(r.ok ? { ok: true, res: r.res, fim: true } : { ok: false, motivo: r.motivo, fim: true });
  } catch (e) {
    return resp({ ok: false, motivo: "erro: " + String(e).slice(0, 120) }, 500);
  }
});
