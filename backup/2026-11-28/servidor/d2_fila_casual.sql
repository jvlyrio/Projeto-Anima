-- ===== Fila Casual: PvP sem rank, libera no nivel 5 (aplicada em 28/11/2026) =====
-- So jogadores de verdade aqui; quando ninguem aparece, o jogo encontra um adversario (no aparelho).
create table if not exists public.fila_casual(
  uid uuid primary key references auth.users(id) on delete cascade,
  nick text,
  entrou timestamptz not null default now(),
  visto timestamptz not null default now(),
  sala text, rival uuid, casou timestamptz);
alter table public.fila_casual enable row level security;
drop policy if exists fila_casual_minha on public.fila_casual;
create policy fila_casual_minha on public.fila_casual for select to authenticated using (uid = auth.uid());
revoke all on public.fila_casual from anon, authenticated;
grant select on public.fila_casual to authenticated;

-- a sala casual: uma sala comum ja com os dois jogadores prontos (o draft comeca sozinho)
create or replace function public.sala_casual(a uuid, b uuid, na text, nb text) returns text
language plpgsql set search_path to 'public' as $$
declare cod text; i int := 0;
begin
  loop
    cod := public.sala_codigo(); i := i + 1;
    exit when not exists (select 1 from public.docs where path = 'rooms/' || cod) or i > 12;
  end loop;
  insert into public.docs(path, parent, id, data, owner) values (
    'rooms/' || cod, 'rooms', cod,
    jsonb_build_object(
      'v', 2, 'host', a::text, 'p0', a::text, 'p1', b::text,
      's0', null, 's1', null, 's2', null, 's3', null, 's4', null, 's5', null,
      'mem', jsonb_build_object(
        'm_' || a::text, jsonb_build_object('n', na),
        'm_' || b::text, jsonb_build_object('n', nb)),
      'ru', '{"m":"p"}', 'lr0', true, 'lr1', true,
      'cp0','', 'cp1','', 'cd', 0, 't0','', 't1','', 'r0', false, 'r1', false,
      'fd','r', 'ph','lobby', 'st','', 'seq', 0, 'gid','', 'cs', 1,
      'at', (extract(epoch from now())*1000)::bigint),
    a);
  return cod;
end $$;
revoke all on function public.sala_casual(uuid, uuid, text, text) from public, anon, authenticated;

create or replace function public.fila_casual_entrar(p_nick text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare u uuid := auth.uid(); eu public.fila_casual; outro public.fila_casual; nick text; cod text;
begin
  if u is null then raise exception 'sem sessao' using errcode = '42501'; end if;
  if not public.termos_ok(u) then return jsonb_build_object('estado','termos'); end if;
  if public.prog_estrito() and public.prog_nivel((public.prog_garante(u)).xp) < 5 then
    return jsonb_build_object('estado','nivel');
  end if;
  nick := public.nick_limpo(p_nick);
  select * into eu from public.fila_casual where uid = u;
  if found and eu.sala is null and eu.visto > now() - interval '1 second' then
    return jsonb_build_object('estado','esperando');
  end if;
  delete from public.fila_casual f where f.sala is null and f.visto < now() - interval '12 seconds';
  delete from public.fila_casual f where f.sala is not null and coalesce(f.casou, f.visto) < now() - interval '45 seconds';
  select * into eu from public.fila_casual where uid = u;
  if found and eu.sala is not null then
    select * into outro from public.fila_casual where uid = eu.rival;
    return jsonb_build_object('estado','casado','sala',eu.sala,'rival',jsonb_build_object('nome',coalesce(outro.nick,'Adversário')));
  end if;
  insert into public.fila_casual(uid, nick) values (u, nick)
  on conflict (uid) do update set visto = now(), nick = excluded.nick, sala = null, rival = null, casou = null,
    entrou = case when public.fila_casual.sala is null then public.fila_casual.entrou else now() end;
  select * into outro from public.fila_casual f
   where f.sala is null and f.uid <> u and f.visto > now() - interval '12 seconds'
     and not public.fila_em_partida(f.uid)
   order by f.entrou limit 1 for update skip locked;
  if not found then return jsonb_build_object('estado','esperando'); end if;
  cod := public.sala_casual(outro.uid, u, coalesce(outro.nick,'Jogador'), nick);
  update public.fila_casual set sala = cod, rival = outro.uid, visto = now(), casou = now() where uid = u;
  update public.fila_casual set sala = cod, rival = u, visto = now(), casou = now() where uid = outro.uid;
  return jsonb_build_object('estado','casado','sala',cod,'rival',jsonb_build_object('nome',coalesce(outro.nick,'Adversário')));
end $$;
revoke all on function public.fila_casual_entrar(text) from public, anon;
grant execute on function public.fila_casual_entrar(text) to authenticated;

create or replace function public.fila_casual_sair() returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is null then return; end if;
  delete from public.fila_casual where uid = auth.uid();
end $$;
revoke all on function public.fila_casual_sair() from public, anon;
grant execute on function public.fila_casual_sair() to authenticated;
