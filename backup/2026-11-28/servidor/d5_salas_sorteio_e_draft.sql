-- ===== Sorteio das salas e conferencia do draft no servidor (aplicada em 28/11/2026) =====
-- sv: numero sorteado pelo servidor a cada volta da sala para o lobby (e na criacao). Ninguem consegue mudar.
--   bit 0 = quem joga primeiro, bit 1 = quem bane primeiro, o resto = desempate do voto de campo.
-- No comeco da batalha (draft -> battle) o servidor confere o sorteio e os times do draft; se nao bater, recusa.
-- A conferencia so vale com cfg 'salas_sorteio' = 'on' (liga junto com a versao nova do jogo).
create or replace function public.salas_sorteio() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare sv bigint; R jsonb; N jsonb; t int; k text; ban jsonb; vistos text[]; u jsonb; tem boolean;
begin
  if new.parent is distinct from 'rooms' or new.path !~ '^rooms/[A-Za-z0-9]{3,12}$' then return new; end if;
  if new.data is null or jsonb_typeof(new.data) <> 'object' then return new; end if;
  if tg_op = 'INSERT' then
    new.data := new.data || jsonb_build_object('sv', floor(random() * 2147483647)::bigint);
    return new;
  end if;
  if coalesce(new.data->>'ph','') = 'lobby' and coalesce(old.data->>'ph','') <> 'lobby' then
    new.data := new.data || jsonb_build_object('sv', floor(random() * 2147483647)::bigint);
  elsif old.data ? 'sv' then
    new.data := new.data || jsonb_build_object('sv', old.data->'sv');
  else
    new.data := new.data - 'sv';
  end if;
  -- comeco da batalha
  if coalesce(new.data->>'ph','') = 'battle' and coalesce(old.data->>'ph','') = 'draft'
     and (new.data ? 'sv') and coalesce(new.data->>'tx','') = ''
     and coalesce((select valor from public.cfg where chave = 'salas_sorteio'), 'off') = 'on' then
    sv := (new.data->>'sv')::bigint;
    begin R := (new.data->>'dr')::jsonb; N := (new.data->>'st')::jsonb;
    exception when others then raise exception 'draft invalido: estado' using errcode = '22023'; end;
    if R is null or N is null or coalesce(R->>'ph','') <> 'done' then raise exception 'draft invalido: fase' using errcode = '22023'; end if;
    if (N->>'cur')::int is distinct from (sv & 1)::int then raise exception 'draft invalido: quem comeca' using errcode = '22023'; end if;
    if (R->>'bf')::int is distinct from ((sv >> 1) & 1)::int then raise exception 'draft invalido: quem bane' using errcode = '22023'; end if;
    ban := coalesce(R->'bans'->0,'[]'::jsonb) || coalesce(R->'bans'->1,'[]'::jsonb);
    for t in 0..1 loop
      vistos := '{}';
      for k in select jsonb_array_elements_text(coalesce(R->'act'->t,'[]'::jsonb)) loop
        if k = any(vistos) then raise exception 'draft invalido: personagem repetido' using errcode = '22023'; end if;
        vistos := vistos || k;
        if ban ? k then raise exception 'draft invalido: personagem banido' using errcode = '22023'; end if;
        if not (coalesce(R->'picks'->t,'[]'::jsonb) ? k) then raise exception 'draft invalido: personagem fora das escolhas' using errcode = '22023'; end if;
        tem := false;
        for u in select jsonb_array_elements(coalesce(N->'u','[]'::jsonb)) loop
          if u->>'c' = k and (u->>'s')::int = t then tem := true; exit; end if;
        end loop;
        if not tem then raise exception 'draft invalido: time diferente do draft' using errcode = '22023'; end if;
      end loop;
      if coalesce(array_length(vistos,1),0) = 0 then raise exception 'draft invalido: time vazio' using errcode = '22023'; end if;
      k := R->'lead'->>t;
      if k is not null and ban ? k then raise exception 'draft invalido: lider banido' using errcode = '22023'; end if;
    end loop;
  end if;
  return new;
end $$;
revoke all on function public.salas_sorteio() from public, anon, authenticated;
drop trigger if exists salas_sorteio_t on public.docs;
create trigger salas_sorteio_t before insert or update on public.docs for each row execute function public.salas_sorteio();
insert into public.cfg(chave, valor) values ('salas_sorteio','off') on conflict (chave) do nothing;
