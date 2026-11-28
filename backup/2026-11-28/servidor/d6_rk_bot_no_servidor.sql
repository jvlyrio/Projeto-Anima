-- ===== Ranqueada contra bot: o servidor abre a partida e decide o MMR do adversario (aplicada em 28/11/2026) =====
-- Pontuacao igual a de antes (MMR do bot = MMR do jogador +- 80), mas quem sorteia e guarda e o servidor.
-- rk_resultado passa a usar esse MMR e, no modo servidor, recusa ranqueada que o servidor nao abriu.
create table if not exists public.rk_bot(
  partida text primary key,
  uid uuid not null references auth.users(id) on delete cascade,
  mmr double precision not null,
  inicio timestamptz not null default now());
create index if not exists rk_bot_uid on public.rk_bot(uid, inicio);
alter table public.rk_bot enable row level security;
revoke all on public.rk_bot from anon, authenticated;

create or replace function public.rk_b36(n bigint) returns text
language plpgsql immutable set search_path to 'public' as $$
declare a text := '0123456789abcdefghijklmnopqrstuvwxyz'; o text := ''; v bigint := greatest(n, 0);
begin
  loop o := substr(a, (v % 36)::int + 1, 1) || o; v := v / 36; exit when v = 0; end loop;
  return o;
end $$;
revoke all on function public.rk_b36(bigint) from public, anon, authenticated;

create or replace function public.rk_bot_iniciar() returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare u uuid := auth.uid(); r public.ranked; sea_atual text := public.rk_season();
  pid text; m double precision; n int; i int := 0; a text := '0123456789abcdefghijklmnopqrstuvwxyz'; rnd text;
begin
  if u is null then raise exception 'sem sessao' using errcode = '42501'; end if;
  if not public.conta_real() then raise exception 'entre com o Google' using errcode = '42501'; end if;
  if not public.termos_ok(u) then return jsonb_build_object('ok', false, 'motivo', 'termos'); end if;
  if public.prog_estrito() and public.prog_nivel((public.prog_garante(u)).xp) < 10 then
    return jsonb_build_object('ok', false, 'motivo', 'nivel');
  end if;
  select count(*) into n from public.partidas where uid = u and inicio > now() - interval '1 hour';
  if n >= 120 then return jsonb_build_object('ok', false, 'motivo', 'limite'); end if;
  insert into public.ranked(uid, sea) values (u, sea_atual) on conflict (uid) do nothing;
  select * into r from public.ranked where uid = u;
  if r.sea is distinct from sea_atual then r := public.rk_reset(r, sea_atual); end if;
  m := greatest(0, round(coalesce(r.mmr, 1000) + (random() * 160 - 80)));
  loop
    rnd := '';
    for k in 1..5 loop rnd := rnd || substr(a, floor(random() * 36)::int + 1, 1); end loop;
    pid := 'rk-' || public.rk_b36((extract(epoch from clock_timestamp()) * 1000)::bigint) || '-' || rnd;
    i := i + 1;
    exit when (not exists (select 1 from public.rk_bot where partida = pid)
           and not exists (select 1 from public.rk_pvp where partida = pid)) or i > 8;
  end loop;
  insert into public.rk_bot(partida, uid, mmr) values (pid, u, m);
  insert into public.partidas(uid, id, tipo) values (u, pid, 'rk') on conflict do nothing;
  delete from public.rk_bot where uid = u and inicio < now() - interval '30 days';
  return jsonb_build_object('ok', true, 'partida', pid, 'mmr', m);
end $$;
revoke all on function public.rk_bot_iniciar() from public, anon;
grant execute on function public.rk_bot_iniciar() to authenticated;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.rk_resultado(text,boolean,double precision)'::regprocedure);
  d := replace(d, $x$outro public.ranked_log; g0 public.ranked_log; ou uuid;$x$,
                  $x$outro public.ranked_log; g0 public.ranked_log; ou uuid; bt public.rk_bot; bok boolean := false;$x$);
  d := replace(d, $x$  if xok then ou := case when u = x.a then x.b else x.a end; end if;
$x$, $x$  if xok then ou := case when u = x.a then x.b else x.a end; end if;
  if not xok then select * into bt from public.rk_bot where partida = p_partida; bok := found; end if;
$x$);
  d := replace(d, $x$  if xok and u <> x.a and u <> x.b then
    return jsonb_build_object('repetida', true, 'recusada', true, 'motivo', 'alheia', 'st', to_jsonb(r));
  end if;
$x$, $x$  if (xok and u <> x.a and u <> x.b) or (bok and bt.uid <> u) then
    return jsonb_build_object('repetida', true, 'recusada', true, 'motivo', 'alheia', 'st', to_jsonb(r));
  end if;
  if est and not xok and not bok then
    return jsonb_build_object('repetida', true, 'recusada', true, 'motivo', 'sem_inicio', 'st', to_jsonb(r));
  end if;
$x$);
  d := replace(d, $x$  if xok then opp := case when u = x.a then x.mb else x.ma end; end if;
$x$, $x$  if xok then opp := case when u = x.a then x.mb else x.ma end; end if;
  if bok then opp := bt.mmr; end if;
$x$);
  if position('bok := found' in d) = 0 or position('if bok then opp := bt.mmr' in d) = 0
     or position('if est and not xok and not bok' in d) = 0 or position('bt.uid <> u' in d) = 0 then
    raise exception 'rk_resultado: trecho nao encontrado';
  end if;
  execute d;
end $$;
