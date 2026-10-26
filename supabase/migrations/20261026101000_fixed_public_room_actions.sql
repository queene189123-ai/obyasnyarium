create or replace function public.join_fixed_room(
  p_room_number integer, p_player_id text, p_player_token text, p_name text
) returns public.rooms
language plpgsql security definer set search_path = ''
as $function$
declare v_room public.rooms; v_state jsonb; v_players jsonb; v_name text; v_hash text;
begin
  if p_room_number not between 1 and 3 or length(coalesce(p_player_id,''))=0 or length(coalesce(p_player_token,''))<20 then
    raise exception 'INVALID_PLAYER_CREDENTIALS';
  end if;
  select * into v_room from public.rooms
    where code = lpad((10000+p_room_number)::text,5,'0') and game_state->>'fixed_room'='true'
    for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  v_state:=coalesce(v_room.game_state,'{}'::jsonb);
  v_players:=coalesce(v_state->'players','[]'::jsonb);
  v_hash:=encode(extensions.digest(convert_to(p_player_token,'UTF8'),'sha256'),'hex');
  if exists(select 1 from jsonb_array_elements(v_players) p where p->>'id'=p_player_id) then
    if not exists(select 1 from public.room_players rp where rp.room_id=v_room.id and rp.player_id=p_player_id and rp.token_hash=v_hash) then raise exception 'PLAYER_NOT_AUTHORIZED'; end if;
    return v_room;
  end if;
  if jsonb_array_length(v_players)>=8 then raise exception 'ROOM_FULL'; end if;
  if v_state->>'status' not in ('lobby','') then raise exception 'GAME_ALREADY_STARTED'; end if;
  v_name:=left(coalesce(nullif(trim(p_name),''),'Игрок'),20);
  v_players:=v_players||jsonb_build_array(jsonb_build_object('id',p_player_id,'name',v_name,'score',0,'ready',false));
  v_state:=jsonb_set(v_state,'{players}',v_players,true);
  update public.rooms set game_state=v_state,version=version+1,last_activity_at=now() where id=v_room.id returning * into v_room;
  insert into public.room_players(room_id,player_id,token_hash) values(v_room.id,p_player_id,v_hash);
  return v_room;
end;
$function$;

create or replace function public.set_fixed_room_ready(
  p_room_id bigint, p_player_id text, p_player_token text, p_ready boolean
) returns public.rooms
language plpgsql security definer set search_path = ''
as $function$
declare v_room public.rooms; v_state jsonb; v_players jsonb; v_hash text; v_count integer; v_ready integer;
begin
  v_hash:=encode(extensions.digest(convert_to(p_player_token,'UTF8'),'sha256'),'hex');
  if not exists(select 1 from public.room_players rp where rp.room_id=p_room_id and rp.player_id=p_player_id and rp.token_hash=v_hash) then raise exception 'PLAYER_NOT_AUTHORIZED'; end if;
  select * into v_room from public.rooms where id=p_room_id and game_state->>'fixed_room'='true' for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  v_state:=v_room.game_state; v_players:=coalesce(v_state->'players','[]'::jsonb);
  if v_state->>'status'<>'lobby' then raise exception 'GAME_ALREADY_STARTED'; end if;
  if not exists(select 1 from jsonb_array_elements(v_players) p where p->>'id'=p_player_id) then raise exception 'PLAYER_NOT_IN_ROOM'; end if;
  select jsonb_agg(case when p->>'id'=p_player_id then jsonb_set(p,'{ready}',to_jsonb(coalesce(p_ready,false)),true) else p end order by ord)
  into v_players from jsonb_array_elements(v_players) with ordinality x(p,ord);
  v_count:=jsonb_array_length(v_players);
  select count(*) into v_ready from jsonb_array_elements(v_players) p where coalesce((p->>'ready')::boolean,false);
  v_state:=jsonb_set(v_state,'{players}',v_players,true);
  if v_count>=2 and v_ready=v_count then
    v_state:=jsonb_set(v_state,'{status}','"pass"'::jsonb,true);
    v_state:=jsonb_set(v_state,'{text_mode}','true'::jsonb,true);
    v_state:=jsonb_set(v_state,'{visibility}','"public"'::jsonb,true);
    v_state:=jsonb_set(v_state,'{currentIdx}',to_jsonb(0),true);
    v_state:=jsonb_set(v_state,'{round}','1'::jsonb,true);
    v_state:=jsonb_set(v_state,'{currentWord}','""'::jsonb,true);
    v_state:=jsonb_set(v_state,'{currentLetter}','""'::jsonb,true);
  end if;
  update public.rooms set game_state=v_state,version=version+1,last_activity_at=now() where id=v_room.id returning * into v_room;
  return v_room;
end;
$function$;

create or replace function public.send_fixed_room_message(
  p_room_id bigint, p_player_id text, p_player_token text, p_message text
) returns bigint
language plpgsql security definer set search_path = ''
as $function$
declare v_name text; v_msg text; v_id bigint; v_hash text;
begin
  v_hash:=encode(extensions.digest(convert_to(p_player_token,'UTF8'),'sha256'),'hex');
  if not exists(select 1 from public.room_players rp where rp.room_id=p_room_id and rp.player_id=p_player_id and rp.token_hash=v_hash) then raise exception 'PLAYER_NOT_AUTHORIZED'; end if;
  v_msg:=trim(regexp_replace(coalesce(p_message,''),'\s+',' ','g'));
  if length(v_msg)<1 or length(v_msg)>240 then raise exception 'INVALID_MESSAGE'; end if;
  select p->>'name' into v_name from public.rooms r, jsonb_array_elements(r.game_state->'players') p where r.id=p_room_id and p->>'id'=p_player_id;
  if v_name is null then raise exception 'PLAYER_NOT_IN_ROOM'; end if;
  insert into public.fixed_room_messages(room_id,player_id,player_name,message) values(p_room_id,p_player_id,v_name,v_msg) returning id into v_id;
  delete from public.fixed_room_messages where room_id=p_room_id and id < (select greatest(coalesce(max(id),0)-100,0) from public.fixed_room_messages where room_id=p_room_id);
  return v_id;
end;
$function$;

create or replace function public.get_fixed_room_messages(
  p_room_id bigint, p_player_id text, p_player_token text, p_after_id bigint default 0
) returns table(id bigint,player_id text,player_name text,message text,created_at timestamptz)
language plpgsql security definer set search_path = ''
stable
as $function$
declare v_hash text;
begin
  v_hash:=encode(extensions.digest(convert_to(p_player_token,'UTF8'),'sha256'),'hex');
  if not exists(select 1 from public.room_players rp where rp.room_id=p_room_id and rp.player_id=p_player_id and rp.token_hash=v_hash) then raise exception 'PLAYER_NOT_AUTHORIZED'; end if;
  return query select m.id,m.player_id,m.player_name,m.message,m.created_at from public.fixed_room_messages m where m.room_id=p_room_id and m.id>coalesce(p_after_id,0) order by m.id asc limit 100;
end;
$function$;

create or replace function public.leave_fixed_room(
  p_room_id bigint, p_player_id text, p_player_token text
) returns public.rooms
language plpgsql security definer set search_path = ''
as $function$
declare v_room public.rooms; v_state jsonb; v_players jsonb; v_hash text;
begin
  v_hash:=encode(extensions.digest(convert_to(p_player_token,'UTF8'),'sha256'),'hex');
  if not exists(select 1 from public.room_players rp where rp.room_id=p_room_id and rp.player_id=p_player_id and rp.token_hash=v_hash) then raise exception 'PLAYER_NOT_AUTHORIZED'; end if;
  select * into v_room from public.rooms where id=p_room_id and game_state->>'fixed_room'='true' for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  v_state:=v_room.game_state;
  select coalesce(jsonb_agg(jsonb_set(p,'{ready}','false'::jsonb,true) order by ord),'[]'::jsonb) into v_players
    from jsonb_array_elements(coalesce(v_state->'players','[]'::jsonb)) with ordinality x(p,ord) where p->>'id'<>p_player_id;
  delete from public.room_players where room_id=p_room_id and player_id=p_player_id;
  v_state:=jsonb_set(v_state,'{players}',v_players,true);
  v_state:=jsonb_set(v_state,'{status}','"lobby"'::jsonb,true);
  v_state:=jsonb_set(v_state,'{text_mode}','false'::jsonb,true);
  v_state:=jsonb_set(v_state,'{currentWord}','""'::jsonb,true);
  v_state:=jsonb_set(v_state,'{currentLetter}','""'::jsonb,true);
  if jsonb_array_length(v_players)=0 then
    v_state:=jsonb_set(v_state,'{players}','[]'::jsonb,true);
  end if;
  update public.rooms set game_state=v_state,version=version+1,last_activity_at=now() where id=v_room.id returning * into v_room;
  return v_room;
end;
$function$;

revoke all on function public.join_fixed_room(integer,text,text,text) from public;
revoke all on function public.set_fixed_room_ready(bigint,text,text,boolean) from public;
revoke all on function public.send_fixed_room_message(bigint,text,text,text) from public;
revoke all on function public.get_fixed_room_messages(bigint,text,text,bigint) from public;
revoke all on function public.leave_fixed_room(bigint,text,text) from public;
grant execute on function public.join_fixed_room(integer,text,text,text) to anon,authenticated;
grant execute on function public.set_fixed_room_ready(bigint,text,text,boolean) to anon,authenticated;
grant execute on function public.send_fixed_room_message(bigint,text,text,text) to anon,authenticated;
grant execute on function public.get_fixed_room_messages(bigint,text,text,bigint) to anon,authenticated;
grant execute on function public.leave_fixed_room(bigint,text,text) to anon,authenticated;
