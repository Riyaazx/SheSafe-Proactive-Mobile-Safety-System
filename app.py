from fastapi import FastAPI
from pydantic import BaseModel
from typing import Optional, List
import numpy as np
import joblib
import pandas as pd
from math import radians, cos, sin, asin, sqrt, ceil
from datetime import datetime, timedelta
import hashlib
import logging

# Configure logging for anonymised data
logging.basicConfig(
    filename='safeword_verification.log',
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)

model = joblib.load("isolation_forest_model.pkl")
scaler = joblib.load("scaler.pkl")

# Load risk zones from CSV (single copy lives in assets/)
risk_zones_df = pd.read_csv("assets/risk_zones.csv", comment='#')

app = FastAPI()

# Configuration for Safe Word Verification
CONFIDENCE_THRESHOLD = 0.75  # Minimum confidence score (75%)
VERIFICATION_WINDOW_SECONDS = 30  # Time window for multi-match verification
REQUIRED_MATCHES = 1  # Number of matches needed (changed to 1 for faster response)
MIN_MATCH_SCORE = 0.65  # Minimum similarity score for phrase matching

# In-memory session storage (use Redis in production for scalability)
verification_sessions = {}

class MotionWindow(BaseModel):
    features: list[float]

class LocationCheck(BaseModel):
    latitude: float
    longitude: float

class RouteRequest(BaseModel):
    origin_lat: float
    origin_lon: float
    destination_lat: float
    destination_lon: float
    destination_address: Optional[str] = None

class SafeWordVerificationRequest(BaseModel):
    session_id: str
    phrase: str
    confidence: float
    stored_safe_word: str  # In production, retrieve from secure user database
    timestamp: Optional[str] = None  # ISO format timestamp

class PanicEscalationEvent(BaseModel):
    session_id: str
    stage: str                              # EscalationStage name
    trigger: str                            # EscalationTrigger name
    trigger_history: List[str] = []
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    anomaly_score: Optional[float] = None
    anomaly_consecutive_windows: Optional[int] = None
    safe_word_confidence: Optional[float] = None
    timestamp: Optional[str] = None

@app.post("/motion/predict")
def predict_motion(data: MotionWindow):
    try:
        X = np.array(data.features).reshape(1, -1)
        X_scaled = scaler.transform(X)
        prediction = int(model.predict(X_scaled)[0])
        score = float(model.decision_function(X_scaled)[0])

        return {
            "prediction": prediction,
            "anomaly_score": score
        }
    except Exception as e:
        return {"error": str(e)}

def haversine_distance(lat1, lon1, lat2, lon2):
    """
    Calculate the distance between two points on Earth (in meters)
    using the Haversine formula
    """
    # Convert decimal degrees to radians
    lat1, lon1, lat2, lon2 = map(radians, [lat1, lon1, lat2, lon2])
    
    # Haversine formula
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    a = sin(dlat/2)**2 + cos(lat1) * cos(lat2) * sin(dlon/2)**2
    c = 2 * asin(sqrt(a))
    
    # Radius of Earth in meters
    r = 6371000
    
    return c * r

@app.post("/location/check")
def check_location_risk(data: LocationCheck):
    """
    Check if the user's location is near any risky zones
    """
    try:
        user_lat = data.latitude
        user_lon = data.longitude
        
        nearby_risks = []
        
        # Check distance to each risk zone
        for _, zone in risk_zones_df.iterrows():
            distance = haversine_distance(
                user_lat, user_lon, 
                zone['latitude'], zone['longitude']
            )
            
            # If user is within the risk zone radius
            if distance <= zone['radius_meters']:
                nearby_risks.append({
                    "zone_name": zone['zone_name'],
                    "risk_level": zone['risk_level'],
                    "distance_meters": round(distance, 2),
                    "description": zone['description']
                })
        
        # Determine overall risk
        if not nearby_risks:
            overall_risk = "safe"
            message = "You are in a safe area"
        else:
            # Check if any high risk zones
            high_risks = [r for r in nearby_risks if r['risk_level'] == 'high']
            if high_risks:
                overall_risk = "high"
                message = f"⚠️ WARNING: You are near {len(high_risks)} high-risk zone(s)"
            else:
                overall_risk = "medium"
                message = f"⚠️ CAUTION: You are near {len(nearby_risks)} medium-risk zone(s)"
        
        return {
            "overall_risk": overall_risk,
            "message": message,
            "nearby_risks": nearby_risks,
            "total_risks_nearby": len(nearby_risks)
        }
        
    except Exception as e:
        return {"error": str(e)}

@app.post("/route/safest")
def calculate_safest_route(data: RouteRequest):
    """
    Calculate the safest route from origin to destination
    considering risk zones and providing evidence-based explanations
    """
    try:
        # Get multiple route options using OpenRouteService (free alternative to Google Maps)
        # For MVP, we'll calculate a simple direct route and score it against risk zones
        
        origin = (data.origin_lat, data.origin_lon)
        destination = (data.destination_lat, data.destination_lon)
        
        # Calculate simple route (in production, use OpenRouteService or Google Directions API)
        route_segments = _generate_route_segments(origin, destination)
        
        # Score each segment against risk zones
        route_analysis = _analyze_route_safety(route_segments)
        
        # Generate explanation with evidence
        explanation = _generate_route_explanation(route_analysis)
        
        # Create turn-by-turn instructions (simplified for MVP)
        instructions = _generate_instructions(route_segments)
        
        return {
            "status": "success",
            "route": {
                "origin": {"lat": data.origin_lat, "lon": data.origin_lon},
                "destination": {"lat": data.destination_lat, "lon": data.destination_lon},
                "polyline": [{"lat": seg["lat"], "lon": seg["lon"]} for seg in route_segments],
                "distance_meters": route_analysis["total_distance"],
                "estimated_time_minutes": ceil(route_analysis["total_distance"] / 1000 * 12)  # 12 min/km — matches Google Maps walking pace (5 km/h)
            },
            "safety_analysis": {
                "overall_safety_score": route_analysis["safety_score"],
                "risk_level": route_analysis["risk_level"],
                "risk_zones_nearby": route_analysis["risk_zones_count"],
                "safe_segments": route_analysis["safe_segments"],
                "risky_segments": route_analysis["risky_segments"]
            },
            "explanation": explanation,
            "instructions": instructions,
            "evidence": route_analysis["evidence"]
        }
        
    except Exception as e:
        return {"error": str(e), "status": "failed"}

def _generate_route_segments(origin, destination, num_points=20):
    """
    Generate route segments between origin and destination
    In production, replace with actual routing API (OpenRouteService/Google)
    """
    lat1, lon1 = origin
    lat2, lon2 = destination
    
    segments = []
    for i in range(num_points + 1):
        fraction = i / num_points
        lat = lat1 + (lat2 - lat1) * fraction
        lon = lon1 + (lon2 - lon1) * fraction
        segments.append({"lat": lat, "lon": lon, "step": i})
    
    return segments

def _analyze_route_safety(route_segments):
    """
    Analyze route segments against risk zones database
    """
    total_distance = 0
    risk_zones_encountered = []
    safe_segments = 0
    risky_segments = 0
    
    for i in range(len(route_segments) - 1):
        seg = route_segments[i]
        next_seg = route_segments[i + 1]
        
        # Calculate segment distance
        seg_distance = haversine_distance(
            seg["lat"], seg["lon"],
            next_seg["lat"], next_seg["lon"]
        )
        total_distance += seg_distance
        
        # Check if segment is near any risk zones
        is_risky = False
        for _, zone in risk_zones_df.iterrows():
            distance_to_zone = haversine_distance(
                seg["lat"], seg["lon"],
                zone['latitude'], zone['longitude']
            )
            
            # If segment passes within risk zone radius + 100m buffer
            if distance_to_zone <= (zone['radius_meters'] + 100):
                is_risky = True
                if zone['zone_name'] not in [z['name'] for z in risk_zones_encountered]:
                    risk_zones_encountered.append({
                        "name": zone['zone_name'],
                        "risk_level": zone['risk_level'],
                        "description": zone['description'],
                        "distance_from_route": round(distance_to_zone, 1)
                    })
        
        if is_risky:
            risky_segments += 1
        else:
            safe_segments += 1
    
    # Calculate safety score (0-100, higher is safer)
    if len(route_segments) > 1:
        safety_score = int((safe_segments / (safe_segments + risky_segments)) * 100)
    else:
        safety_score = 100
    
    # Determine risk level
    if safety_score >= 80:
        risk_level = "low"
    elif safety_score >= 50:
        risk_level = "medium"
    else:
        risk_level = "high"
    
    return {
        "total_distance": round(total_distance, 1),
        "safety_score": safety_score,
        "risk_level": risk_level,
        "risk_zones_count": len(risk_zones_encountered),
        "safe_segments": safe_segments,
        "risky_segments": risky_segments,
        "evidence": risk_zones_encountered
    }

def _generate_route_explanation(analysis):
    """
    Generate human-readable explanation of why this route is safe/unsafe
    """
    safety_score = analysis["safety_score"]
    risk_zones = analysis["evidence"]
    
    if safety_score >= 80:
        main_message = f"✅ This route is SAFE (Safety Score: {safety_score}/100)"
        details = f"This route avoids most risk zones. {analysis['safe_segments']} out of {analysis['safe_segments'] + analysis['risky_segments']} segments are in safe areas."
    elif safety_score >= 50:
        main_message = f"⚠️ This route has MODERATE RISK (Safety Score: {safety_score}/100)"
        details = f"This route passes near {len(risk_zones)} risk zone(s). Stay alert in these areas."
    else:
        main_message = f"🚨 This route has HIGH RISK (Safety Score: {safety_score}/100)"
        details = f"Warning: This route passes through or very close to {len(risk_zones)} high-risk zone(s). Consider alternative routes if possible."
    
    # Add specific risk zone warnings
    risk_warnings = []
    if risk_zones:
        risk_warnings.append("\n📍 Risk Zones Near This Route:")
        for zone in risk_zones:
            emoji = "🔴" if zone["risk_level"] == "high" else "🟡"
            risk_warnings.append(
                f"{emoji} {zone['name']} ({zone['risk_level']} risk) - {zone['description']}"
            )
    else:
        risk_warnings.append("\n✅ No known risk zones along this route.")
    
    return {
        "summary": main_message,
        "details": details,
        "warnings": risk_warnings
    }

def _generate_instructions(route_segments):
    """
    Generate simple turn-by-turn instructions
    In production, use routing API's instruction output
    """
    instructions = [
        {
            "step": 1,
            "instruction": "Start from your current location",
            "distance": "0m"
        },
        {
            "step": 2,
            "instruction": "Walk straight toward your destination",
            "distance": f"Following safe route"
        },
        {
            "step": 3,
            "instruction": "Stay on main roads with good lighting",
            "distance": "Throughout journey"
        },
        {
            "step": 4,
            "instruction": "You will arrive at your destination",
            "distance": "Final step"
        }
    ]
    
    return instructions


def _anonymize_session_id(session_id: str) -> str:
    """
    Hash session ID for anonymised logging
    """
    return hashlib.sha256(session_id.encode()).hexdigest()[:16]


def _calculate_phrase_similarity(phrase1: str, phrase2: str) -> float:
    """
    Calculate similarity between two phrases using word matching
    Returns score between 0.0 and 1.0
    """
    # Normalize phrases
    phrase1 = phrase1.lower().strip()
    phrase2 = phrase2.lower().strip()
    
    # Exact match gets perfect score
    if phrase1 == phrase2:
        return 1.0
    
    # Check if safe word is contained in the phrase
    if phrase2 in phrase1 or phrase1 in phrase2:
        return 0.9
    
    # Word-by-word comparison
    words1 = set(phrase1.split())
    words2 = set(phrase2.split())
    
    if not words1 or not words2:
        return 0.0
    
    # Calculate Jaccard similarity
    intersection = len(words1.intersection(words2))
    union = len(words1.union(words2))
    
    return intersection / union if union > 0 else 0.0


def _clean_verification_sessions():
    """
    Remove old session data to prevent memory bloat
    """
    current_time = datetime.now()
    expired_sessions = []
    
    for session_id, data in verification_sessions.items():
        if current_time - data['last_updated'] > timedelta(minutes=5):
            expired_sessions.append(session_id)
    
    for session_id in expired_sessions:
        del verification_sessions[session_id]


@app.post("/safeword/verify")
def verify_safe_word(data: SafeWordVerificationRequest):
    """
    Verify safe word with confidence thresholding and multi-match verification
    
    Returns:
    - detected: bool
    - confidence: float
    - reason_code: str
    - match_count: int (number of matches within time window)
    - requires_more_matches: bool
    """
    try:
        # Clean old sessions periodically
        _clean_verification_sessions()
        
        # Parse timestamp
        if data.timestamp:
            try:
                current_time = datetime.fromisoformat(data.timestamp.replace('Z', '+00:00'))
            except:
                current_time = datetime.now()
        else:
            current_time = datetime.now()
        
        # Calculate phrase similarity
        similarity_score = _calculate_phrase_similarity(data.phrase, data.stored_safe_word)
        
        # Anonymize session ID for logging
        anon_session = _anonymize_session_id(data.session_id)
        
        # Check confidence threshold
        if data.confidence < CONFIDENCE_THRESHOLD:
            logging.info(
                f"Session: {anon_session} | Result: REJECTED | "
                f"Reason: LOW_CONFIDENCE | Confidence: {data.confidence:.2f} | "
                f"Threshold: {CONFIDENCE_THRESHOLD}"
            )
            return {
                "detected": False,
                "confidence": data.confidence,
                "reason_code": "LOW_CONFIDENCE",
                "message": f"Confidence {data.confidence:.2f} is below threshold {CONFIDENCE_THRESHOLD}",
                "match_count": 0,
                "requires_more_matches": False
            }
        
        # Check phrase similarity
        if similarity_score < MIN_MATCH_SCORE:
            logging.info(
                f"Session: {anon_session} | Result: REJECTED | "
                f"Reason: PHRASE_MISMATCH | Similarity: {similarity_score:.2f} | "
                f"Min Score: {MIN_MATCH_SCORE}"
            )
            return {
                "detected": False,
                "confidence": data.confidence,
                "reason_code": "PHRASE_MISMATCH",
                "message": f"Phrase similarity {similarity_score:.2f} is below minimum {MIN_MATCH_SCORE}",
                "match_count": 0,
                "requires_more_matches": False
            }
        
        # Initialize or update session
        if data.session_id not in verification_sessions:
            verification_sessions[data.session_id] = {
                'matches': [],
                'last_updated': current_time
            }
        
        session = verification_sessions[data.session_id]
        
        # Add current match
        session['matches'].append({
            'timestamp': current_time,
            'confidence': data.confidence,
            'similarity': similarity_score
        })
        session['last_updated'] = current_time
        
        # Filter matches within time window
        cutoff_time = current_time - timedelta(seconds=VERIFICATION_WINDOW_SECONDS)
        recent_matches = [
            m for m in session['matches']
            if m['timestamp'] >= cutoff_time
        ]
        
        # Update session with filtered matches
        session['matches'] = recent_matches
        
        match_count = len(recent_matches)
        
        # Check if we have enough matches
        if match_count >= REQUIRED_MATCHES:
            # Calculate average confidence of recent matches
            avg_confidence = sum(m['confidence'] for m in recent_matches) / match_count
            avg_similarity = sum(m['similarity'] for m in recent_matches) / match_count
            
            logging.info(
                f"Session: {anon_session} | Result: DETECTED | "
                f"Reason: VERIFIED | Matches: {match_count}/{REQUIRED_MATCHES} | "
                f"Avg Confidence: {avg_confidence:.2f} | Avg Similarity: {avg_similarity:.2f}"
            )
            
            # Clear session after successful verification
            del verification_sessions[data.session_id]
            
            return {
                "detected": True,
                "confidence": avg_confidence,
                "reason_code": "VERIFIED",
                "message": f"Safe word verified with {match_count} matches within {VERIFICATION_WINDOW_SECONDS}s",
                "match_count": match_count,
                "requires_more_matches": False
            }
        else:
            logging.info(
                f"Session: {anon_session} | Result: PENDING | "
                f"Reason: INSUFFICIENT_MATCHES | Matches: {match_count}/{REQUIRED_MATCHES} | "
                f"Window: {VERIFICATION_WINDOW_SECONDS}s"
            )
            
            return {
                "detected": False,
                "confidence": data.confidence,
                "reason_code": "INSUFFICIENT_MATCHES",
                "message": f"Need {REQUIRED_MATCHES - match_count} more match(es) within {VERIFICATION_WINDOW_SECONDS}s",
                "match_count": match_count,
                "requires_more_matches": True,
                "matches_needed": REQUIRED_MATCHES - match_count
            }
        
    except Exception as e:
        logging.error(f"Session: {_anonymize_session_id(data.session_id)} | Error: {str(e)}")
        return {
            "detected": False,
            "confidence": 0.0,
            "reason_code": "ERROR",
            "message": f"Verification error: {str(e)}",
            "match_count": 0,
            "requires_more_matches": False
        }


@app.get("/safeword/config")
def get_safe_word_config():
    """
    Get current safe word verification configuration
    """
    return {
        "confidence_threshold": CONFIDENCE_THRESHOLD,
        "verification_window_seconds": VERIFICATION_WINDOW_SECONDS,
        "required_matches": REQUIRED_MATCHES,
        "min_match_score": MIN_MATCH_SCORE
    }


# ─────────────────────────────────────────────────────────────────────────────
# Panic-mode escalation logging endpoint
# ─────────────────────────────────────────────────────────────────────────────

# In-memory store for active escalation sessions (keyed by session_id).
# Replace with a database in production.
panic_sessions: dict = {}

@app.post("/panic/escalate")
def panic_escalate(data: PanicEscalationEvent):
    """
    Receive a panic-mode escalation event from the mobile app.

    Called by the app whenever the escalation stage changes—most critically
    when stage == 'dispatching'.  The backend:
      - Records the event for audit/analytics
      - Returns an acknowledgement so the app knows the backend received it
      - Can be extended to forward to emergency services / push-notification
        gateway in a production deployment
    """
    try:
        if data.timestamp:
            try:
                ts = datetime.fromisoformat(data.timestamp.replace("Z", "+00:00"))
            except Exception:
                ts = datetime.now()
        else:
            ts = datetime.now()

        anon_session = _anonymize_session_id(data.session_id)

        event = {
            "stage": data.stage,
            "trigger": data.trigger,
            "trigger_history": data.trigger_history,
            "latitude": data.latitude,
            "longitude": data.longitude,
            "anomaly_score": data.anomaly_score,
            "anomaly_consecutive_windows": data.anomaly_consecutive_windows,
            "safe_word_confidence": data.safe_word_confidence,
            "received_at": ts.isoformat(),
        }

        # Persist per session
        if data.session_id not in panic_sessions:
            panic_sessions[data.session_id] = []
        panic_sessions[data.session_id].append(event)

        location_str = (
            f"({data.latitude:.5f}, {data.longitude:.5f})"
            if data.latitude is not None and data.longitude is not None
            else "unknown"
        )

        logging.info(
            f"PANIC | Session: {anon_session} | Stage: {data.stage} | "
            f"Trigger: {data.trigger} | Location: {location_str} | "
            f"AnomalyScore: {data.anomaly_score} | "
            f"SafeWordConf: {data.safe_word_confidence}"
        )

        return {
            "status": "received",
            "session_id": anon_session,       # return anonymised id
            "stage": data.stage,
            "acknowledged_at": ts.isoformat(),
            "message": _escalation_message(data.stage),
        }

    except Exception as e:
        logging.error(f"Panic escalate error: {e}")
        return {"status": "error", "message": str(e)}


def _escalation_message(stage: str) -> str:
    messages = {
        "monitoring":  "Panic session started – monitoring active.",
        "checkIn":     "Check-in prompt triggered.",
        "countdown":   "Countdown to emergency alert started.",
        "dispatching": "Emergency alert dispatch confirmed.",
        "resolved":    "Alert successfully dispatched and logged.",
        "cancelled":   "Panic session cancelled by user.",
    }
    return messages.get(stage, f"Stage '{stage}' recorded.")


@app.get("/health")
def health_check():
    """Lightweight liveness probe used by the app to check backend reachability."""
    return {"status": "ok", "timestamp": datetime.now().isoformat()}



