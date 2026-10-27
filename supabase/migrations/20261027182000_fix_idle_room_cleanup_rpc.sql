-- Qualify table columns that overlap with list_fixed_rooms() OUT parameter names.
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
  for v_room in
    select r.id, r.game_state
    from public.rooms r
    where r.code in ('10001','10002','10003')
      and r.game_state->>'fixed_room'='true'
      and coalesce(r.last_activity_at, 'epoch'::timestamptz) < now() - interval '30 minutes'
      and jsonb_array_length(coalesce(r.game_state->'players','[]'::jsonb)) > 0
    for update
  loop
    delete from public.room_players rp where rp.room_id = v_room.id;
    delete from public.fixed_room_messages fm where fm.room_id = v_room.id;
    delete from public.public_text_messages pm where pm.room_id = v_room.id;

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

    update public.rooms r
    set game_state = v_state, version = r.version + 1, last_activity_at = now()
    where r.id = v_room.id;
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
