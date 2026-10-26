-- Text mode for public rooms: server-side chat validation and answer detection.
create table if not exists public.public_text_messages (
  id bigint generated always as identity primary key,
  room_id bigint not null references public.rooms(id) on delete cascade,
  player_id text not null,
  player_name text not null,
  message text not null,
  message_type text not null default 'chat' check (message_type in ('chat','correct','system')),
  created_at timestamptz not null default now()
);
create index if not exists public_text_messages_room_id_id_idx
  on public.public_text_messages(room_id, id);
alter table public.public_text_messages enable row level security;
revoke all on public.public_text_messages from anon, authenticated, public;

create or replace function public.get_public_text_messages(
  p_room_id bigint, p_player_id text, p_player_token text, p_after_id bigint default 0
) returns table (
  id bigint, player_id text, player_name text, message text, message_type text, created_at timestamptz
)
language plpgsql security definer set search_path = ''
stable
as $function$
begin
  if not exists (
    select 1 from public.room_players rp
    where rp.room_id=p_room_id and rp.player_id=p_player_id
      and rp.token_hash=encode(extensions.digest(convert_to(p_player_token,'UTF8'),'sha256'),'hex')
  ) then raise exception 'PLAYER_NOT_AUTHORIZED'; end if;
  return query
    select m.id,m.player_id,m.player_name,m.message,m.message_type,m.created_at
    from public.public_text_messages m
    where m.room_id=p_room_id and m.id>coalesce(p_after_id,0)
    order by m.id asc limit 100;
end;
$function$;

create or replace function public.send_public_text_message(
  p_room_id bigint, p_player_id text, p_player_token text, p_message text
) returns jsonb
language plpgsql security definer set search_path = ''
as $function$
declare
  v_room public.rooms;
  v_state jsonb;
  v_players jsonb;
  v_idx integer;
  v_current_id text;
  v_word text;
  v_letter text;
  v_msg text;
  v_norm_msg text;
  v_norm_word text;
  v_name text;
  v_message_id bigint;
  v_guesser_score numeric;
  v_explainer_score numeric;
  v_now timestamptz := now();
begin
  if not exists (
    select 1 from public.room_players rp
    where rp.room_id=p_room_id and rp.player_id=p_player_id
      and rp.token_hash=encode(extensions.digest(convert_to(p_player_token,'UTF8'),'sha256'),'hex')
  ) then raise exception 'PLAYER_NOT_AUTHORIZED'; end if;

  select * into v_room from public.rooms where id=p_room_id for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  v_state := coalesce(v_room.game_state,'{}'::jsonb);
  if v_state->>'visibility' <> 'public' or coalesce((v_state->>'text_mode')::boolean,false) is not true then
    raise exception 'TEXT_MODE_NOT_ENABLED';
  end if;
  if v_state->>'status' <> 'word' then raise exception 'ROUND_NOT_ACTIVE'; end if;

  v_players := v_state->'players';
  v_idx := coalesce((v_state->>'currentIdx')::integer,0);
  if jsonb_typeof(v_players) is distinct from 'array' or v_idx<0 or v_idx>=jsonb_array_length(v_players) then
    raise exception 'INVALID_GAME_STATE';
  end if;
  v_current_id := v_players->v_idx->>'id';
  v_word := coalesce(v_state->>'currentWord','');
  v_letter := upper(left(trim(coalesce(v_state->>'currentLetter','')),1));
  v_msg := trim(regexp_replace(coalesce(p_message,''), '\\s+', ' ', 'g'));
  if v_msg='' then raise exception 'EMPTY_MESSAGE'; end if;
  if length(v_msg)>80 then raise exception 'MESSAGE_TOO_LONG'; end if;
  if v_word='' or v_letter='' then raise exception 'ROUND_NOT_READY'; end if;

  if p_player_id = v_current_id then
    if upper(left(v_msg,1)) <> v_letter then raise exception 'WRONG_LETTER'; end if;
    v_norm_msg := lower(regexp_replace(v_msg,'[^[:alnum:]А-Яа-яЁё]','','g'));
    v_norm_word := lower(regexp_replace(v_word,'[^[:alnum:]А-Яа-яЁё]','','g'));
    if v_norm_msg = v_norm_word then raise exception 'CANNOT_SEND_ANSWER'; end if;
    if length(v_msg)>80 then raise exception 'MESSAGE_TOO_LONG'; end if;
    if (select count(*) from public.public_text_messages m
        where m.room_id=p_room_id and m.player_id=p_player_id and m.created_at>v_now-interval '3 seconds')>=4 then
      raise exception 'RATE_LIMITED';
    end if;
  else
    if length(v_msg)>50 then raise exception 'GUESS_TOO_LONG'; end if;
    if (select count(*) from public.public_text_messages m
        where m.room_id=p_room_id and m.player_id=p_player_id and m.created_at>v_now-interval '3 seconds')>=5 then
      raise exception 'RATE_LIMITED';
    end if;
  end if;

  select coalesce(p->>'name','Игрок') into v_name
  from jsonb_array_elements(v_players) p where p->>'id'=p_player_id;
  if v_name is null then raise exception 'PLAYER_NOT_IN_ROOM'; end if;

  v_norm_msg := lower(regexp_replace(v_msg,'[^[:alnum:]А-Яа-яЁё]','','g'));
  v_norm_word := lower(regexp_replace(v_word,'[^[:alnum:]А-Яа-яЁё]','','g'));
  if p_player_id <> v_current_id and v_norm_msg = v_norm_word then
    update public.rooms
    set game_state = jsonb_set(
      jsonb_set(
        jsonb_set(v_state,'{players}',(
          select jsonb_agg(
            case when p->>'id'=p_player_id
              then jsonb_set(p,'{score}',to_jsonb(coalesce((p->>'score')::numeric,0)+1),true)
              when p->>'id'=v_current_id
              then jsonb_set(p,'{score}',to_jsonb(coalesce((p->>'score')::numeric,0)+1),true)
              else p end order by ord
          ) from jsonb_array_elements(v_players) with ordinality as x(p,ord)
        ),true),
        '{status}','"text_result"'::jsonb,true
      ),
      '{selectedGuesserId}',to_jsonb(p_player_id),true
    ),
    version=version+1,last_activity_at=v_now
    where id=p_room_id;
    insert into public.public_text_messages(room_id,player_id,player_name,message,message_type)
    values(p_room_id,p_player_id,v_name,v_msg,'correct') returning id into v_message_id;
    insert into public.public_text_messages(room_id,player_id,player_name,message,message_type)
    values(p_room_id,'system','Объясняриум',v_name||' угадал слово «'||v_word||'»!','system');
    return jsonb_build_object('correct',true,'message_id',v_message_id,'answer',v_word);
  end if;

  insert into public.public_text_messages(room_id,player_id,player_name,message,message_type)
  values(p_room_id,p_player_id,v_name,v_msg,'chat') returning id into v_message_id;
  update public.rooms set last_activity_at=v_now where id=p_room_id;
  return jsonb_build_object('correct',false,'message_id',v_message_id);
end;
$function$;

create or replace function public.advance_public_text_round(
  p_room_id bigint, p_player_id text, p_player_token text,
  p_expected_version bigint, p_word text, p_letter text
) returns public.rooms
language plpgsql security definer set search_path = ''
as $function$
declare v_room public.rooms; v_state jsonb; v_players jsonb; v_idx integer; v_current_id text;
begin
  if not exists (
    select 1 from public.room_players rp
    where rp.room_id=p_room_id and rp.player_id=p_player_id
      and rp.token_hash=encode(extensions.digest(convert_to(p_player_token,'UTF8'),'sha256'),'hex')
  ) then raise exception 'PLAYER_NOT_AUTHORIZED'; end if;
  select * into v_room from public.rooms where id=p_room_id for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  if v_room.version<>p_expected_version then raise exception 'VERSION_CONFLICT'; end if;
  v_state:=coalesce(v_room.game_state,'{}'::jsonb); v_players:=v_state->'players';
  if v_state->>'visibility'<>'public' or coalesce((v_state->>'text_mode')::boolean,false) is not true then
    raise exception 'TEXT_MODE_NOT_ENABLED';
  end if;
  if v_state->>'status' not in ('pass','text_result') then raise exception 'INVALID_TEXT_TRANSITION'; end if;
  v_idx:=coalesce((v_state->>'currentIdx')::integer,0);
  if jsonb_typeof(v_players) is distinct from 'array' or v_idx<0 or v_idx>=jsonb_array_length(v_players) then raise exception 'INVALID_GAME_STATE'; end if;
  v_current_id:=v_players->v_idx->>'id';
  if p_player_id<>v_current_id and p_player_id<>v_room.host_id then raise exception 'NOT_YOUR_TURN'; end if;
  if coalesce(length(trim(p_word)),0)=0 or length(p_word)>100 then raise exception 'INVALID_WORD'; end if;
  if upper(left(trim(coalesce(p_letter,'')),1)) not in ('Б','В','Д','И','М','Н','О','П','Т','У') then raise exception 'INVALID_LETTER'; end if;
  if upper(left(trim(p_word),1))=upper(left(trim(p_letter),1)) then raise exception 'LETTER_MUST_DIFFER_FROM_ANSWER'; end if;
  if v_state->>'status'='text_result' then
    v_idx:=(v_idx+1)%jsonb_array_length(v_players);
    if v_idx=0 then v_state:=jsonb_set(v_state,'{round}',to_jsonb(coalesce((v_state->>'round')::integer,1)+1),true); end if;
    v_state:=jsonb_set(v_state,'{currentIdx}',to_jsonb(v_idx),true);
  end if;
  v_state:=jsonb_set(v_state,'{currentWord}',to_jsonb(trim(p_word)),true);
  v_state:=jsonb_set(v_state,'{currentLetter}',to_jsonb(upper(left(trim(p_letter),1))),true);
  v_state:=jsonb_set(v_state,'{status}','"word"'::jsonb,true);
  v_state:=v_state-'selectedGuesserId';
  update public.rooms set game_state=v_state,version=version+1,last_activity_at=now() where id=p_room_id returning * into v_room;
  return v_room;
end;
$function$;

create or replace function public.get_room_state(p_room_id bigint, p_player_id text, p_player_token text)
returns public.rooms
language plpgsql security definer set search_path = ''
as $function$
declare v_room public.rooms;
begin
  if not exists (
    select 1 from public.room_players rp
    where rp.room_id=p_room_id and rp.player_id=p_player_id
      and rp.token_hash=encode(extensions.digest(convert_to(p_player_token,'UTF8'),'sha256'),'hex')
  ) then raise exception 'PLAYER_NOT_AUTHORIZED'; end if;
  select * into v_room from public.rooms where id=p_room_id;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  if v_room.game_state->>'visibility'='public'
     and coalesce((v_room.game_state->>'text_mode')::boolean,false) is true
     and v_room.game_state->>'status'='word' then
    if (v_room.game_state->'players'->coalesce((v_room.game_state->>'currentIdx')::integer,0)->>'id') is distinct from p_player_id then
      v_room.game_state:=jsonb_set(v_room.game_state,'{currentWord}','""'::jsonb,true);
    end if;
  end if;
  if v_room.last_activity_at is null or v_room.last_activity_at<now()-interval '5 minutes' then
    update public.rooms set last_activity_at=now() where id=p_room_id returning * into v_room;
    if v_room.game_state->>'visibility'='public'
       and coalesce((v_room.game_state->>'text_mode')::boolean,false) is true
       and v_room.game_state->>'status'='word'
       and (v_room.game_state->'players'->coalesce((v_room.game_state->>'currentIdx')::integer,0)->>'id') is distinct from p_player_id then
      v_room.game_state:=jsonb_set(v_room.game_state,'{currentWord}','""'::jsonb,true);
    end if;
  end if;
  return v_room;
end;
$function$;

revoke all on function public.get_public_text_messages(bigint,text,text,bigint) from public;
revoke all on function public.send_public_text_message(bigint,text,text,text) from public;
revoke all on function public.advance_public_text_round(bigint,text,text,bigint,text,text) from public;
grant execute on function public.get_public_text_messages(bigint,text,text,bigint) to anon, authenticated;
grant execute on function public.send_public_text_message(bigint,text,text,text) to anon, authenticated;
grant execute on function public.advance_public_text_round(bigint,text,text,bigint,text,text) to anon, authenticated;
