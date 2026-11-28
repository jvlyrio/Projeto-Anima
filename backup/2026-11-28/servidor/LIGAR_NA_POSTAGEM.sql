-- ===== Etapa 5: rodar SOMENTE no dia em que a versao nova do jogo for postada no site =====
-- Antes disso, ligar quebraria o site antigo (ele nao sabe pedir termos, nem abrir ranqueada
-- contra bot no servidor, nem usar o sorteio do servidor no draft).
-- Ordem da postagem:
--   1. copiar z-arena.html para src/projeto-anima.html, site/zsb.js e site/build.py para o repositorio, rodar build.py
--      (gera index.html e motor/<versao>.js), commit e push no main
--   2. esperar o GitHub Pages publicar e abrir o site uma vez (Ctrl+F5) para conferir
--   3. rodar o bloco abaixo
--   4. gerar termos.html / privacidade.html de novo com termos_pagina.py se o texto mudou
--   5. no mesmo commit do passo 1, apagar de media/ as 7 bandeiras antigas que o jogo novo nao usa mais:
--      3e37028b1d0d0329500d3c7e1b590a31 13ca4487c9e73c99f406cac4fb5b0252 82ae1cd3521dff74e960270f4c0a7ad6
--      6ed200709fc31618c4393bdaecc10552 808ea86ab3680f89e3b68f7600d1fe94 a170c51a21075c437bcd852fb6156295
--      c1b5ad8f01caf6315f2efd5e491f5ef5   (todas .webp)
--   6. antes do build, conferir que os 6 videos de backup/2026-11-28/midia/ estao em media/ (o build para se faltar)
--   7. depois do bloco: jogar 1 partida contra bot (EXP) e 1 ranqueada contra bot com uma conta de teste e ver em
--      partida_conf uma linha ok=true para cada (se vier 'versao', o motor/<versao>.js ainda nao esta no site)
-- o motor da conferencia passa a vir do proprio site (o build gera motor/<versao>.js)
update public.cfg set valor = 'https://jvlyrio.github.io/Projeto-Anima/motor/' where chave = 'motor_base';
update public.cfg set valor = 'on' where chave in ('prog_estrito', 'termos_exigir', 'salas_sorteio', 'conferir_bot');
select chave, valor from public.cfg where chave in ('prog_estrito', 'termos_exigir', 'salas_sorteio', 'conferir_bot', 'motor_base', 'termos_versao');

-- Para desligar de novo (volta ao comportamento antigo, sem perder nada):
-- update public.cfg set valor = 'off' where chave in ('prog_estrito', 'termos_exigir', 'salas_sorteio', 'conferir_bot');
