-- Keep the submitted player list exactly aligned with authenticated room membership.
-- This is the final strict state-write guard: no fake, duplicate, missing, or over-capacity players.

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
  v_state_players jsonb;
  v_state_count integer;
  v_member_count integer;
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

  v_state_players := p_game_state->'players';
  v_state_count := jsonb_array_length(v_state_players);

  select count(*)::integer into v_member_count
  from public.room_players
  where room_id = p_room_id;

  if v_state_count < 1 or v_state_count > 20 or v_state_count <> v_member_count then
    raise exception 'INVALID_GAME_STATE';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(v_state_players) as p(value)
    where coalesce(p.value->>'id', '') = ''
       or not exists (
         select 1 from public.room_players rp
         where rp.room_id = p_room_id
           and rp.player_id = p.value->>'id'
       )
  ) then
    raise exception 'INVALID_GAME_STATE';
  end if;

  if exists (
    select p.value->>'id'
    from jsonb_array_elements(v_state_players) as p(value)
    group by p.value->>'id'
    having count(*) > 1
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
