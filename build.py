#!/usr/bin/env python3
"""Gera o site (index.html) a partir do arquivo do jogo usado no Claude.

Uso: python3 build.py <caminho/do/z-arena.html>

- tira o "envelope" da página do Claude;
- troca os vídeos/imagens /_blob/<id> pelos arquivos da pasta media/;
- injeta o Supabase (login, online e progresso) via src/zsb.js e src/zsb.css;
- escreve a política de segurança (CSP) da página.

A biblioteca do Supabase: se existir src/supabase.min.js, ela vai embutida no
próprio arquivo e o site deixa de depender de um servidor de fora. Sem esse
arquivo, cai no CDN e o build avisa. Para baixar:
    curl -o src/supabase.min.js https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js
"""
import base64, hashlib, os, re, sys

ROOT = os.path.dirname(os.path.abspath(__file__))
SUPABASE_JS = "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js"
SUPABASE_LOCAL = os.path.join(ROOT, "src", "supabase.min.js")

# Mídia embutida (data:...;base64,...) vira arquivo em media/b64/.
# O arquivo de trabalho continua com tudo dentro; quem emagrece é só o site.
# Abaixo deste tamanho a mídia fica embutida: são os ícones da interface, que
# precisam aparecer junto com a tela, sem esperar rede.
B64_LIMITE = 4096
B64_DIR = "media/b64"
B64_EXT = {"image/webp": "webp", "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif",
           "image/svg+xml": "svg", "audio/mpeg": "mp3", "audio/ogg": "ogg", "audio/wav": "wav",
           "video/mp4": "mp4", "video/webm": "webm"}
CFG = {
    "url": "https://fpntdutdeisbbgiyjvjk.supabase.co",
    "key": "sb_publishable_q4e8Cdn50xWHv98_mF98Nw_FqPe9rjB",  # chave pública (pode ficar no site)
    "providers": ["google"],  # adicionar "discord" quando for configurado no Supabase
    # Entrar por e-mail: desligado enquanto o envio for o do Supabase, que libera
    # poucos links por hora. Virar True quando houver SMTP próprio configurado.
    "email": False,
}


def tira_embutidas(s):
    """Grava cada mídia embutida como arquivo e deixa o caminho no lugar dela.

    O nome sai do conteúdo (sha1), então o mesmo desenho sempre vira o mesmo
    arquivo: build repetido não mexe em nada, e o navegador aproveita o cache.
    """
    saida = os.path.join(ROOT, *B64_DIR.split("/"))
    os.makedirs(saida, exist_ok=True)
    usados, novos, ficaram, bytes_fora = set(), 0, 0, 0

    def rep(m):
        nonlocal novos, ficaram, bytes_fora
        inteiro, mime, b64 = m.group(0), m.group(1), m.group(2)
        ext = B64_EXT.get(mime)
        if ext is None or len(inteiro) <= B64_LIMITE:
            ficaram += 1
            return inteiro
        try:
            dados = base64.b64decode(b64, validate=True)
        except Exception:
            ficaram += 1
            return inteiro
        nome = hashlib.sha1(dados).hexdigest()[:16] + "." + ext
        usados.add(nome)
        caminho = os.path.join(saida, nome)
        if not os.path.exists(caminho) or os.path.getsize(caminho) != len(dados):
            open(caminho, "wb").write(dados)
            novos += 1
        bytes_fora += len(inteiro)
        return B64_DIR + "/" + nome

    s = re.sub(r"data:([a-z]+/[a-z0-9.+-]+);base64,([A-Za-z0-9+/=]+)", rep, s)

    # tira do repositório o que esta versão não usa mais
    velhos = 0
    for f in os.listdir(saida):
        if f not in usados and os.path.isfile(os.path.join(saida, f)):
            os.remove(os.path.join(saida, f))
            velhos += 1
    print("midia embutida: %d arquivos em %s (%.2f MB tirados do HTML), %d novos, %d removidos, %d ficaram embutidas"
          % (len(usados), B64_DIR, bytes_fora / 1048576, novos, velhos, ficaram))
    return s


def main(src):
    s = open(src, encoding="utf-8").read()
    i = s.find('<!DOCTYPE html><html lang="pt-BR">')
    if i > 0:
        s = s[i:]
        s = re.sub(r"(</body></html>)\s*</body></html>\s*$", r"\1\n", s)
    media = {f.split(".")[0]: f for f in os.listdir(os.path.join(ROOT, "media"))}
    missing = set()

    def rep(m):
        k = m.group(1)
        if k not in media:
            missing.add(k)
            return m.group(0)
        return "media/" + media[k]

    s = re.sub(r"/_blob/([0-9a-f]{32})", rep, s)
    if missing:
        sys.exit("faltam arquivos em media/: " + ", ".join(sorted(missing)))
    s = s.replace("<title>Projeto Ânima · Etapa 1</title>", "<title>Projeto Ânima</title>", 1)

    # A secao "Sistemas" das notas do patch e so para o link de testes. No site
    # publico ficam Buffs, Nerfs, Ajustes e Novidades. Ligar a chave aqui e mais
    # seguro do que mexer no array PATCH por regex.
    if s.count("const SYOFF=0;") != 1:
        sys.exit("build: esperava uma ocorrencia de 'const SYOFF=0;' e achei %d"
                 % s.count("const SYOFF=0;"))
    s = s.replace("const SYOFF=0;", "const SYOFF=1;", 1)

    s = tira_embutidas(s)
    import json
    zjs = open(os.path.join(ROOT, "src", "zsb.js"), encoding="utf-8").read()
    zcss = open(os.path.join(ROOT, "src", "zsb.css"), encoding="utf-8").read()

    # A biblioteca do Supabase fica hospedada aqui, não num servidor de fora.
    # Ela NÃO pode ir embutida: é um pacote webpack que descobre o próprio endereço
    # pela tag <script src>. Inline não existe src, e ela aborta com
    # "Automatic publicPath is not supported in this browser" — login e online morrem.
    # Por isso vira arquivo do site, carregado por caminho relativo.
    if os.path.exists(SUPABASE_LOCAL):
        destino = os.path.join(ROOT, "lib")
        os.makedirs(destino, exist_ok=True)
        dados = open(SUPABASE_LOCAL, "rb").read()
        alvo = os.path.join(destino, "supabase.min.js")
        if not os.path.exists(alvo) or open(alvo, "rb").read() != dados:
            open(alvo, "wb").write(dados)
        sblib = '<script src="lib/supabase.min.js"></script>'
        cdn = ""
        print("supabase-js: hospedado no proprio site (lib/supabase.min.js, %d bytes)" % len(dados))
    else:
        sblib = '<script src="' + SUPABASE_JS + '"></script>'
        cdn = " https://cdn.jsdelivr.net"
        print("AVISO: src/supabase.min.js nao existe, usando o CDN.\n"
              "       Para tirar essa dependencia de fora, rode:\n"
              "       curl -o src/supabase.min.js " + SUPABASE_JS)

    sb = CFG["url"]
    # Mesmo que um dia escape algum texto de jogador como HTML, o navegador só deixa
    # a página falar com o próprio Supabase: não dá para mandar a sessão para fora.
    csp = ("default-src 'self'; "
           "script-src 'self' 'unsafe-inline'" + cdn + "; "
           "style-src 'self' 'unsafe-inline'; "
           "img-src 'self' data: blob:; "
           "media-src 'self' data: blob:; "
           "font-src 'self' data:; "
           "connect-src 'self' " + sb + " " + sb.replace("https://", "wss://") + "; "
           "object-src 'none'; base-uri 'none'; form-action 'self'")

    head = (
        '<meta name="description" content="Projeto Ânima: jogo de estratégia por turnos no navegador.">'
        '<link rel="icon" href="favicon.ico" sizes="any">'
        '<link rel="icon" type="image/png" sizes="192x192" href="icons/icone-192.png">'
        '<link rel="apple-touch-icon" href="icons/icone-180.png">'
        '<link rel="manifest" href="manifest.webmanifest">'
        '<meta name="theme-color" content="#261b33">'
        '<meta name="mobile-web-app-capable" content="yes">'
        '<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">'
        '<meta http-equiv="Content-Security-Policy" content="' + csp + '">'
        '<meta name="referrer" content="strict-origin-when-cross-origin">'
        "<script>window.ZCFG=" + json.dumps(CFG) + ";</script>"
        + sblib +
        "<style>" + zcss + "</style>"
        "<script>" + zjs + "</script>"
    )
    j = s.find("<head>") + len("<head>")
    j = s.find(">", s.find("<meta", j)) + 1  # depois do <meta charset>
    s = s[:j] + head + s[j:]

    # registro do service worker, no fim da página para não atrasar a abertura
    s = s.replace("</body></html>",
                  "<script>if('serviceWorker' in navigator)addEventListener('load',function(){"
                  "navigator.serviceWorker.register('sw.js').catch(function(){})});</script>"
                  "</body></html>", 1)

    open(os.path.join(ROOT, "index.html"), "w", encoding="utf-8").write(s)

    # o service worker carimba a versão da página: assim cada publicação
    # troca o nome do cache e o aparelho do jogador larga o conteúdo antigo
    versao = hashlib.sha1(s.encode("utf-8")).hexdigest()[:12]
    sw = open(os.path.join(ROOT, "src", "sw.js"), encoding="utf-8").read()
    open(os.path.join(ROOT, "sw.js"), "w", encoding="utf-8").write(
        sw.replace("__VERSAO__", versao))
    print("sw.js: versao", versao)
    print("index.html:", len(s), "bytes")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/mnt/user-data/outputs/z-arena.html")
