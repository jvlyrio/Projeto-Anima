-- ===== Etapa 5: rodar SOMENTE no dia em que a versao nova do jogo for postada no site =====
-- Antes disso, ligar quebraria o site antigo (ele nao sabe pedir termos, nem abrir ranqueada
-- contra bot no servidor, nem usar o sorteio do servidor no draft).
-- Ordem da postagem:
--   1. copiar z-arena.html para src/projeto-anima.html, rodar build.py, commit e push no main
--   2. esperar o GitHub Pages publicar e abrir o site uma vez (Ctrl+F5) para conferir
--   3. rodar o bloco abaixo
--   4. gerar termos.html / privacidade.html de novo com termos_pagina.py se o texto mudou
--   5. no mesmo commit do passo 1, apagar de media/ as 7 bandeiras antigas que o jogo novo nao usa mais:
--      3e37028b1d0d0329500d3c7e1b590a31 13ca4487c9e73c99f406cac4fb5b0252 82ae1cd3521dff74e960270f4c0a7ad6
--      6ed200709fc31618c4393bdaecc10552 808ea86ab3680f89e3b68f7600d1fe94 a170c51a21075c437bcd852fb6156295
--      c1b5ad8f01caf6315f2efd5e491f5ef5   (todas .webp)
update public.cfg set valor = 'on' where chave in ('prog_estrito', 'termos_exigir', 'salas_sorteio');
select chave, valor from public.cfg where chave in ('prog_estrito', 'termos_exigir', 'salas_sorteio', 'termos_versao');

-- Para desligar de novo (volta ao comportamento antigo, sem perder nada):
-- update public.cfg set valor = 'off' where chave in ('prog_estrito', 'termos_exigir', 'salas_sorteio');
