-- =============================================================
-- HKstocknews MVP — Supabase PostgreSQL Schema v1
-- Migration: 20260316_init_schema_v1.sql
--
-- 链路：新闻抓取 → 清洗/去重 → 股票实体识别 → 行情联动
--       → AI 结构化诊断 → 前端展示
-- 三个核心页面：资讯流列表页 | 股票详情页 | AI 诊断页
-- =============================================================

-- ─────────────────────────────────────────────────────────────
-- 0. 启用扩展 (Extensions)
-- ─────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid(), pgp_* 等
CREATE EXTENSION IF NOT EXISTS vector;     -- pgvector，支持 RAG 向量检索


-- ─────────────────────────────────────────────────────────────
-- 1. 通用 updated_at 自动更新 Trigger Function
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


-- ─────────────────────────────────────────────────────────────
-- 2. ticker_master — 港股股票主数据表
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ticker_master (
  id            uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  symbol        varchar(20)   NOT NULL,          -- 完整代码，如 00700.HK
  short_code    varchar(10),                     -- 短代码，如 00700
  name_zh       varchar(100)  NOT NULL,          -- 中文名称
  name_en       varchar(150),                    -- 英文名称
  aliases       jsonb,                           -- 别名数组，便于实体识别匹配
  sector        varchar(100),                    -- 一级行业
  subsector     varchar(100),                    -- 二级行业
  concept_tags  jsonb,                           -- 概念标签，如 ["互联网","AI"]
  market        varchar(20)   NOT NULL DEFAULT 'HK',
  ah_pair_symbol varchar(20),                    -- A/H 对应 A 股代码（可空）
  is_active     boolean       NOT NULL DEFAULT true,
  created_at    timestamptz   NOT NULL DEFAULT now(),
  updated_at    timestamptz   NOT NULL DEFAULT now(),

  CONSTRAINT uq_ticker_symbol UNIQUE (symbol)
);

COMMENT ON TABLE ticker_master IS '港股股票主数据表；服务于资讯流股票Tag、股票详情页顶部信息、AI诊断页';

CREATE INDEX IF NOT EXISTS idx_ticker_short_code  ON ticker_master (short_code);
CREATE INDEX IF NOT EXISTS idx_ticker_name_zh     ON ticker_master (name_zh);
CREATE INDEX IF NOT EXISTS idx_ticker_sector      ON ticker_master (sector);
CREATE INDEX IF NOT EXISTS idx_ticker_is_active   ON ticker_master (is_active);
CREATE INDEX IF NOT EXISTS idx_ticker_aliases_gin ON ticker_master USING gin (aliases);

CREATE TRIGGER trg_ticker_master_updated_at
  BEFORE UPDATE ON ticker_master
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ─────────────────────────────────────────────────────────────
-- 3. news_raw — 原始新闻表（爬虫留档，不直接给前端）
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS news_raw (
  id             uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  source_name    varchar(100) NOT NULL,             -- 来源名，如 财联社
  source_type    varchar(50)  NOT NULL DEFAULT 'media',
                                                    -- announcement / media / flash
  source_url     text,                              -- 原文链接
  title_raw      text         NOT NULL,             -- 原始标题
  content_raw    text,                              -- 原始正文
  published_at   timestamptz,                       -- 发布时间
  fetched_at     timestamptz  NOT NULL DEFAULT now(),
  lang           varchar(10)  NOT NULL DEFAULT 'zh',
  crawl_status   varchar(20)  NOT NULL DEFAULT 'success',
                                                    -- success / failed / partial
  raw_hash       varchar(64),                       -- SHA-256 内容指纹，用于去重
  metadata       jsonb,                             -- 额外元数据（爬虫参数等）

  CONSTRAINT chk_news_raw_source_type
    CHECK (source_type IN ('announcement','media','flash','other')),
  CONSTRAINT chk_news_raw_crawl_status
    CHECK (crawl_status IN ('success','failed','partial'))
);

COMMENT ON TABLE news_raw IS '爬虫原始新闻留档表；仅供数据追溯，不直接暴露给前端';

CREATE INDEX IF NOT EXISTS idx_news_raw_source_name  ON news_raw (source_name);
CREATE INDEX IF NOT EXISTS idx_news_raw_source_type  ON news_raw (source_type);
CREATE INDEX IF NOT EXISTS idx_news_raw_published_at ON news_raw (published_at DESC);
CREATE INDEX IF NOT EXISTS idx_news_raw_raw_hash     ON news_raw (raw_hash);


-- ─────────────────────────────────────────────────────────────
-- 4. news_clean — 清洗后新闻主表（资讯流列表页核心依赖）
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS news_clean (
  id                 uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  raw_news_id        uuid         REFERENCES news_raw (id) ON DELETE SET NULL,
  clean_title        text         NOT NULL,         -- 清洗后标题（资讯流卡片 title）
  clean_content      text,                          -- 清洗后正文
  summary_short      text,                          -- AI 一句话摘要（资讯流卡片展示）
  summary_medium     text,                          -- 中等摘要（新闻详情页展示）
  published_at       timestamptz  NOT NULL,         -- 发布时间（资讯流卡片展示）
  source_name        varchar(100) NOT NULL,         -- 来源名（资讯流卡片展示）
  dedup_hash         varchar(64),                   -- 去重指纹
  event_type         varchar(50),                   -- 事件类型：回购/业绩/政策/评级 等
  sentiment_label    varchar(20),                   -- 情绪：利多/利空/中性
  risk_label         varchar(100),                  -- 风险标签（可多值，逗号分隔或用 extra_tags）
  importance_score   numeric(5,2) NOT NULL DEFAULT 0,
  is_duplicate       boolean      NOT NULL DEFAULT false,
  duplicate_of       uuid         REFERENCES news_clean (id) ON DELETE SET NULL,
  processing_status  varchar(20)  NOT NULL DEFAULT 'ready',
                                                    -- ready / pending / failed
  extra_tags         jsonb,                         -- 预留扩展标签
  created_at         timestamptz  NOT NULL DEFAULT now(),
  updated_at         timestamptz  NOT NULL DEFAULT now(),

  CONSTRAINT chk_news_clean_sentiment
    CHECK (sentiment_label IS NULL OR sentiment_label IN ('利多','利空','中性')),
  CONSTRAINT chk_news_clean_processing_status
    CHECK (processing_status IN ('ready','pending','failed'))
);

COMMENT ON TABLE news_clean IS '清洗后新闻主表；直接服务资讯流列表页卡片字段：title, published_at, source, event_type, sentiment_label, risk_label, summary_short';

CREATE INDEX IF NOT EXISTS idx_news_clean_published_at      ON news_clean (published_at DESC);
CREATE INDEX IF NOT EXISTS idx_news_clean_event_type        ON news_clean (event_type);
CREATE INDEX IF NOT EXISTS idx_news_clean_sentiment_label   ON news_clean (sentiment_label);
CREATE INDEX IF NOT EXISTS idx_news_clean_importance_score  ON news_clean (importance_score DESC);
CREATE INDEX IF NOT EXISTS idx_news_clean_source_name       ON news_clean (source_name);
CREATE INDEX IF NOT EXISTS idx_news_clean_dedup_hash        ON news_clean (dedup_hash);
CREATE INDEX IF NOT EXISTS idx_news_clean_is_duplicate      ON news_clean (is_duplicate);

CREATE TRIGGER trg_news_clean_updated_at
  BEFORE UPDATE ON news_clean
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ─────────────────────────────────────────────────────────────
-- 5. news_ticker_link — 新闻与股票多对多关联表
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS news_ticker_link (
  id          uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  news_id     uuid         NOT NULL REFERENCES news_clean (id) ON DELETE CASCADE,
  ticker_id   uuid         NOT NULL REFERENCES ticker_master (id) ON DELETE CASCADE,
  match_type  varchar(30)  NOT NULL DEFAULT 'ai_extract',
                                                    -- title / content / ai_extract / manual
  confidence  numeric(5,2) NOT NULL DEFAULT 0,      -- 匹配置信度 0~1
  is_primary  boolean      NOT NULL DEFAULT false,  -- 是否主关联股票（资讯流卡片优先展示）
  created_at  timestamptz  NOT NULL DEFAULT now(),

  CONSTRAINT uq_news_ticker UNIQUE (news_id, ticker_id),
  CONSTRAINT chk_ntl_match_type
    CHECK (match_type IN ('title','content','ai_extract','manual')),
  CONSTRAINT chk_ntl_confidence
    CHECK (confidence >= 0 AND confidence <= 1)
);

COMMENT ON TABLE news_ticker_link IS '新闻与股票多对多关联；支持资讯流卡片股票Tag、股票详情页相关新闻时间轴';

CREATE INDEX IF NOT EXISTS idx_ntl_news_id         ON news_ticker_link (news_id);
CREATE INDEX IF NOT EXISTS idx_ntl_ticker_created  ON news_ticker_link (ticker_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ntl_is_primary      ON news_ticker_link (is_primary);


-- ─────────────────────────────────────────────────────────────
-- 6. quote_snapshot — 股票行情快照表（股票详情页顶部行情区）
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS quote_snapshot (
  id           uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  ticker_id    uuid          NOT NULL REFERENCES ticker_master (id) ON DELETE CASCADE,
  symbol       varchar(20)   NOT NULL,              -- 冗余，便于直接查询
  last_price   numeric(18,4),                       -- 最新价
  pct_change   numeric(10,4),                       -- 涨跌幅（%）
  abs_change   numeric(18,4),                       -- 涨跌额
  volume       bigint,                              -- 成交量（股）
  turnover     numeric(20,2),                       -- 成交额（港元）
  high_price   numeric(18,4),                       -- 当日最高
  low_price    numeric(18,4),                       -- 当日最低
  prev_close   numeric(18,4),                       -- 昨收价
  snapshot_at  timestamptz   NOT NULL,              -- 快照时间（即 updated_at 语义）
  source_name  varchar(50),                         -- 行情数据源

  CONSTRAINT chk_qs_last_price   CHECK (last_price IS NULL OR last_price >= 0),
  CONSTRAINT chk_qs_high_low     CHECK (high_price IS NULL OR low_price IS NULL
                                        OR high_price >= low_price)
);

COMMENT ON TABLE quote_snapshot IS '股票行情快照；服务于股票详情页顶部行情区字段：price, pct_change, turnover, updated_at';

CREATE INDEX IF NOT EXISTS idx_qs_ticker_snap  ON quote_snapshot (ticker_id, snapshot_at DESC);
CREATE INDEX IF NOT EXISTS idx_qs_symbol_snap  ON quote_snapshot (symbol, snapshot_at DESC);
CREATE INDEX IF NOT EXISTS idx_qs_snapshot_at  ON quote_snapshot (snapshot_at DESC);


-- ─────────────────────────────────────────────────────────────
-- 7. ai_diagnosis — AI 结构化诊断缓存表（AI 诊断页核心依赖）
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ai_diagnosis (
  id                 uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  ticker_id          uuid         NOT NULL REFERENCES ticker_master (id) ON DELETE CASCADE,
  news_id            uuid         REFERENCES news_clean (id) ON DELETE SET NULL,
                                                    -- 触发新闻 ID（可空，支持综合诊断）
  prompt_version     varchar(30)  NOT NULL DEFAULT 'v1',
  model_name         varchar(50),                   -- 使用的大模型名称
  event_summary      text,                          -- 模块1：事件摘要
  impact_mechanism   jsonb,                         -- 模块2：影响机制（字符串数组）
  market_reaction    text,                          -- 模块3：市场反应
  follow_up_points   jsonb,                         -- 模块4：后续关注点（字符串数组）
  risk_warning       jsonb,                         -- 模块5：风险提示（字符串数组）
  completeness_level varchar(20)  NOT NULL DEFAULT 'medium',
                                                    -- high / medium / low
  status             varchar(20)  NOT NULL DEFAULT 'success',
                                                    -- success / failed / partial
  raw_result         jsonb,                         -- 模型原始返回，供调试
  created_at         timestamptz  NOT NULL DEFAULT now(),

  CONSTRAINT chk_aid_completeness
    CHECK (completeness_level IN ('high','medium','low')),
  CONSTRAINT chk_aid_status
    CHECK (status IN ('success','failed','partial'))
);

COMMENT ON TABLE ai_diagnosis IS 'AI 结构化诊断缓存表；直接服务 AI 诊断页五模块字段：event_summary, impact_mechanism, market_reaction, follow_up_points, risk_warning';

CREATE INDEX IF NOT EXISTS idx_aid_ticker_created ON ai_diagnosis (ticker_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_aid_news_id        ON ai_diagnosis (news_id);
CREATE INDEX IF NOT EXISTS idx_aid_prompt_version ON ai_diagnosis (prompt_version);
CREATE INDEX IF NOT EXISTS idx_aid_status         ON ai_diagnosis (status);


-- ─────────────────────────────────────────────────────────────
-- 8. news_embedding — 新闻向量表（RAG 检索，MVP 预留）
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS news_embedding (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  news_id      uuid        NOT NULL REFERENCES news_clean (id) ON DELETE CASCADE,
  embedding    vector(1536) NOT NULL,               -- OpenAI text-embedding-3-small 维度
  chunk_text   text,                                -- 对应切片文本（用于召回展示）
  chunk_index  integer     NOT NULL DEFAULT 0,      -- 切片序号（同一新闻可多切片）
  created_at   timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT chk_ne_chunk_index CHECK (chunk_index >= 0)
);

COMMENT ON TABLE news_embedding IS '新闻向量嵌入表；MVP 预留，用于未来 RAG 语义检索增强';

CREATE INDEX IF NOT EXISTS idx_ne_news_id ON news_embedding (news_id);
-- 向量 HNSW 索引（余弦相似度），启用后可显著提升 ANN 检索性能
CREATE INDEX IF NOT EXISTS idx_ne_embedding_hnsw
  ON news_embedding USING hnsw (embedding vector_cosine_ops);


-- ─────────────────────────────────────────────────────────────
-- 9. user_favorites — 用户收藏表（RLS 保护）
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS user_favorites (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid        NOT NULL,              -- Supabase Auth uid
  favorite_type  varchar(20) NOT NULL,              -- ticker / news
  ref_id         uuid        NOT NULL,              -- 对应 ticker_master.id 或 news_clean.id
  created_at     timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT uq_user_favorite UNIQUE (user_id, favorite_type, ref_id),
  CONSTRAINT chk_uf_favorite_type
    CHECK (favorite_type IN ('ticker','news'))
);

COMMENT ON TABLE user_favorites IS '用户收藏表；RLS 保护，用户只能读写自己的记录；服务于 AI 诊断页"收藏股票"操作';

CREATE INDEX IF NOT EXISTS idx_uf_user_id       ON user_favorites (user_id);
CREATE INDEX IF NOT EXISTS idx_uf_type_ref      ON user_favorites (favorite_type, ref_id);

-- 启用 RLS
ALTER TABLE user_favorites ENABLE ROW LEVEL SECURITY;

-- 用户只能查看自己的收藏
CREATE POLICY uf_select_own ON user_favorites
  FOR SELECT
  USING (auth.uid() = user_id);

-- 用户只能插入自己的收藏
CREATE POLICY uf_insert_own ON user_favorites
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- 用户只能删除自己的收藏
CREATE POLICY uf_delete_own ON user_favorites
  FOR DELETE
  USING (auth.uid() = user_id);

-- 用户只能更新自己的收藏（防止越权）
CREATE POLICY uf_update_own ON user_favorites
  FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);


-- ─────────────────────────────────────────────────────────────
-- 10. user_recent_views — 用户最近浏览记录（RLS 保护）
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS user_recent_views (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid        NOT NULL,                  -- Supabase Auth uid
  view_type  varchar(20) NOT NULL,                  -- ticker / news / diagnosis
  ref_id     uuid        NOT NULL,                  -- 目标 ID
  created_at timestamptz NOT NULL DEFAULT now(),    -- 浏览时间

  CONSTRAINT chk_urv_view_type
    CHECK (view_type IN ('ticker','news','diagnosis'))
);

COMMENT ON TABLE user_recent_views IS '用户最近浏览记录；RLS 保护，用户只能读写自己的记录；服务于个人中心历史页';

CREATE INDEX IF NOT EXISTS idx_urv_user_created ON user_recent_views (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_urv_type_ref     ON user_recent_views (view_type, ref_id);

-- 启用 RLS
ALTER TABLE user_recent_views ENABLE ROW LEVEL SECURITY;

-- 用户只能查看自己的浏览记录
CREATE POLICY urv_select_own ON user_recent_views
  FOR SELECT
  USING (auth.uid() = user_id);

-- 用户只能插入自己的浏览记录
CREATE POLICY urv_insert_own ON user_recent_views
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- 用户只能删除自己的浏览记录
CREATE POLICY urv_delete_own ON user_recent_views
  FOR DELETE
  USING (auth.uid() = user_id);

-- 用户只能更新自己的浏览记录
CREATE POLICY urv_update_own ON user_recent_views
  FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);


-- ─────────────────────────────────────────────────────────────
-- 11. crawl_job_logs — 定时爬取任务日志
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crawl_job_logs (
  id            uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  job_name      varchar(100) NOT NULL,              -- 任务名，如 crawl_hkex_news
  source_name   varchar(100),                       -- 来源名
  status        varchar(20)  NOT NULL DEFAULT 'running',
                                                    -- running / success / failed / partial
  started_at    timestamptz  NOT NULL DEFAULT now(),
  finished_at   timestamptz,                        -- 任务结束时间
  items_fetched integer      NOT NULL DEFAULT 0,    -- 本次抓取条数
  items_saved   integer      NOT NULL DEFAULT 0,    -- 本次入库条数
  error_message text,                               -- 失败时的错误信息
  extra_info    jsonb,                              -- 额外上下文信息

  CONSTRAINT chk_cjl_status
    CHECK (status IN ('running','success','failed','partial'))
);

COMMENT ON TABLE crawl_job_logs IS '爬取任务运行日志；服务于内部监控与数据管线故障排查';

CREATE INDEX IF NOT EXISTS idx_cjl_job_name   ON crawl_job_logs (job_name);
CREATE INDEX IF NOT EXISTS idx_cjl_started_at ON crawl_job_logs (started_at DESC);
CREATE INDEX IF NOT EXISTS idx_cjl_status     ON crawl_job_logs (status);


-- ─────────────────────────────────────────────────────────────
-- 12. Views
-- ─────────────────────────────────────────────────────────────

-- 12.1 v_latest_quote — 每支股票最新一条行情快照
--      服务于：股票详情页顶部行情区、AI 诊断页股票摘要
CREATE OR REPLACE VIEW v_latest_quote AS
SELECT DISTINCT ON (qs.ticker_id)
  qs.id,
  qs.ticker_id,
  qs.symbol,
  tm.name_zh            AS name,
  qs.last_price,
  qs.pct_change,
  qs.abs_change,
  qs.volume,
  qs.turnover,
  qs.high_price,
  qs.low_price,
  qs.prev_close,
  qs.snapshot_at        AS updated_at,
  qs.source_name
FROM quote_snapshot qs
JOIN ticker_master tm ON tm.id = qs.ticker_id
ORDER BY qs.ticker_id, qs.snapshot_at DESC;

COMMENT ON VIEW v_latest_quote IS '最新行情快照视图（每只股票取最近一条）；供股票详情页和AI诊断页直接查询';


-- 12.2 v_news_feed — 资讯流基础视图
--      服务于：首页资讯流列表页卡片所需全部字段
--      字段对应 NewsCardResponse schema
CREATE OR REPLACE VIEW v_news_feed AS
SELECT
  nc.id                 AS news_id,
  nc.clean_title        AS title,
  nc.published_at,
  nc.source_name        AS source,
  nc.event_type,
  nc.sentiment_label,
  nc.risk_label,
  nc.summary_short      AS ai_summary_short,
  nc.importance_score,
  -- 关联股票聚合（前端渲染股票 Tag，最多取 is_primary 优先的前 3 个）
  (
    SELECT jsonb_agg(
      jsonb_build_object('symbol', tm.symbol, 'name', tm.name_zh)
      ORDER BY ntl.is_primary DESC, ntl.confidence DESC
    )
    FROM news_ticker_link ntl
    JOIN ticker_master tm ON tm.id = ntl.ticker_id
    WHERE ntl.news_id = nc.id
  )                     AS tickers,
  nc.extra_tags,
  nc.created_at
FROM news_clean nc
WHERE nc.is_duplicate = false
  AND nc.processing_status = 'ready';

COMMENT ON VIEW v_news_feed IS '资讯流基础视图；直接返回资讯流卡片所需全部字段：title, published_at, source, tickers, event_type, sentiment_label, risk_label, ai_summary_short';
