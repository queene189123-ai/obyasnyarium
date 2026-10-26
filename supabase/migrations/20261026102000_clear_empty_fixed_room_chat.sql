-- Clear a room's chat when its last participant leaves; the room itself remains reserved.
create or replace function public.leave_fixed_room(
  p_room_id bigint, p_player_id text, p_player_token text
) returns public.rooms
language plpgsql security definer set search_path = ''
as $function$
declare
  v_room public.rooms;
  v_state jsonb;
  v_players jsonb;
  v_hash text;
begin
  v_hash:=encode(extensions.digest(convert_to(p_player_token,'UTF8'),'sha256'),'hex');
  if not exists(
    select 1 from public.room_players rp
    where rp.room_id=p_room_id and rp.player_id=p_player_id and rp.token_hash=v_hash
  ) then
    raise exception 'PLAYER_NOT_AUTHORIZED';
  end if;

  select * into v_room from public.rooms
  where id=p_room_id and game_state->>'fixed_room'='true'
  for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;

  v_state:=v_room.game_state;
  select coalesce(
    jsonb_agg(jsonb_set(p,'{ready}','false'::jsonb,true) order by ord),
    '[]'::jsonb
  ) into v_players
  from jsonb_array_elements(coalesce(v_state->'players','[]'::jsonb))
    with ordinality x(p,ord)
  where p->>'id'<>p_player_id;

  delete from public.room_players where room_id=p_room_id and player_id=p_player_id;
  v_state:=jsonb_set(v_state,'{players}',v_players,true);
  v_state:=jsonb_set(v_state,'{status}','"lobby"'::jsonb,true);
  v_state:=jsonb_set(v_state,'{text_mode}','false'::jsonb,true);
  v_state:=jsonb_set(v_state,'{currentWord}','""'::jsonb,true);
  v_state:=jsonb_set(v_state,'{currentLetter}','""'::jsonb,true);
  v_state:=v_state-'selectedGuesserId';

  if jsonb_array_length(v_players)=0 then
    delete from public.fixed_room_messages where room_id=p_room_id;
    delete from public.public_text_messages where room_id=p_room_id;
    v_state:=jsonb_set(v_state,'{players}','[]'::jsonb,true);
    v_state:=jsonb_set(v_state,'{round}','1'::jsonb,true);
    v_state:=jsonb_set(v_state,'{currentIdx}',to_jsonb(0),true);
    v_state:=jsonb_set(v_state,'{usedWords}','[]'::jsonb,true);
  end if;

  update public.rooms
  set game_state=v_state,version=version+1,last_activity_at=now()
  where id=v_room.id returning * into v_room;
  return v_room;
end;
$function$;

revoke all on function public.leave_fixed_room(bigint,text,text) from public;
grant execute on function public.leave_fixed_room(bigint,text,text) to anon,authenticated;
