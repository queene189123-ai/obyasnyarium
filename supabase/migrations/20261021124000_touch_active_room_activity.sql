-- Keep active rooms alive during polling and player actions.
-- Reads touch activity at most once every five minutes to avoid write amplification.

CREATE OR REPLACE FUNCTION public.get_room_state(
  p_room_id bigint,
  p_player_id text,
  p_player_token text
)
RETURNS public.rooms
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare
  v_room public.rooms;
begin
  if not exists (
    select 1
    from public.room_players rp
    where rp.room_id = p_room_id
      and rp.player_id = p_player_id
      and rp.token_hash = encode(
        extensions.digest(convert_to(p_player_token, 'UTF8'), 'sha256'),
        'hex'
      )
  ) then
    raise exception 'PLAYER_NOT_AUTHORIZED';
  end if;

  select * into v_room
  from public.rooms
  where id = p_room_id;

  if not found then
    raise exception 'ROOM_NOT_FOUND';
  end if;

  if v_room.last_activity_at is null
     or v_room.last_activity_at < now() - interval '5 minutes' then
    update public.rooms
    set last_activity_at = now()
    where id = p_room_id
    returning * into v_room;
  end if;

  return v_room;
end;
$function$;

CREATE OR REPLACE FUNCTION public.join_room(
  p_code text,
  p_player_id text,
  p_player_token text,
  p_name text
)
RETURNS public.rooms
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare
  v_room public.rooms;
  v_state jsonb;
  v_players jsonb;
  v_name text;
  v_token_hash text;
begin
  if coalesce(length(trim(p_player_id)), 0) = 0
     or coalesce(length(p_player_token), 0) < 20 then
    raise exception 'INVALID_PLAYER_CREDENTIALS';
  end if;

  if coalesce(length(trim(p_code)), 0) <> 5
     or p_code !~ '^[0-9]{5}$' then
    raise exception 'INVALID_ROOM_CODE';
  end if;

  select * into v_room
  from public.rooms
  where code = p_code
  for update;

  if not found then
    raise exception 'ROOM_NOT_FOUND';
  end if;

  v_state := coalesce(v_room.game_state, '{}'::jsonb);
  v_players := case
    when jsonb_typeof(v_state->'players') = 'array'
      then v_state->'players'
    else '[]'::jsonb
  end;

  v_token_hash := encode(
    extensions.digest(convert_to(p_player_token, 'UTF8'), 'sha256'),
    'hex'
  );

  if exists (
    select 1
    from jsonb_array_elements(v_players) x
    where x->>'id' = p_player_id
  ) then
    if not exists (
      select 1
      from public.room_players rp
      where rp.room_id = v_room.id
        and rp.player_id = p_player_id
        and rp.token_hash = v_token_hash
    ) then
      raise exception 'PLAYER_NOT_AUTHORIZED';
    end if;

    update public.rooms
    set last_activity_at = now()
    where id = v_room.id
    returning * into v_room;
    return v_room;
  end if;

  if jsonb_array_length(v_players) >= 20 then
    raise exception 'ROOM_FULL';
  end if;

  v_name := left(coalesce(nullif(trim(p_name), ''), 'Игрок'), 24);
  v_players := v_players || jsonb_build_array(
    jsonb_build_object('id', p_player_id, 'name', v_name, 'score', 0)
  );
  v_state := jsonb_set(v_state, '{players}', v_players, true);

  update public.rooms
  set game_state = v_state,
      version = version + 1,
      last_activity_at = now()
  where id = v_room.id
  returning * into v_room;

  insert into public.room_players(room_id, player_id, token_hash)
  values (v_room.id, p_player_id, v_token_hash);

  return v_room;
end;
$function$;

CREATE OR REPLACE FUNCTION public.update_room_state(
  p_room_id bigint,
  p_player_id text,
  p_player_token text,
  p_expected_version bigint,
  p_game_state jsonb
)
RETURNS public.rooms
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare
  v_room public.rooms;
begin
  if not exists (
    select 1
    from public.room_players rp
    where rp.room_id = p_room_id
      and rp.player_id = p_player_id
      and rp.token_hash = encode(
        extensions.digest(convert_to(p_player_token, 'UTF8'), 'sha256'),
        'hex'
      )
  ) then
    raise exception 'PLAYER_NOT_AUTHORIZED';
  end if;

  select * into v_room
  from public.rooms
  where id = p_room_id
  for update;

  if not found then
    raise exception 'ROOM_NOT_FOUND';
  end if;

  if v_room.version <> p_expected_version then
    raise exception 'VERSION_CONFLICT';
  end if;

  if p_game_state is null
     or jsonb_typeof(p_game_state) is distinct from 'object'
     or pg_column_size(p_game_state) > 200000 then
    raise exception 'INVALID_GAME_STATE';
  end if;

  update public.rooms
  set game_state = p_game_state,
      version = version + 1,
      last_activity_at = now()
  where id = p_room_id
  returning * into v_room;

  return v_room;
end;
$function$;

CREATE OR REPLACE FUNCTION public.leave_room(
  p_room_id bigint,
  p_player_id text,
  p_player_token text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare
  v_room public.rooms;
  v_players jsonb;
  v_new_players jsonb;
  v_new_host text;
begin
  if not exists (
    select 1
    from public.room_players rp
    where rp.room_id = p_room_id
      and rp.player_id = p_player_id
      and rp.token_hash = encode(
        extensions.digest(convert_to(p_player_token, 'UTF8'), 'sha256'),
        'hex'
      )
  ) then
    raise exception 'PLAYER_NOT_AUTHORIZED';
  end if;

  select * into v_room
  from public.rooms
  where id = p_room_id
  for update;

  if not found then
    return true;
  end if;

  v_players := case
    when jsonb_typeof(v_room.game_state->'players') = 'array'
      then v_room.game_state->'players'
    else '[]'::jsonb
  end;

  select coalesce(
    jsonb_agg(x.value order by x.ordinality),
    '[]'::jsonb
  )
  into v_new_players
  from jsonb_array_elements(v_players)
    with ordinality as x(value, ordinality)
  where x.value->>'id' <> p_player_id;

  delete from public.room_players
  where room_id = p_room_id
    and player_id = p_player_id;

  if jsonb_array_length(v_new_players) = 0 then
    delete from public.rooms where id = p_room_id;
    return true;
  end if;

  v_new_host := v_room.host_id;
  if v_new_host = p_player_id then
    v_new_host := v_new_players->0->>'id';
  end if;

  update public.rooms
  set game_state = jsonb_set(
        coalesce(v_room.game_state, '{}'::jsonb),
        '{players}', v_new_players, true
      ),
      host_id = v_new_host,
      version = version + 1,
      last_activity_at = now()
  where id = p_room_id;

  return true;
end;
$function$;
