-- ===== Salas: o servidor reconhece cada jogador na grafia que o jogo usa (aplicada em 28/11/2026) =====
-- O jogo grava cada jogador da sala como m_<id com hifens>; o carimbo do modo servidor so
-- reconhecia m_<id com sublinhados> e por isso nunca conferia o nivel/perfil mostrado na sala.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.prog_docs()'::regprocedure);
  d := replace(d, $x$'^m_[0-9a-f]{8}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{12}$'$x$,
                  $x$'^m_[0-9a-f]{8}[-_][0-9a-f]{4}[-_][0-9a-f]{4}[-_][0-9a-f]{4}[-_][0-9a-f]{12}$'$x$);
  execute d;
end $$;
