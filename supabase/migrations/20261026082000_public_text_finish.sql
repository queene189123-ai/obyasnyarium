create or replace function public.finish_public_text_game(
  p_room_id bigint, p_player_id text, p_player_token text, p_expected_version bigint
) returns public.rooms
language plpgsql security definer set search_path = ''
as $function$
declare v_room public.rooms; v_state jsonb;
begin
  if not exists (
    select 1 from public.room_players rp
    where rp.room_id=p_room_id and rp.player_id=p_player_id
      and rp.token_hash=encode(extensions.digest(convert_to(p_player_token,'UTF8'),'sha256'),'hex')
  ) then raise exception 'PLAYER_NOT_AUTHORIZED'; end if;
  select * into v_room from public.rooms where id=p_room_id for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  if v_room.version<>p_expected_version then raise exception 'VERSION_CONFLICT'; end if;
  if v_room.host_id<>p_player_id then raise exception 'HOST_ONLY_ACTION'; end if;
  v_state:=coalesce(v_room.game_state,'{}'::jsonb);
  if v_state->>'visibility'<>'public' or coalesce((v_state->>'text_mode')::boolean,false) is not true then
    raise exception 'TEXT_MODE_NOT_ENABLED';
  end if;
  v_state:=jsonb_set(v_state,'{status}','"finished"'::jsonb,true);
  update public.rooms set game_state=v_state,version=version+1,last_activity_at=now()
    where id=p_room_id returning * into v_room;
  return v_room;
end;
$function$;
revoke all on function public.finish_public_text_game(bigint,text,text,bigint) from public;
grant execute on function public.finish_public_text_game(bigint,text,text,bigint) to anon, authenticated;
