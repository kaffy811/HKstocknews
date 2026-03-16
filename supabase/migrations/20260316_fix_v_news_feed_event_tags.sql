-- =============================================================
-- Migration: 20260316_fix_v_news_feed_event_tags.sql
-- Purpose : Patch v_news_feed to include event_tags (jsonb array)
-- Safe    : Only replaces a VIEW; no table schema changes.
-- =============================================================

begin;

create or replace view public.v_news_feed as
select
  nc.id                 as news_id,
  nc.clean_title        as title,
  nc.published_at,
  nc.source_name        as source,
  nc.event_type,
  nc.sentiment_label,
  nc.risk_label,
  nc.summary_short      as ai_summary_short,
  nc.importance_score,

  -- tickers: aggregated json array [{symbol,name},...]
  (
    select jsonb_agg(
      jsonb_build_object('symbol', tm.symbol, 'name', tm.name_zh)
      order by ntl.is_primary desc, ntl.confidence desc
    )
    from public.news_ticker_link ntl
    join public.ticker_master tm on tm.id = ntl.ticker_id
    where ntl.news_id = nc.id
  ) as tickers,

  -- event_tags: always jsonb array
  (
    case
      -- extra_tags is already an array => treat as event_tags (current seed behavior)
      when nc.extra_tags is not null and jsonb_typeof(nc.extra_tags) = 'array'
        then nc.extra_tags

      -- extra_tags is an object and has event_tags: [...]
      when nc.extra_tags is not null
           and jsonb_typeof(nc.extra_tags) = 'object'
           and (nc.extra_tags ? 'event_tags')
           and jsonb_typeof(nc.extra_tags->'event_tags') = 'array'
        then nc.extra_tags->'event_tags'

      -- fallback to [event_type]
      when nc.event_type is not null
        then jsonb_build_array(nc.event_type)

      else '[]'::jsonb
    end
  ) as event_tags,

  -- keep raw extra_tags for future extension/debug
  nc.extra_tags,
  nc.created_at

from public.news_clean nc
where nc.is_duplicate = false
  and nc.processing_status = 'ready';

comment on view public.v_news_feed is
'资讯流基础视图；返回资讯流卡片字段：title, published_at, source, tickers, event_tags, ai_summary_short, sentiment_label, risk_label 等。';

commit;
