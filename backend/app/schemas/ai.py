from __future__ import annotations

from typing import Any, Optional

from pydantic import BaseModel, Field


class DiagnosisRequest(BaseModel):
    # You can pass either symbol or ticker_id
    symbol: Optional[str] = None
    ticker_id: Optional[str] = None

    # Optional: diagnosis for specific trigger news
    news_id: Optional[str] = None

    # Future: prompt_version override etc.
    prompt_version: Optional[str] = None


class AIDiagnosis(BaseModel):
    id: str
    ticker_id: str
    news_id: Optional[str] = None

    prompt_version: str
    model_name: Optional[str] = None

    event_summary: Optional[str] = None
    impact_mechanism: Optional[Any] = None
    market_reaction: Optional[str] = None
    follow_up_points: Optional[Any] = None
    risk_warning: Optional[Any] = None

    completeness_level: str = "medium"
    status: str = "success"
    raw_result: Optional[Any] = None
    created_at: str


class DiagnosisResponse(BaseModel):
    status: str = Field(..., description="ok | not_found")
    diagnosis: Optional[AIDiagnosis] = None