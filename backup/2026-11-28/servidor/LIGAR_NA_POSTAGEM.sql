-- ===== Etapa 5: rodar SOMENTE no dia em que a versao nova do jogo for postada no site =====
-- Antes disso, ligar quebraria o site antigo (ele nao sabe pedir termos, nem abrir ranqueada
-- contra bot no servidor, nem usar o sorteio do servidor no draft).
-- Ordem da postagem:
--   1. copiar z-arena.html para src/projeto-anima.html, rodar build.py, commit e push no main
--   2. esperar o GitHub Pages publicar e abrir o site uma vez (Ctrl+F5) para conferir
--   3. rodar o bloco abaixo
--   4. gerar termos.html / privacidade.html de novo com termos_pagina.py se o texto mudou
update public.cfg set valor = 'on' where chave in ('prog_estrito', 'termos_exigir', 'salas_sorteio');
select chave, valor from public.cfg where chave in ('prog_estrito', 'termos_exigir', 'salas_sorteio', 'termos_versao');

-- Para desligar de novo (volta ao comportamento antigo, sem perder nada):
-- update public.cfg set valor = 'off' where chave in ('prog_estrito', 'termos_exigir', 'salas_sorteio');
