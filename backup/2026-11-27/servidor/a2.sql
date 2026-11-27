-- ---------- espelho e carimbo: perfil salvo, documentos publicos ----------
-- perfil salvo (profiles.data): no espelho, o servidor acompanha o maior valor;
-- no modo servidor, za_conta.xp e za_mx.p saem da tabela progresso (o aparelho nao escolhe)
create or replace function public.prog_profiles() returns trigger language plpgsql security definer set search_path to 'public' as $$
declare x bigint; m jsonb; p public.progresso; c jsonb; mm jsonb; np jsonb := '{}'::jsonb; k text; r jsonb; ant jsonb;
begin
  if new.data is null or jsonb_typeof(new.data) <> 'object' then return new; end if;
  if not public.prog_estrito() then
    if new.data ? 'za_conta' or new.data ? 'za_mx' then
      select d.xp, d.mx into x, m from public.prog_do_perfil(new.data) d;
      insert into public.progresso(uid, xp, mx) values (new.uid, x, m)
      on conflict (uid) do update set xp = greatest(public.progresso.xp, excluded.xp),
        mx = public.mx_maior(public.progresso.mx, excluded.mx), updated_at = now();
    end if;
    return new;
  end if;
  p := public.prog_garante(new.uid);
  if new.data ? 'za_conta' then
    begin c := (new.data->>'za_conta')::jsonb; exception when others then c := null; end;
    if c is null or jsonb_typeof(c) <> 'object' then c := '{}'::jsonb; end if;
    c := c || jsonb_build_object('xp', p.xp);
    new.data := new.data || jsonb_build_object('za_conta', c::text);
  end if;
  if new.data ? 'za_mx' then
    begin mm := (new.data->>'za_mx')::jsonb; exception when others then mm := null; end;
    if mm is null or jsonb_typeof(mm) <> 'object' then mm := '{"v":1,"g":[]}'::jsonb; end if;
    for k, r in select * from jsonb_each(coalesce(p.mx,'{}'::jsonb)) loop
      ant := case when jsonb_typeof(mm->'p'->k) = 'object' then mm->'p'->k else '{}'::jsonb end;
      np := np || jsonb_build_object(k, (ant - 'pt' - 'j' - 'v' - 'd' - 'mvp' - 'svp' - 'd10' - 'm10') || r);
    end loop;
    new.data := new.data || jsonb_build_object('za_mx', (mm || jsonb_build_object('p', np))::text);
  end if;
  return new;
end $$;
drop trigger if exists prog_profiles_t on public.profiles;
create trigger prog_profiles_t before insert or update on public.profiles for each row execute function public.prog_profiles();

-- documentos publicos (modo servidor): players/<uid> e pres/<uid> (pf), salas (mem.m_<uid>.pf e .mx)
-- e maestria/<chave> (p). Roda depois de docs_keep_owner (ordem alfabetica), entao o dono ja e o certo.
create or replace function public.prog_docs() returns trigger language plpgsql security definer set search_path to 'public' as $$
declare k text; v jsonb; u uuid; mem jsonb; ant jsonb; mudou boolean := false; p public.progresso;
begin
  if new.data is null or jsonb_typeof(new.data) <> 'object' then return new; end if;
  if new.parent not in ('players','pres','rooms','maestria') then return new; end if;
  if not public.prog_estrito() then return new; end if;
  if new.parent in ('players','pres') then
    if new.data ? 'pf' and new.owner is not null then
      new.data := new.data || jsonb_build_object('pf', public.prog_pf(new.owner, new.data->'pf', new.parent = 'players'));
    end if;
    return new;
  end if;
  if new.parent = 'maestria' then
    if new.owner is not null then
      p := public.prog_garante(new.owner);
      new.data := new.data || jsonb_build_object('p', coalesce(p.mx,'{}'::jsonb));
    end if;
    return new;
  end if;
  -- sala: so os membros que mudaram nesta escrita
  mem := new.data->'mem';
  if mem is null or jsonb_typeof(mem) <> 'object' then return new; end if;
  ant := case when tg_op = 'UPDATE' then old.data->'mem' else null end;
  if ant is not null and ant = mem then return new; end if;
  for k, v in select * from jsonb_each(mem) loop
    continue when k !~ '^m_[0-9a-f]{8}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{12}$';
    continue when jsonb_typeof(v) <> 'object';
    continue when ant is not null and ant->k = v;
    u := replace(substr(k, 3), '_', '-')::uuid;
    continue when not exists (select 1 from auth.users where id = u);
    if v ? 'pf' then v := v || jsonb_build_object('pf', public.prog_pf(u, v->'pf', false)); end if;
    if v ? 'mx' then p := public.prog_garante(u); v := v || jsonb_build_object('mx', public.mx_pacote(p.mx)); end if;
    mem := mem || jsonb_build_object(k, v); mudou := true;
  end loop;
  if mudou then new.data := new.data || jsonb_build_object('mem', mem); end if;
  return new;
end $$;
drop trigger if exists prog_docs_t on public.docs;
create trigger prog_docs_t before insert or update on public.docs for each row execute function public.prog_docs();

-- ---------- o jogo conversa com o servidor por estas tres ----------
-- o meu progresso (o jogo troca a copia local por este quando o servidor manda)
create or replace function public.prog_meu() returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u uuid := auth.uid(); p public.progresso;
begin
  if u is null then raise exception 'sem sessao' using errcode = '42501'; end if;
  p := public.prog_garante(u);
  return jsonb_build_object('estrito', public.prog_estrito(), 'xp', p.xp, 'nv', public.prog_nivel(p.xp), 'mx', p.mx,
    'dur', public.prog_cfg('prog_dur_min', 60));
end $$;

-- comeco de partida: o relogio do servidor marca a hora. tipo: bot (contra o computador
-- ou dois no mesmo aparelho), pvp (sala online) ou rk (fila ranqueada)
create or replace function public.partida_iniciar(p_id text, p_tipo text) returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u uuid := auth.uid(); n int; x public.rk_pvp; q public.partidas;
begin
  if u is null then raise exception 'sem sessao' using errcode = '42501'; end if;
  if p_id is null or p_id !~ '^[A-Za-z0-9:_-]{4,64}$' then raise exception 'id de partida invalido' using errcode = '22023'; end if;
  if p_tipo not in ('bot','pvp','rk') then raise exception 'tipo invalido' using errcode = '22023'; end if;
  select * into q from public.partidas where uid = u and id = p_id;
  if found then return jsonb_build_object('ok', true, 'ja', true); end if;
  if p_tipo = 'rk' then
    if p_id !~ '^rk-[a-z0-9]{1,16}-[a-z0-9]{1,12}$' then raise exception 'id de partida invalido' using errcode = '22023'; end if;
    select * into x from public.rk_pvp where partida = p_id;
    if found and u <> x.a and u <> x.b then return jsonb_build_object('ok', false, 'motivo', 'alheia'); end if;
    if public.prog_estrito() and public.prog_nivel((public.prog_garante(u)).xp) < 10 then
      return jsonb_build_object('ok', false, 'motivo', 'nivel');
    end if;
  end if;
  select count(*) into n from public.partidas where uid = u and inicio > now() - interval '1 hour';
  if n >= 120 then return jsonb_build_object('ok', false, 'motivo', 'limite'); end if;
  insert into public.partidas(uid, id, tipo) values (u, p_id, p_tipo) on conflict do nothing;
  delete from public.partidas where uid = u and inicio < now() - interval '30 days';
  return jsonb_build_object('ok', true);
end $$;

-- fim de partida: o servidor confere (comecou aqui, durou o minimo, ainda nao foi paga, limite por hora)
-- e faz as contas da EXP (275/195) e da Maestria (so ranqueada: 90/55 + 35 MVP ou 25 SVP), as mesmas do jogo.
-- p_res: v (venceu), d (perdeu), e (empate: EXP de derrota, sem Maestria)
create or replace function public.partida_fim(p_id text, p_res text, p_time text[], p_dest jsonb) returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u uuid := auth.uid(); q public.partidas; p public.progresso; dur int := public.prog_cfg('prog_dur_min', 60);
        mh int := public.prog_cfg('prog_max_hora', 30); n int; ganho int; base int; vmx jsonb; r jsonb; k text;
        vistos text[] := '{}'; mvp text; svp text; eM int; eS int; noMax boolean; g int; vmxg jsonb := '{}'::jsonb;
        motivo text := null;
begin
  if u is null then raise exception 'sem sessao' using errcode = '42501'; end if;
  if p_res not in ('v','d','e') then raise exception 'resultado invalido' using errcode = '22023'; end if;
  p := public.prog_garante(u);
  select * into q from public.partidas where uid = u and id = p_id for update;
  if not found then motivo := 'sem_inicio';
  elsif q.fim is not null then motivo := 'repetida';
  elsif now() - q.inicio < make_interval(secs => dur) then motivo := 'curta';
  else
    select count(*) into n from public.partidas where uid = u and fim > now() - interval '1 hour' and coalesce(xp,0) > 0;
    if n >= mh then motivo := 'limite'; end if;
  end if;
  if motivo is not null then
    if q.id is not null and q.fim is null then update public.partidas set fim = now(), res = p_res, xp = 0, nota = motivo where uid = u and id = p_id; end if;
    return jsonb_build_object('valeu', false, 'motivo', motivo, 'estrito', public.prog_estrito(), 'xp', p.xp, 'nv', public.prog_nivel(p.xp), 'mx', p.mx);
  end if;

  ganho := case when p_res = 'v' then 275 else 195 end;
  vmx := coalesce(p.mx, '{}'::jsonb);
  if q.tipo = 'rk' and p_res in ('v','d') and p_time is not null then
    base := case when p_res = 'v' then 90 else 55 end;
    mvp := nullif(p_dest->>'mvp',''); svp := nullif(p_dest->>'svp','');
    -- MVP sai do time que venceu e SVP do que perdeu: cada lado so pode ter um dos dois
    if p_res = 'v' then svp := null; else mvp := null; end if;
    foreach k in array p_time loop
      continue when k is null or k !~ '^[a-z0-9]{1,12}$' or k = any(vistos);
      exit when coalesce(array_length(vistos,1),0) >= 4;
      vistos := vistos || k;
    end loop;
    if mvp is not null and not (mvp = any(vistos)) then mvp := null; end if;
    if svp is not null and not (svp = any(vistos)) then svp := null; end if;
    foreach k in array vistos loop
      r := public.mx_rec(coalesce(vmx->k, '{"m10":0}'::jsonb));
      noMax := (r->>'pt')::bigint >= 9000;
      eM := case when k = mvp then 1 else 0 end;
      eS := case when eM = 0 and k = svp then 1 else 0 end;
      g := base + 35*eM + 25*eS;
      r := r || jsonb_build_object('pt', (r->>'pt')::bigint + g, 'j', (r->>'j')::bigint + 1,
            'v', (r->>'v')::bigint + case when p_res = 'v' then 1 else 0 end,
            'd', (r->>'d')::bigint + case when p_res = 'd' then 1 else 0 end,
            'mvp', (r->>'mvp')::bigint + eM, 'svp', (r->>'svp')::bigint + eS,
            'd10', (r->>'d10')::bigint + case when noMax and (eM + eS) > 0 then 1 else 0 end);
      vmx := vmx || jsonb_build_object(k, r);
      vmxg := vmxg || jsonb_build_object(k, g);
    end loop;
  end if;
  update public.progresso set xp = least(xp + ganho, 2000000000), mx = vmx, updated_at = now() where uid = u
    returning * into p;
  update public.partidas set fim = now(), res = p_res, xp = ganho, mxg = vmxg where uid = u and id = p_id;
  return jsonb_build_object('valeu', true, 'ganho', ganho, 'mxg', vmxg, 'estrito', public.prog_estrito(),
    'xp', p.xp, 'nv', public.prog_nivel(p.xp), 'mx', p.mx);
end $$;

revoke all on function public.prog_meu() from public, anon;
revoke all on function public.partida_iniciar(text,text) from public, anon;
revoke all on function public.partida_fim(text,text,text[],jsonb) from public, anon;
grant execute on function public.prog_meu() to authenticated;
grant execute on function public.partida_iniciar(text,text) to authenticated;
grant execute on function public.partida_fim(text,text,text[],jsonb) to authenticated;
-- as de dentro nao sao chamadas pelo jogo
revoke all on function public.prog_garante(uuid) from public, anon, authenticated;
revoke all on function public.prog_pf(uuid,jsonb,boolean) from public, anon, authenticated;
revoke all on function public.prog_profiles() from public, anon, authenticated;
revoke all on function public.prog_docs() from public, anon, authenticated;

-- semente: todo perfil salvo vira uma linha (o mesmo que esta la hoje)
insert into public.progresso(uid, xp, mx)
select pr.uid, d.xp, d.mx from public.profiles pr cross join lateral public.prog_do_perfil(pr.data) d
where exists (select 1 from auth.users au where au.id = pr.uid)
on conflict (uid) do nothing;
