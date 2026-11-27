create or replace function public.rk_resultado(p_partida text, venceu boolean, opp_mmr double precision)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  u uuid := auth.uid(); r public.ranked; sea_atual text := public.rk_season();
  o jsonb; snovo jsonb; rel jsonb; opp double precision; dentro boolean; quantas int;
  est boolean := public.prog_estrito(); q public.partidas; x public.rk_pvp; xok boolean := false;
  outro public.ranked_log; g0 public.ranked_log; ou uuid;
begin
  if u is null then raise exception 'sem sessao' using errcode = '42501'; end if;
  if p_partida !~ '^rk-[a-z0-9]{1,16}-[a-z0-9]{1,12}$' then
    raise exception 'id de partida invalido' using errcode = '22023';
  end if;
  insert into public.ranked(uid, sea) values (u, sea_atual) on conflict (uid) do nothing;
  select * into r from public.ranked where uid = u for update;
  if r.sea is distinct from sea_atual then r := public.rk_reset(r, sea_atual); end if;
  select * into x from public.rk_pvp where partida = p_partida;
  xok := found;
  if xok then ou := case when u = x.a then x.b else x.a end; end if;

  select * into g0 from public.ranked_log g where g.uid = u and g.partida = p_partida;
  if found then
    -- a derrota entrou por abandono e agora esta conta diz que venceu: conflito, as duas partes sao desfeitas
    if est and xok and g0.forcada and venceu and not g0.conflito and (u = x.a or u = x.b) then
      perform public.rk_desfaz(u, p_partida); perform public.rk_desfaz(ou, p_partida);
      select * into r from public.ranked where uid = u;
      return jsonb_build_object('repetida', true, 'recusada', true, 'motivo', 'conflito', 'st', to_jsonb(r));
    end if;
    return jsonb_build_object('repetida', true, 'st', to_jsonb(r));
  end if;

  if xok and u <> x.a and u <> x.b then
    return jsonb_build_object('repetida', true, 'recusada', true, 'motivo', 'alheia', 'st', to_jsonb(r));
  end if;
  if est then
    select * into q from public.partidas where uid = u and id = p_partida;
    if not found or q.tipo <> 'rk' then
      return jsonb_build_object('repetida', true, 'recusada', true, 'motivo', 'sem_inicio', 'st', to_jsonb(r));
    end if;
    if venceu and now() - q.inicio < make_interval(secs => public.prog_cfg('prog_dur_min', 60)) then
      return jsonb_build_object('repetida', true, 'recusada', true, 'motivo', 'curta', 'st', to_jsonb(r));
    end if;
    if public.prog_nivel((public.prog_garante(u)).xp) < 10 then
      return jsonb_build_object('repetida', true, 'recusada', true, 'motivo', 'nivel', 'st', to_jsonb(r));
    end if;
  end if;
  if r.ultima is not null and now() - r.ultima < interval '30 seconds' then
    raise exception 'rapido demais' using errcode = '53400';
  end if;
  select count(*) into quantas from public.ranked_log g where g.uid = u and g.at > now() - interval '1 hour';
  if quantas >= 60 then raise exception 'limite por hora' using errcode = '53400'; end if;

  -- os dois dizem que venceram: ninguem leva
  if est and xok and venceu then
    select * into outro from public.ranked_log g where g.partida = p_partida and g.uid = ou;
    if found and outro.venceu then
      insert into public.ranked_log(uid, partida, venceu, pts, antes, conflito) values (u, p_partida, venceu, 0, to_jsonb(r), true);
      perform public.rk_desfaz(ou, p_partida);
      return jsonb_build_object('repetida', true, 'recusada', true, 'motivo', 'conflito', 'st', to_jsonb(r));
    end if;
  end if;

  if xok then opp := case when u = x.a then x.mb else x.ma end; end if;
  opp := public.rk_clamp(coalesce(opp, opp_mmr, r.mmr), greatest(0, r.mmr - 600), r.mmr + 600);
  dentro := r.pc is not null and r.pc >= (
    select coalesce(min(pc), 0) from (
      select qq.pc from public.ranked qq where qq.sea = sea_atual and qq.pc is not null order by qq.pc desc limit 100
    ) t);
  o := public.rk_apply(jsonb_build_object(
        'rank',r.rank,'div',r.div,'pr',r.pr,'pc',to_jsonb(r.pc),'mmr',r.mmr,
        'n',r.n,'w',r.w,'l',r.l,'prot',r.prot,'dprot',r.dprot,'pen',r.pen,
        'hiRank',r.hirank,'hiDiv',r.hidiv), opp, venceu, dentro);
  snovo := o->'st';
  rel := (o->'r') || jsonb_build_object(
    'rankAnt', r.rank, 'divAnt', r.div, 'mmrAnt', r.mmr,
    'prAnt', coalesce(r.pc, r.pr),
    'prDep', coalesce((snovo->>'pc')::int, (snovo->>'pr')::int),
    'protRest', (snovo->>'prot')::int, 'dprotRest', (snovo->>'dprot')::int, 'penTot', (snovo->>'pen')::int);
  update public.ranked set
    rank=(snovo->>'rank')::int, div=(snovo->>'div')::int, pr=(snovo->>'pr')::int,
    pc=nullif(snovo->>'pc','')::int, mmr=(snovo->>'mmr')::double precision,
    n=(snovo->>'n')::int, w=(snovo->>'w')::int, l=(snovo->>'l')::int,
    prot=(snovo->>'prot')::int, dprot=(snovo->>'dprot')::int, pen=(snovo->>'pen')::int,
    hirank=(snovo->>'hiRank')::int, hidiv=(snovo->>'hiDiv')::int,
    sea=sea_atual, t0=r.t0, ultima=now(), updated_at=now()
  where uid = u;
  insert into public.ranked_log(uid, partida, venceu, pts, antes)
  values (u, p_partida, venceu, (rel->>'pts')::int, to_jsonb(r));

  -- modo servidor, PvP: venceu e o outro ainda nao mandou (abandonou): a derrota dele ja entra
  if est and xok and venceu and not exists (select 1 from public.ranked_log g where g.uid = ou and g.partida = p_partida) then
    perform public.rk_aplica_em(ou, p_partida, false, case when u = x.a then x.ma else x.mb end, true);
  end if;

  return jsonb_build_object('repetida', false, 'st', snovo, 'r', rel, 'sea', sea_atual);
end $function$;
