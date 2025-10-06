create extension if not exists "uuid-ossp";

-- First, define what typeid validity means.
-- Regex taken from https://github.com/jetify-com/typeid/issues/45#issuecomment-2912074153

create or replace function is_valid_typeid(id text)
returns boolean
language sql
immutable
as $$
  select case
    when id is null then false
    else id ~ '^[a-z]([a-z_]{0,61}[a-z])?_[0-7][0-9a-hjkmnpq-tv-z]{25}$'
  end;
$$;

create domain typeid as text constraint is_valid_typeid check (is_valid_typeid (value));

-- This is an internal function, hence the typeid_sql prefix.
-- It is not a generic "base32" encoder; it is specific to the Jetify's TypeID format.
--
-- Based on the Jetify's TypeID specification: https://github.com/jetify-com/typeid/tree/main/spec
-- TypeID format: prefix_base32_encoded_uuid
-- The prefix must be lowercase ASCII letters, 1-63 characters
-- The UUID is encoded using Crockford's base32 with 2 leading zero bits (130 bits total (130 / 5 = 26 chars))
create or replace function typeid_sql_base32_encode(u uuid)
returns text
language plpgsql
strict
immutable
parallel safe
as $$
declare
    -- crockford alphabet (no i, l, o, u)
    alphabet constant text := '0123456789abcdefghjkmnpqrstvwxyz';
    b bytea;
    result text := '';
    acc int := 0;      -- only holds the leftover bits (never large)
    bits int := 2;     -- 2 leading zero bits per typeid
    i int;
    byte_val int;
    idx int;
begin
    b := decode(replace(u::text, '-', ''), 'hex');

    -- loop 16 times, beacause a uuid is 16 bytes (128 bits)
    for i in 0..15 loop
        byte_val := get_byte(b, i);
        -- push 8 bits
        acc := (acc << 8) | byte_val;
        bits := bits + 8;

        -- emit as many 5-bit symbols as available
        while bits >= 5 loop
            idx := (acc >> (bits - 5)) & 31; -- top 5 bits
            result := result || substr(alphabet, idx + 1, 1);
            -- keep only the remaining (bits - 5) lower bits
            acc := acc & ((1 << (bits - 5)) - 1);
            bits := bits - 5;
        end loop;
    end loop;

    -- with 2 + 16*8 = 130 bits, we always emit 26 chars (26*5 = 130)
    return result;
end;
$$;

-- This is an internal function, hence the typeid_sql prefix.
-- It is not a generic "base32" encoder; it is specific to the Jetify's TypeID format.
--
-- base32 (crockford) suffix → uuid
-- accepts exactly 26 chars from alphabet 0123456789abcdefghjkmnpqrstvwxyz
-- decodes to a 130-bit number, drops the top 2 pad bits, returns the uuid
create or replace function typeid_sql_base32_decode(encoded text)
returns uuid
language plpgsql
as $$
declare
  alphabet text := '0123456789abcdefghjkmnpqrstvwxyz';
  sfx text;
  acc numeric := 0;        -- holds up to 130 bits safely
  i integer;
  c text;
  pos integer;
  val128 numeric;          -- low 128 bits after dropping pad
  hex text := '';
  byte_val integer;
  shift integer;
begin
  if encoded is null then
    return null;
  end if;

  sfx := lower(trim(encoded));

  if length(sfx) <> 26 then
    raise exception 'invalid base32 length: %, want 26', length(sfx)
      using errcode = '22000';
  end if;

  -- base32 decode into 130-bit integer
  for i in 1 .. 26 loop
    c := substr(sfx, i, 1);
    pos := strpos(alphabet, c) - 1;  -- 0-based
    if pos < 0 then
      raise exception 'invalid base32 character "%" at position %', c, i
        using errcode = '22000';
    end if;
    acc := acc * 32 + pos;
  end loop;

  -- drop the leading 2 pad bits -> keep the low 128 bits
  val128 := mod(acc, power(2::numeric, 128));

  -- rebuild 16 bytes (big-endian) into a hex string
  for i in 0 .. 15 loop
    shift := (15 - i) * 8;
    byte_val := mod(floor(val128 / power(2::numeric, shift)), 256::numeric)::int;
    hex := hex || lpad(to_hex(byte_val), 2, '0');
  end loop;

  -- cast hex to uuid (insert dashes)
  return (
    substr(hex, 1, 8)  || '-' ||
    substr(hex, 9, 4)  || '-' ||
    substr(hex, 13, 4) || '-' ||
    substr(hex, 17, 4) || '-' ||
    substr(hex, 21, 12)
  )::uuid;
end
$$;

-- Function to generate a TypeID with a given prefix
create or replace function generate_typeid(prefix text)
returns typeid
language plpgsql
as $$
declare
    uuid_part uuid;
    typeid_str text;
    base32_encoded text;
begin
    -- Validate prefix according to spec (lowercase ASCII letters/numbers, 1-63 chars)
    if prefix is null or length(prefix) = 0 or length(prefix) > 63 or prefix !~ '^[a-z][a-z0-9]*$' then
        raise exception 'Invalid prefix: must be lowercase ASCII letters/numbers, 1-63 characters, starting with a letter';
    end if;
    
    -- Generate a random UUID
    uuid_part := uid_generate_v4();
    
    -- Convert UUID to base32 (TypeID spec requirement)
    base32_encoded := typeid_sql_base32_encode(uuid_part);
    typeid_str := prefix || '_' || base32_encoded;
    
    return typeid_str;
end;
$$;

-- Function to convert UUID to TypeID with prefix
create or replace function uuid_to_typeid(prefix text, uuid_val uuid)
returns typeid
language plpgsql
as $$
declare
    typeid_str text;
    base32_encoded text;
    prefix_validated text;
begin
    prefix_validated := lower(coalesce(prefix, ''));
    
    -- Validate prefix according to spec
    if prefix_validated != '' and not (prefix_validated ~ '^[a-z][a-z0-9]{0,62}$') then
        raise exception 'Invalid prefix: "%". Must match ^[a-z][a-z0-9]{0,62}$', prefix;
    end if;
    
    -- Convert UUID to base32 (TypeID spec requirement)
    base32_encoded := typeid_sql_base32_encode(uuid_val);
    
    if prefix_validated = '' then
        return base32_encoded;
    else
        return prefix_validated || '_' || base32_encoded;
    end if;
end;
$$;

-- Function to convert TypeID to UUID
create or replace function typeid_to_uuid(id typeid)
returns uuid
language sql
as $$
  select typeid_sql_base32_decode(
    case
      when position('_' in lower($1)) > 0 then split_part(lower($1), '_', 2)
      else lower($1)
    end
  )
$$;

-- Helper function to extract prefix from TypeID
create or replace function typeid_prefix(typeid_str typeid)
returns text
language plpgsql
as $$
begin
    if position('_' in typeid_str) = 0 then
        return '';
    end if;
    return split_part(typeid_str, '_', 1);
end;
$$;