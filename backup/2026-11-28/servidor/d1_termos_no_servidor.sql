-- ===== Termos de uso conferidos no servidor =====
-- termos_versao: a versao atual (a mesma de TERMOS.versao no jogo). termos_exigir: 'off' ate a postagem; 'on' = sem aceite da versao atual nao cria/entra em sala, nao entra na fila e nao comeca partida.
insert into public.cfg(chave, valor) values ('termos_versao','2026-11-27'), ('termos_exigir','off')
on conflict (chave) do nothing;

create or replace function public.termos_ok(u uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select coalesce((select valor from public.cfg where chave = 'termos_exigir'), 'off') <> 'on'
      or exists (select 1 from public.termos_aceite t
                  where t.uid = u and t.versao = (select valor from public.cfg where chave = 'termos_versao'));
$$;
revoke all on function public.termos_ok(uuid) from public, anon, authenticated;

-- salas: criar ou entrar como jogador pede o aceite (quem ja esta na sala continua jogando)
create or replace function public.docs_termos() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare u uuid := auth.uid(); us text;
begin
  if u is null or new.path !~ '^rooms/[A-Za-z0-9]{3,12}$' then return new; end if;
  us := u::text;
  if tg_op = 'INSERT' or ((coalesce(new.data->>'p0','') = us or coalesce(new.data->>'p1','') = us)
      and not (coalesce(old.data->>'p0','') = us or coalesce(old.data->>'p1','') = us)) then
    if not public.termos_ok(u) then raise exception 'termos' using errcode = '42501', hint = 'aceite os termos de uso'; end if;
  end if;
  return new;
end $$;
revoke all on function public.docs_termos() from public, anon, authenticated;
drop trigger if exists docs_termos_t on public.docs;
create trigger docs_termos_t before insert or update on public.docs for each row execute function public.docs_termos();

-- partida e fila ranqueada: sem o aceite da versao atual, recusa
do $$
declare d text; a text := $x$if u is null then raise exception 'sem sessao' using errcode = '42501'; end if;$x$;
begin
  d := pg_get_functiondef('public.partida_iniciar(text,text)'::regprocedure);
  if position(a in d) = 0 then raise exception 'partida_iniciar: trecho nao achado'; end if;
  if position('termos_ok' in d) = 0 then
    d := replace(d, a, a || E'\n  if not public.termos_ok(u) then return jsonb_build_object(''ok'', false, ''motivo'', ''termos''); end if;');
    execute d;
  end if;
  d := pg_get_functiondef('public.fila_entrar(text)'::regprocedure);
  if position(a in d) = 0 then raise exception 'fila_entrar: trecho nao achado'; end if;
  if position('termos_ok' in d) = 0 then
    d := replace(d, a, a || E'\n  if not public.termos_ok(u) then return jsonb_build_object(''estado'', ''termos''); end if;');
    execute d;
  end if;
end $$;
