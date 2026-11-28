-- ===== Partidas contra bot conferidas no servidor (aplicada em 28/11/2026) =====
-- A funcao conferir-partida (Edge Function) recebe o pacote gravado pelo aparelho, refaz a partida inteira com o
-- motor do jogo e grava aqui o resultado conferido. Com cfg 'conferir_bot' = 'on', a ranqueada contra bot
-- (rk_resultado) e a EXP/maestria das partidas contra bot (partida_fim) passam a valer por esse resultado.
create table if not exists public.partida_conf(
  partida text primary key,
  uid uuid not null references auth.users(id) on delete cascade,
  ok boolean not null,
  res text check (res in ('v','d','e')),
  time text[],
  dest jsonb,
  turnos int,
  motivo text,
  at timestamptz not null default now());
create index if not exists partida_conf_uid on public.partida_conf(uid, at);
alter table public.partida_conf enable row level security;
revoke all on public.partida_conf from anon, authenticated;

-- quem comeca a ranqueada contra bot sai deste sorteio do servidor (bit 0)
alter table public.rk_bot add column if not exists sv bigint;

insert into public.cfg(chave, valor) values ('conferir_bot','off') on conflict (chave) do nothing;
insert into public.cfg(chave, valor) values ('motor_base','https://raw.githubusercontent.com/jvlyrio/Projeto-Anima/backup-2026-11-27/backup/2026-11-28/servidor/motor/') on conflict (chave) do nothing;

create or replace function public.conf_ligada() returns boolean
language sql stable set search_path to 'public' as $$
  select coalesce((select valor from public.cfg where chave = 'conferir_bot'), 'off') = 'on'
$$;

-- o que a funcao conferir-partida precisa saber antes de refazer (so o servidor chama)
create or replace function public.partida_conf_info(p_uid uuid, p_partida text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare q public.partidas; b public.rk_bot; cf public.partida_conf; n int;
begin
  select * into q from public.partidas where uid = p_uid and id = p_partida;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'sem_inicio'); end if;
  if q.tipo not in ('bot','rk') then return jsonb_build_object('ok', false, 'motivo', 'tipo'); end if;
  if q.tipo = 'rk' then
    if exists (select 1 from public.rk_pvp where partida = p_partida) then return jsonb_build_object('ok', false, 'motivo', 'pvp'); end if;
    select * into b from public.rk_bot where partida = p_partida;
    if not found or b.uid <> p_uid then return jsonb_build_object('ok', false, 'motivo', 'sem_inicio'); end if;
  end if;
  select * into cf from public.partida_conf where partida = p_partida;
  if found then
    if cf.uid <> p_uid then return jsonb_build_object('ok', false, 'motivo', 'alheia'); end if;
    return jsonb_build_object('ok', true, 'ja', true, 'valeu', cf.ok, 'res', cf.res, 'motivo', cf.motivo);
  end if;
  select count(*) into n from public.partida_conf where uid = p_uid and at > now() - interval '1 hour';
  if n >= 150 then return jsonb_build_object('ok', false, 'motivo', 'limite'); end if;
  return jsonb_build_object('ok', true, 'tipo', q.tipo, 'sv', b.sv,
    'base', (select valor from public.cfg where chave = 'motor_base'));
end $$;
revoke all on function public.partida_conf_info(uuid, text) from public, anon, authenticated;
grant execute on function public.partida_conf_info(uuid, text) to service_role;

-- grava o que a funcao conferiu (so o servidor chama)
create or replace function public.partida_conf_grava(p_uid uuid, p_partida text, p_ok boolean, p_res text, p_time text[], p_dest jsonb, p_turnos int, p_motivo text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if not exists (select 1 from public.partidas where uid = p_uid and id = p_partida and tipo in ('bot','rk')) then
    return jsonb_build_object('ok', false, 'motivo', 'sem_inicio');
  end if;
  insert into public.partida_conf(partida, uid, ok, res, time, dest, turnos, motivo)
  values (p_partida, p_uid, p_ok, case when p_ok then p_res end, case when p_ok then p_time end,
          case when p_ok then p_dest end, p_turnos, left(p_motivo, 200))
  on conflict (partida) do nothing;
  delete from public.partida_conf where uid = p_uid and at < now() - interval '30 days';
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.partida_conf_grava(uuid, text, boolean, text, text[], jsonb, int, text) from public, anon, authenticated;
grant execute on function public.partida_conf_grava(uuid, text, boolean, text, text[], jsonb, int, text) to service_role;

-- ranqueada contra bot: o servidor tambem sorteia quem comeca
do $$
declare d text;
begin
  d := pg_get_functiondef('public.rk_bot_iniciar()'::regprocedure);
  d := replace(d, $x$pid text; m double precision;$x$, $x$pid text; m double precision; sv bigint := floor(random() * 2147483647)::bigint;$x$);
  d := replace(d, $x$insert into public.rk_bot(partida, uid, mmr) values (pid, u, m);$x$, $x$insert into public.rk_bot(partida, uid, mmr, sv) values (pid, u, m, sv);$x$);
  d := replace(d, $x$return jsonb_build_object('ok', true, 'partida', pid, 'mmr', m);$x$, $x$return jsonb_build_object('ok', true, 'partida', pid, 'mmr', m, 'sv', sv);$x$);
  if position('mmr, sv) values' in d) = 0 or position($x$'sv', sv)$x$ in d) = 0 then raise exception 'rk_bot_iniciar: trecho nao encontrado'; end if;
  execute d;
end $$;

-- rk_resultado: na ranqueada contra bot (conferencia ligada) vale o resultado conferido
do $$
declare d text;
begin
  d := pg_get_functiondef('public.rk_resultado(text,boolean,double precision)'::regprocedure);
  d := replace(d, $x$bt public.rk_bot; bok boolean := false;$x$, $x$bt public.rk_bot; bok boolean := false; cf public.partida_conf;$x$);
  d := replace(d, $x$  if est and not xok and not bok then
    return jsonb_build_object('repetida', true, 'recusada', true, 'motivo', 'sem_inicio', 'st', to_jsonb(r));
  end if;
$x$, $x$  if est and not xok and not bok then
    return jsonb_build_object('repetida', true, 'recusada', true, 'motivo', 'sem_inicio', 'st', to_jsonb(r));
  end if;
  if bok and public.conf_ligada() then
    select * into cf from public.partida_conf where partida = p_partida and uid = u;
    if not found or not cf.ok then
      return jsonb_build_object('repetida', true, 'recusada', true,
        'motivo', case when found then 'conferencia' else 'sem_conferencia' end, 'st', to_jsonb(r));
    end if;
    venceu := cf.res = 'v';
  end if;
$x$);
  if position('venceu := cf.res' in d) = 0 then raise exception 'rk_resultado: trecho nao encontrado'; end if;
  execute d;
end $$;

-- partida_fim: nas partidas contra bot (conferencia ligada) valem o resultado, o time e os destaques conferidos
do $$
declare d text;
begin
  d := pg_get_functiondef('public.partida_fim(text,text,text[],jsonb)'::regprocedure);
  d := replace(d, $x$motivo text := null;$x$, $x$motivo text := null; cf public.partida_conf;$x$);
  d := replace(d, $x$  ganho := case when p_res = 'v' then 275 else 195 end;$x$, $x$  if public.conf_ligada() and q.tipo in ('bot','rk')
     and not exists (select 1 from public.rk_pvp where partida = p_id) then
    select * into cf from public.partida_conf where partida = p_id and uid = u;
    if not found or not cf.ok then
      update public.partidas set fim = now(), res = p_res, xp = 0,
        nota = case when found then 'conferencia' else 'sem_conferencia' end where uid = u and id = p_id;
      return jsonb_build_object('valeu', false, 'motivo', case when found then 'conferencia' else 'sem_conferencia' end,
        'estrito', public.prog_estrito(), 'xp', p.xp, 'nv', public.prog_nivel(p.xp), 'mx', p.mx);
    end if;
    p_res := cf.res; p_time := cf.time; p_dest := cf.dest;
  end if;
  ganho := case when p_res = 'v' then 275 else 195 end;$x$);
  if position('p_res := cf.res' in d) = 0 then raise exception 'partida_fim: trecho nao encontrado'; end if;
  execute d;
end $$;

-- ===== Correcao aplicada logo depois (migracao conferir_partidas_bot_motivo) =====
-- partida_fim: o motivo devolvido (sem_conferencia / conferencia) saia trocado porque o UPDATE mudava o FOUND
do $$
declare d text;
begin
  d := pg_get_functiondef('public.partida_fim(text,text,text[],jsonb)'::regprocedure);
  d := replace(d, $x$motivo text := null; cf public.partida_conf;$x$, $x$motivo text := null; cf public.partida_conf; cfm text;$x$);
  d := replace(d, $x$    if not found or not cf.ok then
      update public.partidas set fim = now(), res = p_res, xp = 0,
        nota = case when found then 'conferencia' else 'sem_conferencia' end where uid = u and id = p_id;
      return jsonb_build_object('valeu', false, 'motivo', case when found then 'conferencia' else 'sem_conferencia' end,$x$,
  $x$    cfm := case when not found then 'sem_conferencia' when not cf.ok then 'conferencia' end;
    if cfm is not null then
      update public.partidas set fim = now(), res = p_res, xp = 0, nota = cfm where uid = u and id = p_id;
      return jsonb_build_object('valeu', false, 'motivo', cfm,$x$);
  if position('nota = cfm' in d) = 0 then raise exception 'partida_fim: trecho nao encontrado'; end if;
  execute d;
end $$;
