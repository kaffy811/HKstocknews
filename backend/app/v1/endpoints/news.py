from __future__ import annotations

from typing import List, Optional

from fastapi import APIRouter, HTTPException, Query

from app.db.supabase_rest import supabase
from app.schemas.news import NewsCard, NewsDetail

router = APIRouter()


@router.get("", response_model=List[NewsCard])
async def list_news(
    limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0),
    # Optional quick filters (MVP)
    sentiment_label: Optional[str] = Query(None, description="利多/利空/中性"),
    risk_label: Optional[str] = Query(None),
    event_type: Optional[str] = Query(None),
) -> List[NewsCard]:
    """
    Home feed (资讯流列表页).
    Data source: public.v_news_feed (view)
    """
    params = {
        "select": "news_id,title,published_at,source,tickers,event_type,event_tags,ai_summary_short,sentiment_label,risk_label,importance_score,created_at",
        "order": "published_at.desc",
        "limit": str(limit),
        "offset": str(offset),
    }

    if sentiment_label:
        params["sentiment_label"] = f"eq.{sentiment_label}"
    if risk_label:
        params["risk_label"] = f"eq.{risk_label}"
    if event_type:
        params["event_type"] = f"eq.{event_type}"

    rows = await supabase.get("v_news_feed", params=params)
    return [NewsCard.model_validate(r) for r in rows]


@router.get("/{news_id}", response_model=NewsDetail)
async def get_news(news_id: str) -> NewsDetail:
    """
    News detail (MVP).
    Data source: news_clean + tickers aggregation from news_ticker_link/ticker_master.
    """
    # 1) fetch news_clean
    try:
        nc = await supabase.get_one(
            "news_clean",
            params={
                "select": "id,clean_title,clean_content,summary_short,summary_medium,published_at,source_name,event_type,sentiment_label,risk_label,importance_score,extra_tags,created_at,updated_at",
                "id": f"eq.{news_id}",
            },
        )
    except HTTPException as e:
        if e.status_code == 406:
            raise HTTPException(status_code=404, detail="news not found")
        raise

    # 2) tickers aggregation
    tickers = await supabase.get(
        "news_ticker_link",
        params={
            "select": "is_primary,confidence,ticker_master(symbol,name_zh)",
            "news_id": f"eq.{news_id}",
            "order": "is_primary.desc,confidence.desc",
        },
    )

    ticker_list = []
    for row in tickers:
        tm = row.get("ticker_master") or {}
        if tm:
            ticker_list.append({"symbol": tm.get("symbol"), "name": tm.get("name_zh")})

    return NewsDetail(
        news_id=nc["id"],
        title=nc["clean_title"],
        published_at=nc["published_at"],
        source=nc["source_name"],
        clean_content=nc.get("clean_content"),
        summary_short=nc.get("summary_short"),
        summary_medium=nc.get("summary_medium"),
        event_type=nc.get("event_type"),
        sentiment_label=nc.get("sentiment_label"),
        risk_label=nc.get("risk_label"),
        importance_score=nc.get("importance_score", 0),
        event_tags=derive_event_tags(nc.get("extra_tags"), nc.get("event_type")),
        tickers=ticker_list,
        extra_tags=nc.get("extra_tags"),
        created_at=nc.get("created_at"),
        updated_at=nc.get("updated_at"),
    )


def derive_event_tags(extra_tags, event_type: Optional[str]):
    """
    Keep consistent with your v_news_feed rule:
    - extra_tags is array => event_tags
    - extra_tags.event_tags is array => that
    - else [event_type] or []
    """
    if extra_tags is None:
        return [event_type] if event_type else []
    if isinstance(extra_tags, list):
        return extra_tags
    if isinstance(extra_tags, dict):
        et = extra_tags.get("event_tags")
        if isinstance(et, list):
            return et
    return [event_type] if event_type else []