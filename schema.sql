-- 王者农场助手 · Supabase Schema
-- 在 Supabase Dashboard → SQL Editor 一次性执行全部

-- ============================================================
-- 0. 扩展（Supabase 默认把扩展放在 extensions schema）
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

-- ============================================================
-- 1. 表
-- ============================================================

create table if not exists public.users (
  nickname    text primary key,
  pin_hash    text not null,       -- bcrypt hash，由 extensions.crypt() 生成
  banned      boolean not null default false,   -- 管理员封号用，被封后无法登录
  created_at  timestamptz default now()
);

-- 兼容旧库：确保 banned 列存在
alter table public.users add column if not exists banned boolean not null default false;

create table if not exists public.crops (
  id              uuid primary key default gen_random_uuid(),
  user_nickname   text not null references public.users(nickname) on delete cascade,
  type            int  not null check (type in (8, 16, 32)),
  planted_at      timestamptz not null,
  water_events    jsonb not null default '[]'::jsonb,
  mode            text not null default 'fast'
                    check (mode in ('fast','lazy','target','nowater')),
  target_harvest  timestamptz,
  harvested_at    timestamptz,
  name            text,
  created_at      timestamptz default now()
);

create index if not exists crops_user_idx on public.crops(user_nickname);

-- 兼容旧库：确保 name 列存在
alter table public.crops add column if not exists name text;

-- ============================================================
-- 2. RLS：读全开，写走 RPC（RPC 内部校验 PIN）
-- ============================================================

alter table public.users enable row level security;
alter table public.crops enable row level security;

drop policy if exists "public read users" on public.users;
drop policy if exists "public read crops" on public.crops;
create policy "public read users" on public.users for select using (true);
create policy "public read crops" on public.crops for select using (true);

-- ============================================================
-- 3. 登录 RPC（服务端 bcrypt hash）
-- 昵称不存在 → 注册并返回新 hash
-- 昵称存在且 PIN 正确 → 返回 stored hash（作为后续写操作的 token）
-- 失败 → 返回 null
-- ============================================================

create or replace function public.auth_login(p_nickname text, p_pin text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_stored text;
  v_banned boolean;
  v_new    text;
begin
  -- 输入校验
  if p_nickname is null or length(trim(p_nickname)) = 0 or length(p_nickname) > 20 then
    return null;
  end if;
  if p_pin !~ '^[0-9]{4}$' then
    return null;
  end if;

  -- 查现有 hash + banned 状态
  select u.pin_hash, u.banned into v_stored, v_banned
  from public.users u
  where u.nickname = p_nickname;

  if v_stored is null then
    -- 新用户注册
    v_new := extensions.crypt(p_pin, extensions.gen_salt('bf', 10));
    insert into public.users(nickname, pin_hash) values (p_nickname, v_new);
    return v_new;
  end if;

  -- 被封用户无法登录
  if coalesce(v_banned, false) then
    return null;
  end if;

  -- 已有用户校验 PIN
  if extensions.crypt(p_pin, v_stored) = v_stored then
    return v_stored;
  end if;

  return null;
end
$fn$;

-- ============================================================
-- 4. 作物写入 RPC
-- ============================================================

create or replace function public.crop_write(
  p_nickname  text,
  p_pin_hash  text,
  p_action    text,
  p_crop_id   uuid,
  p_payload   jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_ok       boolean;
  v_new_row  public.crops;
begin
  -- PIN token 校验
  select (u.pin_hash = p_pin_hash) into v_ok
  from public.users u
  where u.nickname = p_nickname;

  if not coalesce(v_ok, false) then
    return jsonb_build_object('error', 'auth_failed');
  end if;

  if p_action = 'insert' then
    insert into public.crops (
      user_nickname, type, planted_at, water_events, mode, target_harvest, name
    ) values (
      p_nickname,
      (p_payload->>'type')::int,
      (p_payload->>'planted_at')::timestamptz,
      coalesce(p_payload->'water_events', '[]'::jsonb),
      coalesce(p_payload->>'mode', 'fast'),
      case
        when p_payload ? 'target_harvest'
             and p_payload->>'target_harvest' is not null
        then (p_payload->>'target_harvest')::timestamptz
        else null
      end,
      nullif(p_payload->>'name', '')
    )
    returning * into v_new_row;
    return to_jsonb(v_new_row);

  elsif p_action = 'delete' then
    delete from public.crops
    where id = p_crop_id and user_nickname = p_nickname;
    return jsonb_build_object('ok', true);

  elsif p_action = 'water' then
    update public.crops
    set water_events = water_events || jsonb_build_array(p_payload->>'at')
    where id = p_crop_id and user_nickname = p_nickname
    returning * into v_new_row;
    return to_jsonb(v_new_row);

  elsif p_action = 'harvest' then
    update public.crops
    set harvested_at = (p_payload->>'at')::timestamptz
    where id = p_crop_id and user_nickname = p_nickname
    returning * into v_new_row;
    return to_jsonb(v_new_row);

  elsif p_action = 'water_and_harvest' then
    update public.crops
    set water_events = water_events || jsonb_build_array(p_payload->>'at'),
        harvested_at = (p_payload->>'at')::timestamptz
    where id = p_crop_id and user_nickname = p_nickname
    returning * into v_new_row;
    return to_jsonb(v_new_row);

  elsif p_action = 'update' then
    -- 部分字段更新，只动 payload 里提供的字段
    update public.crops
    set mode = coalesce(p_payload->>'mode', mode),
        target_harvest = case
          when p_payload ? 'target_harvest'
          then nullif(p_payload->>'target_harvest', '')::timestamptz
          else target_harvest
        end,
        name = case
          when p_payload ? 'name'
          then nullif(p_payload->>'name', '')
          else name
        end
    where id = p_crop_id and user_nickname = p_nickname
    returning * into v_new_row;
    return to_jsonb(v_new_row);

  else
    return jsonb_build_object('error', 'unknown_action');
  end if;
end
$fn$;

-- ============================================================
-- 5. 权限：anon 可读 + 可调 RPC，禁止直接写表
-- ============================================================

grant usage on schema public to anon;
grant select on public.users, public.crops to anon;
grant execute on function public.auth_login(text, text) to anon;
grant execute on function public.crop_write(text, text, text, uuid, jsonb) to anon;

revoke insert, update, delete on public.users from anon;
revoke insert, update, delete on public.crops from anon;

-- ============================================================
-- 6. 纪念册：collections 表
-- Sprint 1 启用：insert / update / delete；Sprint 2 启用 is_public；Sprint 4 启用 image_url
-- ============================================================

create table if not exists public.collections (
  id              uuid primary key default gen_random_uuid(),
  user_nickname   text not null references public.users(nickname) on delete cascade,
  crop_type       int  not null check (crop_type in (8, 16, 32)),
  crop_name       text,
  harvested_at    timestamptz,
  mutations       jsonb not null default '[]'::jsonb,
                  -- [{"type":"hero"}, {"type":"giant"}, {"type":"purple","name":"青玉"}, {"type":"normal"}]
  note            text,
  image_url       text,                              -- Sprint 4 才用
  is_public       boolean not null default false,    -- Sprint 2 才用
  source_crop_id  uuid,                              -- 指向原 crops.id，用于"已收入"按钮状态；无外键约束（crops 30min 自清后此 id 会失效）
  created_at      timestamptz default now()
);
-- 兼容已经跑过旧版 schema 的库：先补列（否则下方 collections_source_idx 会报列不存在）
alter table public.collections add column if not exists source_crop_id uuid;

create index if not exists collections_user_idx on public.collections(user_nickname);
create index if not exists collections_public_idx on public.collections(is_public, created_at desc)
  where is_public = true;
create index if not exists collections_source_idx on public.collections(user_nickname, source_crop_id);

alter table public.collections enable row level security;
drop policy if exists "public read collections" on public.collections;
create policy "public read collections" on public.collections for select using (true);

-- ============================================================
-- 7. 纪念册写入 RPC
-- ============================================================

create or replace function public.collection_write(
  p_nickname  text,
  p_pin_hash  text,
  p_action    text,
  p_row_id    uuid,
  p_payload   jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_ok       boolean;
  v_new_row  public.collections;
begin
  -- PIN token 校验（mirror crop_write 的认证流程）
  select (u.pin_hash = p_pin_hash) into v_ok
  from public.users u
  where u.nickname = p_nickname;

  if not coalesce(v_ok, false) then
    return jsonb_build_object('error', 'auth_failed');
  end if;

  if p_action = 'insert' then
    insert into public.collections (
      user_nickname, crop_type, crop_name, harvested_at, mutations, note, image_url, is_public, source_crop_id
    ) values (
      p_nickname,
      (p_payload->>'crop_type')::int,
      nullif(p_payload->>'crop_name', ''),
      case when p_payload ? 'harvested_at' and p_payload->>'harvested_at' is not null
           then (p_payload->>'harvested_at')::timestamptz else null end,
      coalesce(p_payload->'mutations', '[]'::jsonb),
      nullif(p_payload->>'note', ''),
      nullif(p_payload->>'image_url', ''),
      coalesce((p_payload->>'is_public')::boolean, false),
      case when p_payload ? 'source_crop_id' and p_payload->>'source_crop_id' is not null
           then (p_payload->>'source_crop_id')::uuid else null end
    )
    returning * into v_new_row;
    return to_jsonb(v_new_row);

  elsif p_action = 'update' then
    update public.collections
    set crop_name = case when p_payload ? 'crop_name' then nullif(p_payload->>'crop_name', '') else crop_name end,
        mutations = case when p_payload ? 'mutations' then coalesce(p_payload->'mutations', mutations) else mutations end,
        note      = case when p_payload ? 'note' then nullif(p_payload->>'note', '') else note end,
        image_url = case when p_payload ? 'image_url' then nullif(p_payload->>'image_url', '') else image_url end,
        is_public = case when p_payload ? 'is_public' then coalesce((p_payload->>'is_public')::boolean, is_public) else is_public end
    where id = p_row_id and user_nickname = p_nickname
    returning * into v_new_row;
    return to_jsonb(v_new_row);

  elsif p_action = 'delete' then
    delete from public.collections
    where id = p_row_id and user_nickname = p_nickname;
    return jsonb_build_object('ok', true);

  elsif p_action = 'like_toggle' then
    -- 幂等 toggle：已赞则取消，未赞则添加。返回新状态 { liked, count }
    if exists (
      select 1 from public.collection_likes
      where collection_id = p_row_id and user_nickname = p_nickname
    ) then
      delete from public.collection_likes
      where collection_id = p_row_id and user_nickname = p_nickname;
      return jsonb_build_object(
        'liked', false,
        'count', (select count(*) from public.collection_likes where collection_id = p_row_id)
      );
    else
      insert into public.collection_likes (collection_id, user_nickname)
      values (p_row_id, p_nickname);
      return jsonb_build_object(
        'liked', true,
        'count', (select count(*) from public.collection_likes where collection_id = p_row_id)
      );
    end if;

  elsif p_action = 'question_toggle' then
    -- 和 like_toggle 对称，操作 collection_questions 表
    if exists (
      select 1 from public.collection_questions
      where collection_id = p_row_id and user_nickname = p_nickname
    ) then
      delete from public.collection_questions
      where collection_id = p_row_id and user_nickname = p_nickname;
      return jsonb_build_object(
        'reacted', false,
        'count', (select count(*) from public.collection_questions where collection_id = p_row_id)
      );
    else
      insert into public.collection_questions (collection_id, user_nickname)
      values (p_row_id, p_nickname);
      return jsonb_build_object(
        'reacted', true,
        'count', (select count(*) from public.collection_questions where collection_id = p_row_id)
      );
    end if;

  else
    return jsonb_build_object('error', 'unknown_action');
  end if;
end
$fn$;

-- ============================================================
-- 8. 纪念册权限
-- ============================================================

grant select on public.collections to anon;
grant execute on function public.collection_write(text, text, text, uuid, jsonb) to anon;
revoke insert, update, delete on public.collections from anon;

-- ============================================================
-- 9. 纪念册点赞表（Sprint 3）
-- ============================================================

create table if not exists public.collection_likes (
  collection_id uuid not null references public.collections(id) on delete cascade,
  user_nickname text not null references public.users(nickname) on delete cascade,
  created_at    timestamptz default now(),
  primary key (collection_id, user_nickname)
                -- ★ UNIQUE 兜底：一人对一条只能点一个赞；toggle 靠 RPC 内部逻辑实现
);
create index if not exists collection_likes_cid_idx on public.collection_likes(collection_id);

alter table public.collection_likes enable row level security;
drop policy if exists "public read likes" on public.collection_likes;
create policy "public read likes" on public.collection_likes for select using (true);

grant select on public.collection_likes to anon;
revoke insert, update, delete on public.collection_likes from anon;

-- ============================================================
-- 10. 纪念册 问号反应 表（Sprint 3.5）
-- 和 collection_likes 结构对称，独立一张表方便未来清理或单独限流
-- ============================================================

create table if not exists public.collection_questions (
  collection_id uuid not null references public.collections(id) on delete cascade,
  user_nickname text not null references public.users(nickname) on delete cascade,
  created_at    timestamptz default now(),
  primary key (collection_id, user_nickname)
);
create index if not exists collection_questions_cid_idx on public.collection_questions(collection_id);

alter table public.collection_questions enable row level security;
drop policy if exists "public read questions" on public.collection_questions;
create policy "public read questions" on public.collection_questions for select using (true);

grant select on public.collection_questions to anon;
revoke insert, update, delete on public.collection_questions from anon;

-- ============================================================
-- 11. 管理员能力（Admin power-ups）
-- 允许管理员昵称（'长缨'）跨用户删作物 / 改收藏 / 切公开 / 封号
-- 管理员身份 = nickname 等于硬编码值 + pin_hash 匹配 + 未被封
-- ============================================================

-- 11.1 管理员身份校验 helper
create or replace function public.is_admin(p_nickname text, p_pin_hash text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_ok boolean;
begin
  -- 管理员昵称硬编码（和 admin.html 的 ADMIN_NICKNAME 对应；改这里 + admin.html 两处可换管理员）
  if p_nickname != '长缨' then
    return false;
  end if;
  select (u.pin_hash = p_pin_hash and not coalesce(u.banned, false)) into v_ok
  from public.users u where u.nickname = p_nickname;
  return coalesce(v_ok, false);
end
$fn$;

grant execute on function public.is_admin(text, text) to anon;

-- 11.2 管理员删任意作物（跨用户）
create or replace function public.admin_crop_delete(
  p_admin_nickname text,
  p_admin_pin_hash text,
  p_crop_id        uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if not public.is_admin(p_admin_nickname, p_admin_pin_hash) then
    return jsonb_build_object('error', 'not_admin');
  end if;
  delete from public.crops where id = p_crop_id;
  return jsonb_build_object('ok', true);
end
$fn$;

grant execute on function public.admin_crop_delete(text, text, uuid) to anon;

-- 11.3 管理员改 / 删任意 collection（update 支持所有字段含 is_public；delete 硬删）
create or replace function public.admin_collection_write(
  p_admin_nickname text,
  p_admin_pin_hash text,
  p_action         text,
  p_row_id         uuid,
  p_payload        jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_new_row public.collections;
begin
  if not public.is_admin(p_admin_nickname, p_admin_pin_hash) then
    return jsonb_build_object('error', 'not_admin');
  end if;

  if p_action = 'update' then
    update public.collections
    set crop_name = case when p_payload ? 'crop_name' then nullif(p_payload->>'crop_name', '') else crop_name end,
        mutations = case when p_payload ? 'mutations' then coalesce(p_payload->'mutations', mutations) else mutations end,
        note      = case when p_payload ? 'note' then nullif(p_payload->>'note', '') else note end,
        image_url = case when p_payload ? 'image_url' then nullif(p_payload->>'image_url', '') else image_url end,
        is_public = case when p_payload ? 'is_public' then coalesce((p_payload->>'is_public')::boolean, is_public) else is_public end
    where id = p_row_id
    returning * into v_new_row;
    return to_jsonb(v_new_row);

  elsif p_action = 'delete' then
    delete from public.collections where id = p_row_id;
    return jsonb_build_object('ok', true);

  else
    return jsonb_build_object('error', 'unknown_action');
  end if;
end
$fn$;

grant execute on function public.admin_collection_write(text, text, text, uuid, jsonb) to anon;

-- 11.4 管理员封号 / 恢复（切换 users.banned）
create or replace function public.admin_user_ban(
  p_admin_nickname  text,
  p_admin_pin_hash  text,
  p_target_nickname text,
  p_banned          boolean
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if not public.is_admin(p_admin_nickname, p_admin_pin_hash) then
    return jsonb_build_object('error', 'not_admin');
  end if;
  -- 管理员自己不能被封（防止误操作把自己锁出去）
  if p_target_nickname = '长缨' then
    return jsonb_build_object('error', 'cannot_ban_admin');
  end if;
  update public.users set banned = coalesce(p_banned, false) where nickname = p_target_nickname;
  return jsonb_build_object('ok', true);
end
$fn$;

grant execute on function public.admin_user_ban(text, text, text, boolean) to anon;

-- ============================================================
-- 12. 好友系统（v1.1.0）
-- 双向好友：friendships 表用 user_a < user_b 规范化，双向关系存一行
-- 朋友圈 is_public=true 语义从"全网可见"改为"好友可见"
-- ============================================================

create table if not exists public.friendships (
  user_a       text not null references public.users(nickname) on delete cascade,
  user_b       text not null references public.users(nickname) on delete cascade,
  created_at   timestamptz default now(),
  primary key (user_a, user_b),
  check (user_a < user_b)   -- 规范化：字典序小的在前，防重复
);
create index if not exists friendships_b_idx on public.friendships(user_b);

alter table public.friendships enable row level security;
drop policy if exists "public read friendships" on public.friendships;
create policy "public read friendships" on public.friendships for select using (true);
grant select on public.friendships to anon;
revoke insert, update, delete on public.friendships from anon;

-- 好友申请表
create table if not exists public.friend_requests (
  id           uuid primary key default gen_random_uuid(),
  from_user    text not null references public.users(nickname) on delete cascade,
  to_user      text not null references public.users(nickname) on delete cascade,
  status       text not null default 'pending'
                 check (status in ('pending','accepted','rejected')),
  created_at   timestamptz default now(),
  responded_at timestamptz,
  check (from_user <> to_user)
);
-- partial unique：同一对 from→to 只能有一条 pending，历史已处理的不占名额
create unique index if not exists friend_requests_pending_uniq
  on public.friend_requests(from_user, to_user)
  where status = 'pending';
create index if not exists friend_requests_to_idx
  on public.friend_requests(to_user, status) where status = 'pending';

alter table public.friend_requests enable row level security;
drop policy if exists "public read friend_requests" on public.friend_requests;
create policy "public read friend_requests" on public.friend_requests for select using (true);
grant select on public.friend_requests to anon;
revoke insert, update, delete on public.friend_requests from anon;

-- ============================================================
-- 13. 好友系统 helpers
-- ============================================================

-- PIN + banned 综合校验（后续所有用户态 RPC 共用）
create or replace function public._check_pin(p_nick text, p_hash text)
returns boolean
language sql stable
set search_path = public
as $fn$
  select exists(
    select 1 from public.users
    where nickname = p_nick and pin_hash = p_hash and not coalesce(banned, false)
  );
$fn$;

-- 两人是否好友
create or replace function public.is_friend(p_a text, p_b text)
returns boolean
language sql stable
set search_path = public
as $fn$
  select exists (
    select 1 from public.friendships
    where user_a = least(p_a, p_b) and user_b = greatest(p_a, p_b)
  );
$fn$;
grant execute on function public.is_friend(text, text) to anon;

-- ============================================================
-- 14. 好友系统 RPC
-- ============================================================

-- 14.1 发送好友申请
-- 若对方已向我申请 pending → 自动互接受（竞态处理）
create or replace function public.friend_request_send(
  p_nickname text, p_pin_hash text, p_target text
) returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $fn$
begin
  if not public._check_pin(p_nickname, p_pin_hash) then
    return jsonb_build_object('error', 'auth_failed');
  end if;
  if p_target = p_nickname then
    return jsonb_build_object('error', 'cannot_befriend_self');
  end if;
  if not exists (
    select 1 from public.users where nickname = p_target and not coalesce(banned, false)
  ) then
    return jsonb_build_object('error', 'target_not_found');
  end if;
  if public.is_friend(p_nickname, p_target) then
    return jsonb_build_object('error', 'already_friends');
  end if;
  -- 对方已申请 pending → 自动互接受
  if exists (
    select 1 from public.friend_requests
    where from_user = p_target and to_user = p_nickname and status = 'pending'
  ) then
    update public.friend_requests
      set status = 'accepted', responded_at = now()
      where from_user = p_target and to_user = p_nickname and status = 'pending';
    insert into public.friendships(user_a, user_b)
      values (least(p_nickname, p_target), greatest(p_nickname, p_target))
      on conflict do nothing;
    return jsonb_build_object('ok', true, 'auto_accepted', true);
  end if;
  -- 正常插入；partial unique 兜底
  insert into public.friend_requests(from_user, to_user)
    values (p_nickname, p_target)
    on conflict do nothing;
  return jsonb_build_object('ok', true);
end
$fn$;

grant execute on function public.friend_request_send(text, text, text) to anon;

-- 14.2 响应好友申请（同意/拒绝）
create or replace function public.friend_request_respond(
  p_nickname text, p_pin_hash text, p_request_id uuid, p_accept boolean
) returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $fn$
declare
  v_from text;
  v_to   text;
  v_status text;
begin
  if not public._check_pin(p_nickname, p_pin_hash) then
    return jsonb_build_object('error', 'auth_failed');
  end if;
  select from_user, to_user, status into v_from, v_to, v_status
    from public.friend_requests where id = p_request_id;
  if v_to is null then return jsonb_build_object('error', 'not_found'); end if;
  if v_to <> p_nickname then return jsonb_build_object('error', 'not_recipient'); end if;
  if v_status <> 'pending' then return jsonb_build_object('error', 'not_pending'); end if;

  update public.friend_requests
    set status = case when p_accept then 'accepted' else 'rejected' end,
        responded_at = now()
    where id = p_request_id;

  if p_accept then
    insert into public.friendships(user_a, user_b)
      values (least(v_from, v_to), greatest(v_from, v_to))
      on conflict do nothing;
  end if;
  return jsonb_build_object('ok', true, 'from_user', v_from);
end
$fn$;

grant execute on function public.friend_request_respond(text, text, uuid, boolean) to anon;

-- 14.3 列出自己的好友
create or replace function public.friend_list(p_nickname text, p_pin_hash text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $fn$
begin
  if not public._check_pin(p_nickname, p_pin_hash) then
    return jsonb_build_object('error', 'auth_failed');
  end if;
  return jsonb_build_object('ok', true, 'data', coalesce((
    select jsonb_agg(jsonb_build_object(
      'nickname', case when user_a = p_nickname then user_b else user_a end,
      'since', created_at
    ) order by created_at desc)
    from public.friendships
    where user_a = p_nickname or user_b = p_nickname
  ), '[]'::jsonb));
end
$fn$;

grant execute on function public.friend_list(text, text) to anon;

-- 14.4 列出自己收到的 pending 申请
create or replace function public.friend_requests_incoming(p_nickname text, p_pin_hash text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $fn$
begin
  if not public._check_pin(p_nickname, p_pin_hash) then
    return jsonb_build_object('error', 'auth_failed');
  end if;
  return jsonb_build_object('ok', true, 'data', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id,
      'from_user', from_user,
      'created_at', created_at
    ) order by created_at desc)
    from public.friend_requests
    where to_user = p_nickname and status = 'pending'
  ), '[]'::jsonb));
end
$fn$;

grant execute on function public.friend_requests_incoming(text, text) to anon;

-- 14.5 删除好友
create or replace function public.friend_remove(
  p_nickname text, p_pin_hash text, p_target text
) returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $fn$
begin
  if not public._check_pin(p_nickname, p_pin_hash) then
    return jsonb_build_object('error', 'auth_failed');
  end if;
  delete from public.friendships
    where user_a = least(p_nickname, p_target) and user_b = greatest(p_nickname, p_target);
  return jsonb_build_object('ok', true);
end
$fn$;

grant execute on function public.friend_remove(text, text, text) to anon;

-- ============================================================
-- 15. 朋友圈 / 纪念册朋友模式 RPC（is_public 语义切换到"好友可见"）
-- ============================================================

-- 15.1 朋友圈 feed：返回 me 自己 + me 好友 的 is_public=true 条目
-- 结构 1:1 对齐现有 Web feed.loadFeed 的 .select('*, collection_likes(user_nickname), collection_questions(user_nickname)')
create or replace function public.feed_for_user(p_nickname text, p_pin_hash text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $fn$
declare v_rows jsonb;
begin
  if not public._check_pin(p_nickname, p_pin_hash) then
    return jsonb_build_object('error', 'auth_failed');
  end if;
  -- jsonb_agg(t order by ...) 直接聚合 record；比 row_to_jsonb(t) 更稳定（后者在部分 Supabase 环境下 record 重载解析不到）
  select coalesce(jsonb_agg(t order by t.created_at desc), '[]'::jsonb) into v_rows
  from (
    select c.*,
      coalesce((
        select jsonb_agg(jsonb_build_object('user_nickname', user_nickname))
        from public.collection_likes where collection_id = c.id
      ), '[]'::jsonb) as collection_likes,
      coalesce((
        select jsonb_agg(jsonb_build_object('user_nickname', user_nickname))
        from public.collection_questions where collection_id = c.id
      ), '[]'::jsonb) as collection_questions
    from public.collections c
    where c.is_public = true
      and (c.user_nickname = p_nickname
           or public.is_friend(p_nickname, c.user_nickname))
  ) t;
  return jsonb_build_object('ok', true, 'data', v_rows);
end
$fn$;

grant execute on function public.feed_for_user(text, text) to anon;

-- 15.2 纪念册朋友模式：必须是好友才看得到
-- 看自己等价于 list 所有条目（含非公开）
-- 非好友返回 is_friend=false + 空 data
create or replace function public.collection_friend_list_v2(
  p_nickname text, p_pin_hash text, p_friend text
) returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $fn$
begin
  if not public._check_pin(p_nickname, p_pin_hash) then
    return jsonb_build_object('error', 'auth_failed');
  end if;
  if p_friend = p_nickname then
    return jsonb_build_object('ok', true, 'is_friend', true,
      'data', coalesce((
        select jsonb_agg(c order by c.created_at desc)
        from public.collections c where c.user_nickname = p_nickname
      ), '[]'::jsonb));
  end if;
  if not public.is_friend(p_nickname, p_friend) then
    return jsonb_build_object('ok', true, 'is_friend', false, 'data', '[]'::jsonb);
  end if;
  return jsonb_build_object('ok', true, 'is_friend', true,
    'data', coalesce((
      select jsonb_agg(c order by c.created_at desc)
      from public.collections c
      where c.user_nickname = p_friend and c.is_public = true
    ), '[]'::jsonb));
end
$fn$;

grant execute on function public.collection_friend_list_v2(text, text, text) to anon;

-- 15.3 主页朋友视图：必须是好友才能看 TA 的作物（v1.1.0 bug 修复）
-- 和 collection_friend_list_v2 对称
create or replace function public.crop_friend_list_v2(
  p_nickname text, p_pin_hash text, p_friend text
) returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $fn$
begin
  if not public._check_pin(p_nickname, p_pin_hash) then
    return jsonb_build_object('error', 'auth_failed');
  end if;
  if p_friend = p_nickname then
    -- 看自己 = 查所有作物
    return jsonb_build_object('ok', true, 'is_friend', true,
      'data', coalesce((
        select jsonb_agg(c order by c.planted_at desc)
        from public.crops c where c.user_nickname = p_nickname
      ), '[]'::jsonb));
  end if;
  if not public.is_friend(p_nickname, p_friend) then
    return jsonb_build_object('ok', true, 'is_friend', false, 'data', '[]'::jsonb);
  end if;
  return jsonb_build_object('ok', true, 'is_friend', true,
    'data', coalesce((
      select jsonb_agg(c order by c.planted_at desc)
      from public.crops c
      where c.user_nickname = p_friend
    ), '[]'::jsonb));
end
$fn$;

grant execute on function public.crop_friend_list_v2(text, text, text) to anon;
