-- Enforce room membership and the 20-player cap on every state write.
-- Without server-side checks, a client with a valid token could bypass join_room's cap.

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
  v_player_count integer;
  v_distinct_ids integer;
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

  if jsonb_typeof(p_game_state->'players') is distinct from 'array' then
    raise exception 'INVALID_GAME_STATE';
  end if;

  v_player_count := jsonb_array_length(p_game_state->'players');
  if v_player_count < 1 or v_player_count > 20 then
    raise exception 'INVALID_GAME_STATE';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_game_state->'players') as player(value)
    where coalesce(length(trim(player.value->>'id')), 0) = 0
  ) then
    raise exception 'INVALID_GAME_STATE';
  end if;

  select count(distinct player.value->>'id')
  into v_distinct_ids
  from jsonb_array_elements(p_game_state->'players') as player(value);

  if v_distinct_ids <> v_player_count then
    raise exception 'INVALID_GAME_STATE';
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(p_game_state->'players') as player(value)
    where player.value->>'id' = p_player_id
  ) or not exists (
    select 1
    from jsonb_array_elements(p_game_state->'players') as player(value)
    where player.value->>'id' = v_room.host_id
  ) then
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
