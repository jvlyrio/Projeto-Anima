/* Service worker do Projeto Ânima.
   Regra de ouro: a página NUNCA vem do cache antes da rede. Se viesse, uma
   versão velha ficaria grudada no aparelho do jogador e nenhuma publicação
   chegaria nele. O cache serve para a mídia, que tem nome tirado do conteúdo
   e por isso nunca fica desatualizada: se o desenho muda, o nome muda junto.

   Gerado pelo build.py — não editar o sw.js da raiz, editar este. */
const VERSAO = "__VERSAO__";
const CACHE = "anima-" + VERSAO;
/* A mídia mora num cache que NÃO muda a cada publicação. Antes ela ficava no
   cache da versão, e toda publicação apagava tudo: os jogadores baixavam de
   novo todas as falas e vídeos, justo quando o GitHub Pages ainda está lento
   com a publicação nova. O nome do arquivo já é o conteúdo, então não há como
   ficar desatualizada. */
const MIDIA = "anima-midia";

/* o esqueleto, baixado na instalação para a segunda visita abrir na hora */
const ESQUELETO = ["./", "./lib/supabase.min.js", "./favicon.ico",
                   "./icons/icone-192.png", "./icons/icone-512.png"];

self.addEventListener("install", e => {
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ESQUELETO).catch(() => {})));
});

self.addEventListener("activate", e => {
  e.waitUntil((async () => {
    const midia = await caches.open(MIDIA);
    for (const n of await caches.keys()) {
      if (n === CACHE || n === MIDIA) continue;
      /* aproveita a mídia que já estava baixada no cache antigo */
      try {
        const velho = await caches.open(n);
        for (const req of await velho.keys()) {
          if (!/\/(media|icons|lib)\//.test(new URL(req.url).pathname)) continue;
          if (await midia.match(req)) continue;
          const res = await velho.match(req);
          if (res && res.status === 200) await midia.put(req, res);
        }
      } catch (x) {}
      await caches.delete(n);
    }
    await self.clients.claim();
  })());
});

const ehMidia = u => /\/(media|icons|lib)\//.test(u.pathname);

/* Vídeo e áudio pedem o arquivo em pedaços (cabeçalho Range). Um pedaço (206)
   não pode ser guardado, então antes os vídeos nunca entravam no cache e
   baixavam de novo a cada vez. Agora o arquivo inteiro é baixado uma vez,
   guardado, e o pedaço pedido sai dele. O iPhone exige a resposta 206. */
async function pedaco(req, res) {
  const range = req.headers.get("range");
  if (!range || !res || res.status !== 200) return res;
  const buf = await res.clone().arrayBuffer(), total = buf.byteLength;
  const m = /bytes=(\d*)-(\d*)/.exec(range);
  let a = 0, b = total - 1;
  if (m) {
    if (m[1] === "" && m[2] !== "") { a = Math.max(0, total - +m[2]); }
    else { a = m[1] === "" ? 0 : +m[1]; if (m[2] !== "") b = Math.min(+m[2], total - 1); }
  }
  if (a >= total || a > b) return new Response(null, { status: 416, headers: { "Content-Range": "bytes */" + total } });
  return new Response(buf.slice(a, b + 1), { status: 206, statusText: "Partial Content", headers: {
    "Content-Type": res.headers.get("Content-Type") || "application/octet-stream",
    "Content-Range": "bytes " + a + "-" + b + "/" + total,
    "Content-Length": String(b - a + 1), "Accept-Ranges": "bytes" } });
}
/* dois pedidos do mesmo arquivo ao mesmo tempo esperam um único download */
const BAIXANDO = new Map();

self.addEventListener("fetch", e => {
  const r = e.request;
  if (r.method !== "GET") return;
  let u; try { u = new URL(r.url) } catch (x) { return }

  /* o Supabase (login, salas, ranqueada) nunca passa por cache */
  if (u.origin !== self.location.origin) return;

  /* a página: rede primeiro, cache só como rede de segurança quando está offline */
  if (r.mode === "navigate" || u.pathname.endsWith(".html") || u.pathname.endsWith("/")) {
    e.respondWith((async () => {
      try {
        /* "no-cache": confere com o servidor em vez de usar a página guardada
           pelo navegador (o GitHub Pages manda guardar por 10 minutos), senão
           quem recarrega para atualizar pode receber a versão antiga */
        const res = await fetch(r.url, { cache: "no-cache", credentials: "same-origin" });
        if (res && res.status === 200) {
          const c = await caches.open(CACHE); c.put("./", res.clone());
        }
        return res;
      } catch (x) {
        return (await caches.match("./")) || Response.error();
      }
    })());
    return;
  }

  /* mídia, ícones e biblioteca: cache primeiro, porque o nome do arquivo
     já carrega o conteúdo e um arquivo desses nunca muda por baixo */
  if (ehMidia(u)) {
    e.respondWith((async () => {
      const chave = u.origin + u.pathname;
      const achou = (await caches.match(chave, { ignoreSearch: true })) || (await caches.match(r));
      if (achou) return pedaco(r, achou);
      if (BAIXANDO.has(chave)) { const pr = await BAIXANDO.get(chave); if (pr) return pedaco(r, pr.clone()); }

      /* O GitHub Pages recusa requisições (503) nos primeiros minutos depois de
         uma publicação, quando a página pede centenas de mídias de uma vez. Sem
         uma segunda tentativa a imagem fica quebrada na tela até o jogador
         recarregar. Só repete quando o erro é passageiro — recusa do servidor
         ou falha de rede; repetir um 404 não adianta nada. */
      const passageiro = x => !x || x.status === 408 || x.status === 429 || x.status >= 500;
      /* sempre o arquivo inteiro (sem Range), para poder guardar */
      const baixa = (async () => {
        let res = null;
        for (let tentativa = 0; tentativa < 3; tentativa++) {
          if (tentativa) await new Promise(ok => setTimeout(ok, 400 * tentativa));
          res = null;
          try { res = await fetch(chave, { credentials: "same-origin" }) } catch (x) {}
          if (!passageiro(res)) break;
        }
        if (res && res.status === 200) {
          try { const c = await caches.open(MIDIA); await c.put(chave, res.clone()); } catch (x) {}
        }
        return res;
      })();
      BAIXANDO.set(chave, baixa);
      let res = null;
      try { res = await baixa } finally { BAIXANDO.delete(chave) }
      if (!res) return Response.error();
      return pedaco(r, res.clone());
    })());
  }
});
