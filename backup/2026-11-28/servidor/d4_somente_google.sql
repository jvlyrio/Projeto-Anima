-- ===== Login so com Google: conta de convidado (anonima) nao joga nem grava nada (aplicada em 28/11/2026) =====
create or replace function public.conta_real() returns boolean
language sql stable set search_path to 'public' as $$
  select auth.uid() is not null and coalesce((auth.jwt()->>'is_anonymous')::boolean, false) = false
$$;
grant execute on function public.conta_real() to anon, authenticated;

-- gravacoes diretas nas tabelas
alter policy docs_insert on public.docs with check (public.conta_real() and (owner = auth.uid()) and doc_path_ok(path));
alter policy docs_update on public.docs
  using (public.conta_real() and ((owner = auth.uid()) or ((path ~~ 'admin/%'::text) and is_admin()) or doc_ramo_meu(path) or ((path ~ '^inv/[0-9a-fA-F-]{36}$'::text) and (auth.uid() is not null))))
  with check (public.conta_real() and ((owner = auth.uid()) or ((path ~~ 'admin/%'::text) and is_admin()) or doc_ramo_meu(path) or ((path ~ '^inv/[0-9a-fA-F-]{36}$'::text) and (auth.uid() is not null))));
alter policy docs_delete on public.docs using (public.conta_real() and ((owner = auth.uid()) or is_admin() or doc_ramo_meu(path)));
alter policy profiles_own_ins on public.profiles with check (public.conta_real() and uid = auth.uid());
alter policy profiles_own_upd on public.profiles using (public.conta_real() and uid = auth.uid()) with check (public.conta_real() and uid = auth.uid());

-- funcoes do servidor que gravam: fila, partida, resultado, termos e documentos
do $$
declare f text; d text;
  a text := $x$if u is null then raise exception 'sem sessao' using errcode = '42501'; end if;$x$;
  b text := $x$if auth.uid() is null then raise exception 'sem sessao' using errcode = '42501'; end if;$x$;
  c text := $x$
  if not public.conta_real() then raise exception 'entre com o Google' using errcode = '42501'; end if;$x$;
begin
  foreach f in array array['public.fila_casual_entrar(text)','public.fila_entrar(text)','public.partida_fim(text,text,text[],jsonb)',
                           'public.partida_iniciar(text,text)','public.rk_resultado(text,boolean,double precision)','public.termos_aceitar(text)'] loop
    d := pg_get_functiondef(f::regprocedure);
    if position('conta_real' in d) > 0 then continue; end if;
    if position(a in d) = 0 then raise exception '%: trecho nao achado', f; end if;
    execute replace(d, a, a || c);
  end loop;
  foreach f in array array['public.doc_set(text,jsonb)','public.doc_update(text,jsonb)'] loop
    d := pg_get_functiondef(f::regprocedure);
    if position('conta_real' in d) > 0 then continue; end if;
    if position(b in d) = 0 then raise exception '%: trecho nao achado', f; end if;
    execute replace(d, b, b || c);
  end loop;
end $$;
-- Depois disso as 84 contas de convidado foram apagadas (dados guardados no schema backup_20261128_convidados).
