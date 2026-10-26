-- Public room discovery for Объясняриум.
-- This RPC exposes only lobby metadata; it never returns game_state or player tokens.
create or replace function public.list_public_rooms()
returns table (
  room_id bigint,
  room_code text,
  player_count integer,
  player_names text[],
  last_activity_at timestamptz
)
language sql
security definer
set search_path = ''
stable
as $function$
  select
    r.id,
    r.code,
    coalesce(jsonb_array_length(r.game_state->'players'), 0)::integer,
    coalesce(
      array(
        select left(coalesce(p->>'name', 'Игрок'), 20)
        from jsonb_array_elements(
          case when jsonb_typeof(r.game_state->'players') = 'array'
               then r.game_state->'players' else '[]'::jsonb end
        ) p
        limit 8
      ),
      array[]::text[]
    ),
    r.last_activity_at
  from public.rooms r
  where r.game_state->>'visibility' = 'public'
    and r.game_state->>'status' = 'lobby'
    and r.last_activity_at > now() - interval '3 minutes'
    and coalesce(jsonb_array_length(r.game_state->'players'), 0) < 8
  order by r.last_activity_at desc
  limit 30;
$function$;

revoke all on function public.list_public_rooms() from public;
grant execute on function public.list_public_rooms() to anon, authenticated;
