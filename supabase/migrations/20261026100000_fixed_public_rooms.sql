-- Fixed public rooms are reserved rows, never deleted when players leave.
create table if not exists public.fixed_room_messages (
  id bigint generated always as identity primary key,
  room_id bigint not null references public.rooms(id) on delete cascade,
  player_id text not null,
  player_name text not null,
  message text not null check (length(message) between 1 and 240),
  created_at timestamptz not null default now()
);
create index if not exists fixed_room_messages_room_id_id_idx
  on public.fixed_room_messages(room_id, id);
alter table public.fixed_room_messages enable row level security;
revoke all on public.fixed_room_messages from anon, authenticated, public;

-- Reserve room codes 10001-10003; these rows are intentionally persistent.
insert into public.rooms(code, host_id, game_state)
values
 ('10001', 'fixed-room-1', '{"visibility":"public","fixed_room":true,"room_number":1,"status":"lobby","text_mode":false,"players":[]}'::jsonb),
 ('10002', 'fixed-room-2', '{"visibility":"public","fixed_room":true,"room_number":2,"status":"lobby","text_mode":false,"players":[]}'::jsonb),
 ('10003', 'fixed-room-3', '{"visibility":"public","fixed_room":true,"room_number":3,"status":"lobby","text_mode":false,"players":[]}'::jsonb)
on conflict (code) do update
set game_state = case
  when coalesce(public.rooms.game_state->>'fixed_room','false') = 'true'
    then public.rooms.game_state
  else public.rooms.game_state
end;

create or replace function public.list_fixed_rooms()
returns table(room_number integer, room_id bigint, player_count integer, players jsonb, status text)
language sql security definer set search_path = ''
stable
as $function$
  select (r.game_state->>'room_number')::integer, r.id,
    jsonb_array_length(coalesce(r.game_state->'players','[]'::jsonb)),
    coalesce(r.game_state->'players','[]'::jsonb),
    coalesce(r.game_state->>'status','lobby')
  from public.rooms r
  where r.code in ('10001','10002','10003')
    and r.game_state->>'fixed_room'='true'
  order by (r.game_state->>'room_number')::integer;
$function$;
revoke all on function public.list_fixed_rooms() from public;
grant execute on function public.list_fixed_rooms() to anon, authenticated;
