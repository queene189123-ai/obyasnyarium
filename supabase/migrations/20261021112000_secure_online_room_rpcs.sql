-- Security hardening for the public online-room RPC API.
-- Applied to the production Supabase project on 2026-10-21.
-- Anonymous browser clients still need EXECUTE; authenticated and PUBLIC do not.

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

  -- Player IDs are visible in the lobby; require the existing secret token.
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
    return v_room;
  end if;

  if jsonb_array_length(v_players) >= 20 then
    raise exception 'ROOM_FULL';
  end if;

  v_name := left(
    coalesce(nullif(trim(p_name), ''), 'Игрок'),
    24
  );

  v_players := v_players || jsonb_build_array(
    jsonb_build_object('id', p_player_id, 'name', v_name, 'score', 0)
  );

  v_state := jsonb_set(v_state, '{players}', v_players, true);

  update public.rooms
  set game_state = v_state,
      version = version + 1
  where id = v_room.id
  returning * into v_room;

  insert into public.room_players(room_id, player_id, token_hash)
  values (v_room.id, p_player_id, v_token_hash);

  return v_room;
end;
$function$;

REVOKE EXECUTE ON FUNCTION public.create_room(text, text, text, text, jsonb) FROM PUBLIC, authenticated;
REVOKE EXECUTE ON FUNCTION public.join_room(text, text, text, text) FROM PUBLIC, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_room_state(bigint, text, text) FROM PUBLIC, authenticated;
REVOKE EXECUTE ON FUNCTION public.update_room_state(bigint, text, text, bigint, jsonb) FROM PUBLIC, authenticated;
REVOKE EXECUTE ON FUNCTION public.leave_room(bigint, text, text) FROM PUBLIC, authenticated;

GRANT EXECUTE ON FUNCTION public.create_room(text, text, text, text, jsonb) TO anon, service_role;
GRANT EXECUTE ON FUNCTION public.join_room(text, text, text, text) TO anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_room_state(bigint, text, text) TO anon, service_role;
GRANT EXECUTE ON FUNCTION public.update_room_state(bigint, text, text, bigint, jsonb) TO anon, service_role;
GRANT EXECUTE ON FUNCTION public.leave_room(bigint, text, text) TO anon, service_role;
