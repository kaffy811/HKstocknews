from __future__ import annotations

from typing import Any, List, Optional

from pydantic import BaseModel, Field


class Ticker(BaseModel):
    id: str
    symbol: str
    short_code: Optional[str] = None
    name_zh: str
    name_en: Optional[str] = None
    sector: Optional[str] = None
    subsector: Optional[str] = None
    concept_tags: Optional[Any] = None
    is_active: bool = True
    updated_at: Optional[str] = None


class QuoteLatest(BaseModel):
    ticker_id: str
    symbol: str
    name: Optional[str] = None

    last_price: Optional[float] = None
    pct_change: Optional[float] = None
    abs_change: Optional[float] = None
    volume: Optional[int] = None
    turnover: Optional[float] = None

    high_price: Optional[float] = None
    low_price: Optional[float] = None
    prev_close: Optional[float] = None

    updated_at: str
    source_name: Optional[str] = None


class RelatedNewsItem(BaseModel):
    news_id: str
    title: str
    published_at: str
    source: str

    event_type: Optional[str] = None
    sentiment_label: Optional[str] = None
    risk_label: Optional[str] = None
    ai_summary_short: Optional[str] = None


class TickerDetail(BaseModel):
    ticker: Ticker
    quote: Optional[QuoteLatest] = None
    related_news: List[RelatedNewsItem] = Field(default_factory=list)