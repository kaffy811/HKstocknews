from __future__ import annotations

from fastapi import APIRouter, HTTPException

from app.db.supabase_rest import supabase
from app.schemas.ai import DiagnosisRequest, DiagnosisResponse, AIDiagnosis

router = APIRouter()


@router.post("/diagnosis", response_model=DiagnosisResponse)
async def get_or_create_diagnosis(req: DiagnosisRequest) -> DiagnosisResponse:
    """
    MVP: cache-first
    - find ticker by symbol (or accept ticker_id directly)
    - fetch latest ai_diagnosis by ticker_id and optional news_id
    - if none: return status=not_found (later you can trigger background job)
    """
    ticker_id = req.ticker_id
    if not ticker_id:
        if not req.symbol:
            raise HTTPException(status_code=400, detail="symbol or ticker_id is required")
        try:
            tm = await supabase.get_one(
                "ticker_master",
                params={"select": "id,symbol,name_zh", "symbol": f"eq.{req.symbol}"},
            )
        except HTTPException as e:
            if e.status_code == 406:
                raise HTTPException(status_code=404, detail="ticker not found")
            raise
        ticker_id = tm["id"]

    params = {
        "select": "id,ticker_id,news_id,prompt_version,model_name,event_summary,impact_mechanism,market_reaction,follow_up_points,risk_warning,completeness_level,status,raw_result,created_at",
        "ticker_id": f"eq.{ticker_id}",
        "order": "created_at.desc",
        "limit": "1",
    }
    if req.news_id:
        params["news_id"] = f"eq.{req.news_id}"

    rows = await supabase.get("ai_diagnosis", params=params)
    if not rows:
        return DiagnosisResponse(status="not_found", diagnosis=None)

    diag = AIDiagnosis.model_validate(rows[0])
    return DiagnosisResponse(status="ok", diagnosis=diag)