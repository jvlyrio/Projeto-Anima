-- sem limite de partidas pagas por hora (decisao do dono do jogo)
update public.cfg set valor = '1000000', updated_at = now() where chave = 'prog_max_hora';

-- ===== excluir a propria conta =====
-- perfil salvo so existe para conta que existe (conta apagada nao volta pelo envio automatico)
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_uid_fkey') then
    alter table public.profiles add constraint profiles_uid_fkey foreign key (uid) references auth.users(id) on delete cascade not valid;
  end if;
end $$;
create or replace function public.conta_excluir() returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare u uuid := auth.uid(); us text; uk text; n int := 0;
begin
  if u is null then raise exception 'sem sessao' using errcode = '42501'; end if;
  us := u::text; uk := 'm_' || replace(us, '-', '_');
  -- documentos: os dele, o perfil publico, presenca, amigos, conversas, convites e a maestria
  delete from public.docs d where d.owner = u
     or d.path in ('players/' || us, 'pres/' || us, 'inv/' || us, 'maestria/' || uk)
     or d.path like 'fr/' || us || '/%' or d.path like 'fr/%/' || us
     or d.path like 'dm/%' || us || '%' or d.path like 'dmn/' || us || '/%' or d.path like 'dmn/%/' || us;
  get diagnostics n = row_count;
  delete from public.profiles where uid = u;
  delete from public.avisos where uid = u;
  delete from public.admins where uid = u;
  delete from public.rk_pvp where a = u or b = u;
  update public.fila set rival = null where rival = u;
  -- a conta: progresso, partidas, ranqueada, fila e aceite dos termos vao junto (cascata)
  delete from auth.users where id = u;
  return jsonb_build_object('ok', true, 'docs', n);
end $$;
revoke all on function public.conta_excluir() from public, anon;
grant execute on function public.conta_excluir() to authenticated;

-- ===== abandono no PvP ranqueado (modo servidor) =====
-- quando o vencedor manda o resultado e o outro ainda nao mandou, a derrota do outro ja entra (forcada).
-- Se depois o outro disser que venceu, e conflito: as duas partes sao desfeitas.
alter table public.ranked_log add column if not exists forcada boolean not null default false;

create or replace function public.rk_desfaz(p_uid uuid, p_partida text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare g public.ranked_log; a jsonb;
begin
  select * into g from public.ranked_log where uid = p_uid and partida = p_partida;
  if not found then return; end if;
  update public.ranked_log set conflito = true where uid = p_uid and partida = p_partida;
  a := g.antes;
  if a is not null and not exists (select 1 from public.ranked_log x where x.uid = p_uid and x.at > g.at) then
    update public.ranked set rank=(a->>'rank')::int, div=(a->>'div')::int, pr=(a->>'pr')::int,
      pc=nullif(a->>'pc','')::int, mmr=(a->>'mmr')::double precision, n=(a->>'n')::int, w=(a->>'w')::int,
      l=(a->>'l')::int, prot=(a->>'prot')::int, dprot=(a->>'dprot')::int, pen=(a->>'pen')::int,
      hirank=(a->>'hirank')::int, hidiv=(a->>'hidiv')::int, updated_at=now()
    where uid = p_uid and sea = a->>'sea';
  end if;
end $$;
revoke all on function public.rk_desfaz(uuid,text) from public, anon, authenticated;

-- aplica uma partida a uma conta (mesma conta do rk_resultado), sem mexer no "ultima"
create or replace function public.rk_aplica_em(p_uid uuid, p_partida text, p_venceu boolean, p_opp double precision, p_forcada boolean) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare r public.ranked; sea_atual text := public.rk_season(); o jsonb; snovo jsonb; dentro boolean; opp double precision;
begin
  insert into public.ranked(uid, sea) values (p_uid, sea_atual) on conflict (uid) do nothing;
  select * into r from public.ranked where uid = p_uid for update;
  if r.sea is distinct from sea_atual then r := public.rk_reset(r, sea_atual); end if;
  opp := public.rk_clamp(coalesce(p_opp, r.mmr), greatest(0, r.mmr - 600), r.mmr + 600);
  dentro := r.pc is not null and r.pc >= (select coalesce(min(pc), 0) from (
      select qq.pc from public.ranked qq where qq.sea = sea_atual and qq.pc is not null order by qq.pc desc limit 100) t);
  o := public.rk_apply(jsonb_build_object('rank',r.rank,'div',r.div,'pr',r.pr,'pc',to_jsonb(r.pc),'mmr',r.mmr,
        'n',r.n,'w',r.w,'l',r.l,'prot',r.prot,'dprot',r.dprot,'pen',r.pen,'hiRank',r.hirank,'hiDiv',r.hidiv), opp, p_venceu, dentro);
  snovo := o->'st';
  update public.ranked set rank=(snovo->>'rank')::int, div=(snovo->>'div')::int, pr=(snovo->>'pr')::int,
    pc=nullif(snovo->>'pc','')::int, mmr=(snovo->>'mmr')::double precision, n=(snovo->>'n')::int, w=(snovo->>'w')::int,
    l=(snovo->>'l')::int, prot=(snovo->>'prot')::int, dprot=(snovo->>'dprot')::int, pen=(snovo->>'pen')::int,
    hirank=(snovo->>'hiRank')::int, hidiv=(snovo->>'hiDiv')::int, sea=sea_atual, updated_at=now()
  where uid = p_uid;
  insert into public.ranked_log(uid, partida, venceu, pts, antes, forcada) values (p_uid, p_partida, p_venceu, (o->'r'->>'pts')::int, to_jsonb(r), p_forcada);
  return o;
end $$;
revoke all on function public.rk_aplica_em(uuid,text,boolean,double precision,boolean) from public, anon, authenticated;
