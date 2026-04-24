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
