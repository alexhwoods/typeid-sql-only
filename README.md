# An SQL-only TypeID Implementation

> [!WARNING]  
> Don't use this, use [this](https://github.com/jetify-com/typeid-sql)

This is an SQL-only implementation of [typeid](https://github.com/jetify-com/typeid), for Postgres. Perhaps you use something like Cloud SQL, where [you can't install a custom extension](https://cloud.google.com/sql/docs/postgres/extensions#requesting-support-for-a-new-extension).

## Types

The migration introduces a `typeid` [domain](https://www.postgresql.org/docs/current/domains.html) (basically a type in Postgres).

This can be used on table definitions and functions.

```sql
create table product (
  id typeid primary key
  -- ...other fields
);
```

You can add a further constraint to your column, to ensure it's not just a typeid, it's a product typeid.

```sql
create table product (
  id typeid primary key check (id like 'product_%')
);
```

If you plan to reuse a specific typeid a lot, you may even want to define a custom domain (think "sub-type") on top of the provided `typeid` domain.

```sql
create domain product_typeid as typeid
constraint has_product_prefix check (
  value like 'product_%'
);
```

```sql
select 'product_2gh52ntzrw9wkaf83xp7yredhZ'::product_typeid;
-- ERROR:  value for domain product_typeid violates check constraint "is_valid_typeid"

select 'order_2gh52ntzrw9wkaf83xp7yredhd'::product_typeid;
-- ERROR:  value for domain product_typeid violates check constraint "has_product_prefix"
```

> [!NOTE]  
> While table inheritance drops check constraints from parents, for domains, they are maintained.



## Functions

This implementation provides the following functions.

### `generate_typeid`

```sql
select generate_typeid('team');
```
| generate_typeid                 |
| ------------------------------- |
| team_14jw30z89s9xrt5crfx4w9d838 |


This can be used on table definitions.

```sql
create domain team_typeid as typeid
constraint has_team_prefix check (
  value like 'team_%'
);

create table team (
  id team_typeid primary key default generate_typeid('team')
);

insert into team default values returning *;
```
| id                              |
| ------------------------------- |
| team_2hnycrg7v088etk4mf70td2v9p |

### `uuid_to_typeid`

This provides a function to create a typeid from a UUID.

```sql
select uuid_to_typeid('team', uuid_generate_v4());
```


### `typeid_to_uuid`

Similarly, it provides a function to create a UUID from a typeid.

```sql
select typeid_to_uuid('team_3j2rfz45k198tbtan40zyrsc7j');
-- 72161ff2-1661-4a34-bd2a-a407fd8cb0f2
```


### `typeid_prefix`

```sql
select typeid_prefix('team_3j2rfz45k198tbtan40zyrsc7j');
-- team
```

## Example

I might expect tables to look like this:

```sql
create table product (
  id typeid primary key default generate_typeid('product') check (id like 'product_%')
);
```

## How do you know this works?

I don't know for sure. I would not be surprised if there were some bugs (feel free to add an issue).

Here is a comparison to the `typeid` CLI.

```sql
select uuid_to_typeid('foo', '72161ff2-1661-4a34-bd2a-a407fd8cb0f2');
```
| uuid_to_typeid                 |
| ------------------------------ |
| foo_3j2rfz45k198tbtan40zyrsc7j |


```bash
typeid encode foo 72161ff2-1661-4a34-bd2a-a407fd8cb0f2
foo_3j2rfz45k198tbtan40zyrsc7j
```

And here is encoding and decoding a UUID:

```sql
select typeid_to_uuid(uuid_to_typeid('team', 'ccfd9184-3edc-4006-a119-b29cbb499898')) = 'ccfd9184-3edc-4006-a119-b29cbb499898';
-- t
```
