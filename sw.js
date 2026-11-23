/* Service worker do Projeto Ânima.
   Regra de ouro: a página NUNCA vem do cache antes da rede. Se viesse, uma
   versão velha ficaria grudada no aparelho do jogador e nenhuma publicação
   chegaria nele. O cache serve para a mídia, que tem nome tirado do conteúdo
   e por isso nunca fica desatualizada: se o desenho muda, o nome muda junto.

   Gerado pelo build.py — não editar o sw.js da raiz, editar este. */
const VERSAO = "d3c55a3c8098";
const CACHE = "anima-" + VERSAO;

/* o esqueleto, baixado na instalação para a segunda visita abrir na hora */
const ESQUELETO = ["./", "./lib/supabase.min.js", "./favicon.ico",
                   "./icons/icone-192.png", "./icons/icone-512.png"];

self.addEventListener("install", e => {
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ESQUELETO).catch(() => {})));
});

self.addEventListener("activate", e => {
  e.waitUntil((async () => {
    for (const n of await caches.keys()) if (n !== CACHE) await caches.delete(n);
    await self.clients.claim();
  })());
});

const ehMidia = u => /\/(media|icons|lib)\//.test(u.pathname);

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
        const res = await fetch(r);
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
      const achou = await caches.match(r);
      if (achou) return achou;

      /* O GitHub Pages recusa requisições (503) nos primeiros minutos depois de
         uma publicação, quando a página pede centenas de mídias de uma vez. Sem
         uma segunda tentativa a imagem fica quebrada na tela até o jogador
         recarregar. Só repete quando o erro é passageiro — recusa do servidor
         ou falha de rede; repetir um 404 não adianta nada. */
      const passageiro = x => !x || x.status === 408 || x.status === 429 || x.status >= 500;
      let res = null;
      for (let tentativa = 0; tentativa < 3; tentativa++) {
        if (tentativa) await new Promise(ok => setTimeout(ok, 400 * tentativa));
        res = null;
        try { res = await fetch(r) } catch (x) {}
        if (!passageiro(res)) break;
      }
      /* 206 (pedaço de vídeo) não pode ser guardado: o cache recusa */
      if (res && res.status === 200) {
        const c = await caches.open(CACHE); c.put(r, res.clone());
      }
      return res || Response.error();
    })());
  }
});
