-- Validate initial room state on the server just like later state updates.
-- This prevents anonymous clients from creating oversized or malformed room payloads.

CREATE OR REPLACE FUNCTION public.create_room(
  p_code text,
  p_player_id text,
  p_player_token text,
  p_name text,
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
  if coalesce(length(trim(p_code)), 0) <> 5
     or p_code !~ '^[0-9]{5}$' then
    raise exception 'INVALID_ROOM_CODE';
  end if;

  if coalesce(length(trim(p_player_id)), 0) = 0
     or coalesce(length(p_player_token), 0) < 20 then
    raise exception 'INVALID_PLAYER_CREDENTIALS';
  end if;

  if p_game_state is null
     or jsonb_typeof(p_game_state) <> 'object'
     or pg_column_size(p_game_state) > 200000 then
    raise exception 'INVALID_GAME_STATE';
  end if;

  if jsonb_typeof(p_game_state->'players') <> 'array'
     or jsonb_array_length(p_game_state->'players') <> 1
     or p_game_state->'players'->0->>'id' <> p_player_id then
    raise exception 'INVALID_GAME_STATE';
  end if;

  insert into public.rooms(code, host_id, game_state, version)
  values (p_code, p_player_id, p_game_state, 0)
  returning * into v_room;

  insert into public.room_players(room_id, player_id, token_hash)
  values (
    v_room.id,
    p_player_id,
    encode(
      extensions.digest(convert_to(p_player_token, 'UTF8'), 'sha256'),
      'hex'
    )
  );

  return v_room;
exception when unique_violation then
  raise exception 'ROOM_CODE_ALREADY_EXISTS';
end;
$function$;
