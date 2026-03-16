from __future__ import annotations

from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field


class TickerTag(BaseModel):
    symbol: Optional[str] = None
    name: Optional[str] = None


class NewsCard(BaseModel):
    news_id: str
    title: str
    published_at: str
    source: str

    tickers: Optional[List[Dict[str, Any]]] = Field(default_factory=list)

    event_type: Optional[str] = None
    event_tags: Optional[Any] = None  # jsonb array from Supabase
    ai_summary_short: Optional[str] = None
    sentiment_label: Optional[str] = None
    risk_label: Optional[str] = None
    importance_score: Optional[float] = 0

    created_at: Optional[str] = None


class NewsDetail(BaseModel):
    news_id: str
    title: str
    published_at: str
    source: str

    clean_content: Optional[str] = None
    summary_short: Optional[str] = None
    summary_medium: Optional[str] = None

    event_type: Optional[str] = None
    sentiment_label: Optional[str] = None
    risk_label: Optional[str] = None
    importance_score: Optional[float] = 0

    event_tags: List[Optional[str]] = Field(default_factory=list)
    tickers: List[Dict[str, Any]] = Field(default_factory=list)

    extra_tags: Optional[Any] = None
    created_at: Optional[str] = None
    updated_at: Optional[str] = None