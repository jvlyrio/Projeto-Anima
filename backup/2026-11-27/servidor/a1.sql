-- ===== Opcao A: o servidor guarda o Nivel da Conta e a Maestria =====
-- Chave prog_estrito: 'off' = espelho (o servidor acompanha o que o aparelho manda, como hoje);
-- 'on' = o servidor manda (so partida registrada e terminada da EXP/Maestria; perfis publicos carimbados).
insert into public.cfg(chave, valor) values
  ('prog_estrito','off'), ('prog_dur_min','60'), ('prog_max_hora','30')
on conflict (chave) do nothing;

create table if not exists public.progresso(
  uid uuid primary key references auth.users(id) on delete cascade,
  xp bigint not null default 0,
  mx jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now());
alter table public.progresso enable row level security;
drop policy if exists progresso_meu on public.progresso;
create policy progresso_meu on public.progresso for select to authenticated using (uid = auth.uid());
revoke all on public.progresso from anon, authenticated;
grant select on public.progresso to authenticated;

create table if not exists public.partidas(
  uid uuid not null references auth.users(id) on delete cascade,
  id text not null,
  tipo text not null check (tipo in ('bot','pvp','rk')),
  inicio timestamptz not null default now(),
  fim timestamptz, res text, xp int, mxg jsonb, nota text,
  primary key (uid, id));
create index if not exists partidas_uid_inicio on public.partidas(uid, inicio desc);
create index if not exists partidas_uid_fim on public.partidas(uid, fim desc);
alter table public.partidas enable row level security;
drop policy if exists partidas_minhas on public.partidas;
create policy partidas_minhas on public.partidas for select to authenticated using (uid = auth.uid());
revoke all on public.partidas from anon, authenticated;
grant select on public.partidas to authenticated;

-- as partidas PvP da fila ranqueada: quem sao os dois e o MMR de cada um na hora do casamento
create table if not exists public.rk_pvp(
  partida text primary key, a uuid not null, b uuid not null,
  ma double precision, mb double precision, at timestamptz not null default now());
alter table public.rk_pvp enable row level security;
revoke all on public.rk_pvp from anon, authenticated;

alter table public.ranked_log add column if not exists antes jsonb;
alter table public.ranked_log add column if not exists conflito boolean not null default false;

-- ---------- contas (as mesmas do jogo) ----------
create or replace function public.prog_estrito() returns boolean language sql stable security definer set search_path to 'public' as
$$ select coalesce((select valor = 'on' from public.cfg where chave = 'prog_estrito'), false) $$;
create or replace function public.prog_cfg(k text, d int) returns int language sql stable security definer set search_path to 'public' as
$$ select coalesce((select nullif(regexp_replace(valor,'[^0-9]','','g'),'')::int from public.cfg where chave = k), d) $$;

-- EXP total para ESTAR no nivel n (ctTotal) e o nivel de um total de EXP (ctProg)
create or replace function public.prog_total(n int) returns bigint language sql immutable as
$$ select (100::bigint*(n-1) + 25::bigint*(n-1)*(n-2)/2) $$;
create or replace function public.prog_nivel(p_xp bigint) returns int language plpgsql immutable as $$
declare n int; x bigint := greatest(0, least(coalesce(p_xp,0), 2000000000));
begin
  n := greatest(1, floor((-87.5 + sqrt(7656.25 + 50.0*x)) / 25)::int);   -- chute perto, depois acerta
  while n > 1 and x < public.prog_total(n) loop n := n - 1; end loop;
  while x >= public.prog_total(n+1) loop n := n + 1; end loop;
  return n;
end $$;

-- Maestria: MXAC e nivel (1..10, o 10 pede 5 destaques), destaques que valem e niveis depois do 10
create or replace function public.mx_ac() returns int[] language sql immutable as
$$ select array[0,200,550,1050,1700,2550,3650,5050,6800,9000] $$;
create or replace function public.mx_nivel(pt bigint, dest int) returns int language plpgsql immutable as $$
declare a int[] := public.mx_ac(); n int := 1;
begin
  for i in 2..10 loop if coalesce(pt,0) >= a[i] then n := i; end if; end loop;
  if n >= 10 and coalesce(dest,0) < 5 then n := 9; end if;
  return n;
end $$;
create or replace function public.mx_destnv(r jsonb) returns int language sql immutable as
$$ select case when coalesce((r->>'m10')::int,0) = 1 then 5 else greatest(0, coalesce((r->>'d10')::int,0)) end $$;
create or replace function public.mx_nv(r jsonb) returns int language sql immutable as
$$ select public.mx_nivel(coalesce((r->>'pt')::bigint,0), public.mx_destnv(r)) $$;
create or replace function public.mx_nvinf(r jsonb) returns int language plpgsql immutable as $$
declare n int := public.mx_nv(r); x bigint; k int := 10; p bigint := 2450;
begin
  if n < 10 then return n; end if;
  x := coalesce((r->>'pt')::bigint,0) - 9000;
  while x >= p and k < 100000 loop x := x - p; k := k + 1; p := p + 250; end loop;
  return k;
end $$;

-- um registro de maestria com todos os campos e numeros validos
create or replace function public.mx_rec(r jsonb) returns jsonb language plpgsql immutable as $$
declare o jsonb := '{}'::jsonb; c text; v numeric;
begin
  foreach c in array array['pt','j','v','d','mvp','svp','d10'] loop
    begin v := (r->>c)::numeric; exception when others then v := 0; end;
    o := o || jsonb_build_object(c, greatest(0, least(coalesce(floor(v),0), 900000000))::bigint);
  end loop;
  -- regra antiga do 10 (3 destaques): quem ja era 10 continua no 10
  if r ? 'm10' and jsonb_typeof(r->'m10') = 'number' then
    o := o || jsonb_build_object('m10', case when (r->>'m10')::numeric >= 1 then 1 else 0 end);
  else
    o := o || jsonb_build_object('m10', case when (o->>'pt')::bigint >= 9000
          and (o->>'mvp')::bigint + (o->>'svp')::bigint >= 3 then 1 else 0 end);
  end if;
  return o;
end $$;

-- o progresso que esta no perfil salvo (za_conta / za_mx vao como texto JSON)
create or replace function public.prog_do_perfil(d jsonb, out xp bigint, out mx jsonb) language plpgsql immutable as $$
declare c jsonb; m jsonb; k text;
begin
  xp := 0; mx := '{}'::jsonb;
  begin c := (d->>'za_conta')::jsonb; exception when others then c := null; end;
  begin xp := greatest(0, least(coalesce(floor((c->>'xp')::numeric),0), 2000000000))::bigint; exception when others then xp := 0; end;
  begin m := (d->>'za_mx')::jsonb; exception when others then m := null; end;
  if m is not null and jsonb_typeof(m->'p') = 'object' then
    for k in select jsonb_object_keys(m->'p') loop
      if k ~ '^[a-z0-9]{1,12}$' and jsonb_typeof(m->'p'->k) = 'object' then
        mx := mx || jsonb_build_object(k, public.mx_rec(m->'p'->k));
      end if;
    end loop;
  end if;
end $$;

-- junta dois mapas de maestria campo a campo, ficando com o maior (espelho)
create or replace function public.mx_maior(a jsonb, b jsonb) returns jsonb language plpgsql immutable as $$
declare o jsonb := coalesce(a,'{}'::jsonb); k text; r jsonb; s jsonb; c text;
begin
  for k in select jsonb_object_keys(coalesce(b,'{}'::jsonb)) loop
    s := b->k; r := coalesce(o->k, s);
    foreach c in array array['pt','j','v','d','mvp','svp','d10','m10'] loop
      r := jsonb_set(r, array[c], to_jsonb(greatest(coalesce((r->>c)::bigint,0), coalesce((s->>c)::bigint,0))));
    end loop;
    o := o || jsonb_build_object(k, r);
  end loop;
  return o;
end $$;

-- a linha de progresso da conta (cria se nao houver). No modo espelho vem do perfil salvo;
-- no modo servidor uma conta nova comeca do zero. Quem ja jogou a ranqueada fica no minimo no nivel 10.
create or replace function public.prog_garante(u uuid) returns public.progresso language plpgsql security definer set search_path to 'public' as $$
declare p public.progresso; xp0 bigint := 0; mx0 jsonb := '{}'::jsonb; d jsonb;
begin
  select * into p from public.progresso where uid = u;
  if found then return p; end if;
  if not public.prog_estrito() then
    select data into d from public.profiles where uid = u;
    if d is not null then select x.xp, x.mx into xp0, mx0 from public.prog_do_perfil(d) x; end if;
  end if;
  if exists (select 1 from public.ranked r where r.uid = u and r.n > 0)
     or exists (select 1 from public.ranked_log g where g.uid = u) then
    xp0 := greatest(xp0, public.prog_total(10));
  end if;
  insert into public.progresso(uid, xp, mx) values (u, xp0, mx0) on conflict (uid) do nothing;
  select * into p from public.progresso where uid = u;
  return p;
end $$;

-- o pacote publico de maestria {k:[pontos, destaques do 10, destaques]} (mxPacote)
create or replace function public.mx_pacote(mx jsonb) returns jsonb language sql immutable as $$
  select coalesce(jsonb_object_agg(k, jsonb_build_array((r->>'pt')::bigint, public.mx_destnv(r),
           coalesce((r->>'mvp')::bigint,0) + coalesce((r->>'svp')::bigint,0))), '{}'::jsonb)
  from jsonb_each(coalesce(mx,'{}'::jsonb)) e(k, r)
  where coalesce((r->>'pt')::bigint,0) > 0 or coalesce((r->>'mvp')::bigint,0) + coalesce((r->>'svp')::bigint,0) > 0
$$;

-- carimba o perfil publico com o que o servidor sabe: nivel, maestria, top 3 e ranqueada.
-- Icone, titulo, moldura e fundo que a maestria do servidor nao libera voltam para o padrao.
create or replace function public.prog_pf(u uuid, pf jsonb, completo boolean) returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare p public.progresso; n int; o jsonb := coalesce(pf,'{}'::jsonb); mx jsonb; mxmax int := 0; k text; r jsonb;
        ic text; ti text; fu text; mo text; tk text; tn int; rk public.ranked;
begin
  if jsonb_typeof(o) <> 'object' then return pf; end if;
  p := public.prog_garante(u); mx := coalesce(p.mx,'{}'::jsonb);
  n := public.prog_nivel(p.xp);
  o := o || jsonb_build_object('nv', n);
  for k, r in select * from jsonb_each(mx) loop mxmax := greatest(mxmax, public.mx_nv(r)); end loop;
  ic := coalesce(o->>'ic',''); ti := coalesce(o->>'ti',''); fu := coalesce(o->>'fu',''); mo := coalesce(o->>'mo','pad');
  if ic <> '' and public.mx_nv(coalesce(mx->ic,'{}'::jsonb)) < 2 then o := o || '{"ic":""}'::jsonb; end if;
  if ti <> '' then
    tk := split_part(ti, ':', 1);
    begin tn := split_part(ti, ':', 2)::int; exception when others then tn := 99; end;
    if tn not in (4,8,10) or public.mx_nv(coalesce(mx->tk,'{}'::jsonb)) < tn then o := o || '{"ti":""}'::jsonb; end if;
  end if;
  if fu <> '' and fu not like 'bg\_%' and public.mx_nv(coalesce(mx->fu,'{}'::jsonb)) < 7 then o := o || '{"fu":""}'::jsonb; end if;
  if (mo = 'bronze' and mxmax < 5) or (mo = 'prata' and mxmax < 7) or (mo = 'ouro' and mxmax < 10) then
    o := o || '{"mo":"pad"}'::jsonb;
  end if;
  if completo then
    o := o || jsonb_build_object('no', p.xp - public.prog_total(n), 'passo', 100 + 25*(n-1), 'mx', public.mx_pacote(mx),
      'top', coalesce((select jsonb_agg(jsonb_build_array(t.k, (t.r->>'pt')::bigint, public.mx_nvinf(t.r)) order by (t.r->>'pt')::bigint desc, t.k)
                       from (select e.k, e.r from jsonb_each(mx) e(k, r) where (e.r->>'pt')::bigint > 0
                             order by (e.r->>'pt')::bigint desc, e.k limit 3) t), '[]'::jsonb));
    select * into rk from public.ranked where uid = u;
    if found and rk.n > 0 and rk.sea = public.rk_season() then
      o := o || jsonb_build_object('rk', jsonb_build_object('rank', rk.rank, 'div', rk.div, 'pc', to_jsonb(rk.pc),
             'pos', greatest(0, least(coalesce((o->'rk'->>'pos')::int, 0), 1000000))));
    else
      o := o || '{"rk":null}'::jsonb;
    end if;
  end if;
  return o;
end $$;
