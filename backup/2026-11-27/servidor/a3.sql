-- ---------- ranqueada: resultado so de partida registrada, MMR do adversario do servidor e conflito ----------
create or replace function public.rk_resultado(p_partida text, venceu boolean, opp_mmr double precision)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  u uuid := auth.uid(); r public.ranked; sea_atual text := public.rk_season();
  o jsonb; snovo jsonb; rel jsonb; opp double precision; dentro boolean; quantas int;
  est boolean := public.prog_estrito(); q public.partidas; x public.rk_pvp; xok boolean := false;
  outro public.ranked_log; a jsonb;
begin
  if u is null then raise exception 'sem sessao' using errcode = '42501'; end if;
  if p_partida !~ '^rk-[a-z0-9]{1,16}-[a-z0-9]{1,12}$' then
    raise exception 'id de partida invalido' using errcode = '22023';
  end if;

  insert into public.ranked(uid, sea) values (u, sea_atual) on conflict (uid) do nothing;
  select * into r from public.ranked where uid = u for update;
  if r.sea is distinct from sea_atual then r := public.rk_reset(r, sea_atual); end if;

  if exists (select 1 from public.ranked_log g where g.uid = u and g.partida = p_partida) then
    return jsonb_build_object('repetida', true, 'st', to_jsonb(r));
  end if;

  -- partida da fila PvP: so os dois que foram casados
  select * into x from public.rk_pvp where partida = p_partida;
  xok := found;
  if xok and u <> x.a and u <> x.b then
    return jsonb_build_object('repetida', true, 'recusada', true, 'motivo', 'alheia', 'st', to_jsonb(r));
  end if;
  -- modo servidor: a partida precisa ter comecado aqui, com nivel 10, e a vitoria precisa do tempo minimo
  -- (derrota sempre vale: ninguem ganha nada inventando derrota)
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

  -- modo servidor, PvP: os dois dizem que venceram. Ninguem leva: o meu nao entra e o do outro e desfeito.
  if est and xok and venceu then
    select * into outro from public.ranked_log g where g.partida = p_partida and g.uid <> u and g.uid in (x.a, x.b) limit 1;
    if found and outro.venceu then
      insert into public.ranked_log(uid, partida, venceu, pts, antes, conflito) values (u, p_partida, venceu, 0, to_jsonb(r), true);
      update public.ranked_log set conflito = true where uid = outro.uid and partida = p_partida;
      a := outro.antes;
      if a is not null and not exists (select 1 from public.ranked_log g where g.uid = outro.uid and g.at > outro.at) then
        update public.ranked set rank=(a->>'rank')::int, div=(a->>'div')::int, pr=(a->>'pr')::int,
          pc=nullif(a->>'pc','')::int, mmr=(a->>'mmr')::double precision, n=(a->>'n')::int, w=(a->>'w')::int,
          l=(a->>'l')::int, prot=(a->>'prot')::int, dprot=(a->>'dprot')::int, pen=(a->>'pen')::int,
          hirank=(a->>'hirank')::int, hidiv=(a->>'hidiv')::int, updated_at=now()
        where uid = outro.uid and sea = a->>'sea';
      end if;
      return jsonb_build_object('repetida', true, 'recusada', true, 'motivo', 'conflito', 'st', to_jsonb(r));
    end if;
  end if;

  -- o MMR do adversario PvP e o que o servidor anotou no casamento, nao o que o aparelho diz
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

  return jsonb_build_object('repetida', false, 'st', snovo, 'r', rel, 'sea', sea_atual);
end $function$;

create or replace function public.fila_entrar(p_nick text)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  u uuid := auth.uid(); sea_atual text := public.rk_season();
  r public.ranked; eu public.fila; outro public.fila;
  espera double precision; cod text; pid text; nick text;
begin
  if u is null then raise exception 'sem sessao' using errcode = '42501'; end if;
  if not ((public.rk_modo())->>'pvp')::boolean then return jsonb_build_object('estado','desligado'); end if;
  -- modo servidor: a fila ranqueada pede o nivel 10 que o servidor conhece
  if public.prog_estrito() and public.prog_nivel((public.prog_garante(u)).xp) < 10 then
    return jsonb_build_object('estado','nivel');
  end if;
  nick := public.nick_limpo(p_nick);

  select * into eu from public.fila where uid = u;
  if found and eu.sala is null and eu.visto > now() - interval '1 second' then
    return jsonb_build_object('estado','esperando');
  end if;

  insert into public.ranked(uid, sea) values (u, sea_atual) on conflict (uid) do nothing;
  select * into r from public.ranked where uid = u;
  if r.sea is distinct from sea_atual then r := public.rk_reset(r, sea_atual); end if;

  delete from public.fila f where f.sala is null and f.visto < now() - interval '12 seconds';
  delete from public.fila f where f.sala is not null
    and coalesce(f.casou, f.visto) < now() - interval '45 seconds';

  select * into eu from public.fila where uid = u;
  if found and eu.sala is not null then
    select * into outro from public.fila where uid = eu.rival;
    return jsonb_build_object('estado','casado','sala',eu.sala,'partida',eu.partida,
      'rival', jsonb_build_object('nome',coalesce(outro.nick,'Adversário'),'mmr',coalesce(outro.mmr,r.mmr),
        'rank',coalesce(outro.rank,1),'div',coalesce(outro.div,5),'pc',outro.pc));
  end if;

  insert into public.fila(uid, sea, mmr, nick, rank, div, pc)
  values (u, sea_atual, r.mmr, nick, r.rank, r.div, r.pc)
  on conflict (uid) do update set visto = now(), entrou = now(), sala = null, rival = null, partida = null,
    casou = null,
    nick = excluded.nick, mmr = excluded.mmr, rank = excluded.rank, div = excluded.div,
    pc = excluded.pc, sea = excluded.sea;
  select * into eu from public.fila where uid = u;

  select * into outro from public.fila f
   where f.sala is null and f.uid <> u and f.sea = sea_atual
     and f.visto > now() - interval '12 seconds'
     and not public.fila_em_partida(f.uid)
   order by abs(f.mmr - r.mmr) limit 1 for update skip locked;
  if not found then return jsonb_build_object('estado','esperando'); end if;

  espera := greatest(extract(epoch from now() - eu.entrou), extract(epoch from now() - outro.entrou));
  if abs(outro.mmr - r.mmr) > public.fila_banda(espera) then return jsonb_build_object('estado','esperando'); end if;

  pid := 'rk-' || to_char(now(), 'SSMS') || '-' || substr(md5(u::text || outro.uid::text || clock_timestamp()::text), 1, 8);
  cod := public.sala_ranqueada(u, outro.uid, nick, outro.nick, r.rank, r.div, r.pc,
                               outro.rank, outro.div, outro.pc, r.mmr, outro.mmr, pid);
  -- anota quem sao os dois desta partida (o resultado so aceita eles, com estes MMR)
  insert into public.rk_pvp(partida, a, b, ma, mb) values (pid, u, outro.uid, r.mmr, outro.mmr) on conflict do nothing;
  delete from public.rk_pvp where at < now() - interval '30 days';
  update public.fila set sala = cod, rival = outro.uid, partida = pid, visto = now(), casou = now() where uid = u;
  update public.fila set sala = cod, rival = u,        partida = pid, visto = now(), casou = now() where uid = outro.uid;
  return jsonb_build_object('estado','casado','sala',cod,'partida',pid,
    'rival', jsonb_build_object('nome',outro.nick,'mmr',outro.mmr,'rank',outro.rank,'div',outro.div,'pc',outro.pc));
end $function$;
