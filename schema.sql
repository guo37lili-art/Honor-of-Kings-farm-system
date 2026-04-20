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
  created_at  timestamptz default now()
);

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
  v_new    text;
begin
  -- 输入校验
  if p_nickname is null or length(trim(p_nickname)) = 0 or length(p_nickname) > 20 then
    return null;
  end if;
  if p_pin !~ '^[0-9]{4}$' then
    return null;
  end if;

  -- 查现有 hash（用表别名 + 完全限定列名避免命名冲突）
  select u.pin_hash into v_stored
  from public.users u
  where u.nickname = p_nickname;

  if v_stored is null then
    -- 新用户注册
    v_new := extensions.crypt(p_pin, extensions.gen_salt('bf', 10));
    insert into public.users(nickname, pin_hash) values (p_nickname, v_new);
    return v_new;
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
