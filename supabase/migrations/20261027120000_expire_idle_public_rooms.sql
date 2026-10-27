-- Fixed public rooms should not retain abandoned players or chat forever.
-- A browser session is considered active while get_room_state touches last_activity_at.
-- Client-side inactivity expiry also leaves rooms after 30 minutes without user input.

create or replace function public.list_fixed_rooms()
returns table(room_number integer, room_id bigint, player_count integer, players jsonb, status text)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_room record;
  v_state jsonb;
begin
  -- If every browser closed/crashed, the polling heartbeat stops. Clear the
  -- fixed room on the next room-list refresh after 30 minutes without a heartbeat.
  for v_room in
    select r.id, r.game_state
    from public.rooms r
    where r.code in ('10001','10002','10003')
      and r.game_state->>'fixed_room'='true'
      and coalesce(r.last_activity_at, 'epoch'::timestamptz) < now() - interval '30 minutes'
      and jsonb_array_length(coalesce(r.game_state->'players','[]'::jsonb)) > 0
    for update
  loop
    delete from public.room_players where room_id = v_room.id;
    delete from public.fixed_room_messages where room_id = v_room.id;
    delete from public.public_text_messages where room_id = v_room.id;

    v_state := coalesce(v_room.game_state, '{}'::jsonb);
    v_state := jsonb_set(v_state, '{players}', '[]'::jsonb, true);
    v_state := jsonb_set(v_state, '{status}', '"lobby"'::jsonb, true);
    v_state := jsonb_set(v_state, '{text_mode}', 'false'::jsonb, true);
    v_state := jsonb_set(v_state, '{currentIdx}', '0'::jsonb, true);
    v_state := jsonb_set(v_state, '{round}', '1'::jsonb, true);
    v_state := jsonb_set(v_state, '{currentWord}', '""'::jsonb, true);
    v_state := jsonb_set(v_state, '{currentLetter}', '""'::jsonb, true);
    v_state := jsonb_set(v_state, '{usedWords}', '[]'::jsonb, true);
    v_state := v_state - 'selectedGuesserId';

    update public.rooms
    set game_state = v_state,
        version = version + 1,
        last_activity_at = now()
    where id = v_room.id;
  end loop;

  return query
    select
      (r.game_state->>'room_number')::integer,
      r.id,
      jsonb_array_length(coalesce(r.game_state->'players','[]'::jsonb)),
      coalesce(r.game_state->'players','[]'::jsonb),
      coalesce(r.game_state->>'status','lobby')
    from public.rooms r
    where r.code in ('10001','10002','10003')
      and r.game_state->>'fixed_room'='true'
    order by (r.game_state->>'room_number')::integer;
end;
$function$;

revoke all on function public.list_fixed_rooms() from public;
grant execute on function public.list_fixed_rooms() to anon, authenticated;
