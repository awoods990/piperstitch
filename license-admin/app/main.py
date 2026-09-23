"""PiperStitch License Admin — a standalone service, separate from the
PiperStitch desktop app, that runs the subscription business: takes
monthly subscriptions through Stripe, mirrors their state from Stripe's
webhooks, signs Macs in to them, hands the app short-lived signed
entitlements, gives customers a self-service account page, and gives
the one admin a dashboard over all of it. See README.md for what this
is, how to configure it, and how to deploy it.
"""

from __future__ import annotations

import base64
import asyncio
import csv
import hashlib
import hmac
import io
import json
import logging
import re
import tempfile
from contextlib import asynccontextmanager
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Optional
from urllib.parse import quote, quote_plus

import httpx
import stripe
from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel, field_validator
from starlette.middleware.sessions import SessionMiddleware

from . import activation, auth, config, db, email_sender, emails, finance, partners, project_view, promotions, ratelimit, referrals, stripe_client, subscriptions, web_access, website_publish

log = logging.getLogger("license_admin")


@asynccontextmanager
async def _lifespan(app: FastAPI):
    db.init_db()
    emails.seed()
    partners.seed_kit()
    missing = config.require_for_serving()
    if missing:
        log.warning("License Admin is running with missing configuration: %s — see .env.example", ", ".join(missing))
    # The scheduler: due sequence emails, the win-back check and recurring
    # expenses, every few minutes, in-process -- no external cron.
    task = asyncio.create_task(_scheduler_loop()) if config.SCHEDULER_ENABLED else None
    yield
    if task:
        task.cancel()


async def _scheduler_loop():
    await asyncio.sleep(20)
    while True:
        try:
            result = await asyncio.to_thread(emails.run_scheduled_work)
            if any(result.values()):
                log.info("Scheduler: %s", result)
        except Exception as e:  # noqa: BLE001
            log.exception("Scheduler tick failed: %s", e)
        await asyncio.sleep(config.SCHEDULER_INTERVAL_SECONDS)


app = FastAPI(title="PiperStitch License Admin", lifespan=_lifespan)
# same_site="lax" rather than Amerus's "strict": the customer's account
# page is reached by clicking a link in an email, and a strict cookie is
# not sent on that cross-site navigation, which would bounce them straight
# back to the "enter your email" form.
app.add_middleware(SessionMiddleware, secret_key=config.SESSION_SECRET or "dev-only-insecure-secret", same_site="lax", https_only=config.SESSION_COOKIE_SECURE)
# Only the JSON API routes need this (the marketing site's subscribe form
# calls /api/checkout via fetch() from its own origin; the app's API is
# not browser-originated at all and ignores CORS).
app.add_middleware(CORSMiddleware, allow_origins=config.CORS_ALLOWED_ORIGINS, allow_methods=["POST"], allow_headers=["Content-Type"])

# Browser-facing POSTs are authorised by a cookie, so a form on someone
# else's site could aim one at us. SameSite=lax already stops the common
# case; this closes the rest by insisting the request says where it came
# from, and that the answer is us. The app's JSON API and Stripe's
# webhook are exempt: they carry their own credentials and no cookie.
_CSRF_EXEMPT = ("/api/", "/webhooks/")
_SELF_ORIGINS = {config.PUBLIC_BASE_URL.rstrip("/")}


@app.middleware("http")
async def _guard_and_harden(request: Request, call_next):
    if request.method in ("POST", "PUT", "PATCH", "DELETE") and not request.url.path.startswith(_CSRF_EXEMPT):
        origin = request.headers.get("origin") or ""
        referer = request.headers.get("referer") or ""
        source = origin or (referer.split("/", 3)[:3] and "/".join(referer.split("/", 3)[:3]))
        here = {f"{request.url.scheme}://{request.headers.get('host', '')}"} | _SELF_ORIGINS
        if source and source not in here:
            log.warning("Refused a cross-site %s to %s from %s", request.method, request.url.path, source)
            return JSONResponse({"error": "cross_site", "message": "That form didn't come from PiperStitch — reload the page and try again."}, status_code=403)
    response = await call_next(request)
    site = config.WEBSITE_BASE_URL.rstrip("/")
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("X-Frame-Options", "DENY")
    response.headers.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
    response.headers.setdefault("Content-Security-Policy",
                                "default-src 'self'; base-uri 'none'; frame-ancestors 'none'; object-src 'none'; "
                                f"img-src 'self' data: {site}; style-src 'self' 'unsafe-inline' {site}; "
                                f"script-src 'self' 'unsafe-inline'; media-src 'self' {site}; form-action 'self'")
    if config.PUBLIC_BASE_URL.startswith("https://"):
        response.headers.setdefault("Strict-Transport-Security", "max-age=15552000; includeSubDomains")
    return response


@app.get("/robots.txt", include_in_schema=False)
def robots() -> Response:
    """Nothing here belongs in a search index: it is somebody's account
    page, the admin, or terms we hand out deliberately."""
    return Response("User-agent: *\nDisallow: /\n", media_type="text/plain")

templates = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))
app.mount("/static", StaticFiles(directory=str(Path(__file__).parent / "static")), name="static")

_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
_TOO_MANY = "That's a lot of emails from one place in an hour. Wait a little and try again — or write to us and we'll sort it out by hand."


def _validate_email(v: str) -> str:
    v = v.strip().lower()
    if not _EMAIL_RE.match(v):
        raise ValueError("not a valid email address")
    return v


def _price_label() -> str:
    cents = config.MONTHLY_PRICE_CENTS
    return f"${cents // 100}" if cents % 100 == 0 else f"${cents / 100:.2f}"


templates.env.globals.update(price_label=_price_label, config=config, max_devices=config.MAX_DEVICES, unreviewed_feedback_count=db.count_feedback_unreviewed,
                              partner_applications_count=lambda: db.count_partners_by_status().get("applied", 0),
                              year_now=lambda: datetime.now(timezone.utc).year)


def _browser_name(user_agent: str) -> str:
    """'Chrome on Mac' from a user-agent string -- for the account page."""
    ua = user_agent or ""
    browser = "Edge" if "Edg/" in ua else "Chrome" if "Chrome/" in ua else "Safari" if "Safari/" in ua else "Firefox" if "Firefox/" in ua else "A browser"
    os_name = "Mac" if "Macintosh" in ua else "Windows" if "Windows" in ua else "Chromebook" if "CrOS" in ua else "iPad" if "iPad" in ua else "iPhone" if "iPhone" in ua else "Android" if "Android" in ua else "Linux" if "Linux" in ua else ""
    return f"{browser} on {os_name}" if os_name else browser


def _short_date(iso: Optional[str]) -> str:
    return iso[:10] if iso else "—"


templates.env.filters["short_date"] = _short_date
templates.env.filters["browser_name"] = _browser_name


def _short_dt(iso: Optional[str]) -> str:
    return iso.replace("T", " ").rstrip("Z")[:16] if iso else "—"


templates.env.filters["short_dt"] = _short_dt


def _money(cents: Optional[int]) -> str:
    return f"${(cents or 0) / 100:,.2f}"


templates.env.filters["money"] = _money


# ------------------------------------------------------------- API models ---


class CustomerIn(BaseModel):
    """POST /api/customers — sent server-to-server by the website's own
    register.php right after someone completes the download form, so a
    customer record exists before any subscription."""

    name: str
    email: str
    phone: str = ""
    address: str = ""
    consent_terms_version: str = ""
    consent_accepted_at: Optional[str] = None

    _validate = field_validator("email")(_validate_email)


class DownloadConfirmedIn(BaseModel):
    email: str

    _validate = field_validator("email")(_validate_email)


class CheckoutIn(BaseModel):
    """POST /api/checkout — called via fetch() from the subscribe form on
    the marketing site's pricing page."""
    promo_code: str = ""

    customer_name: str
    customer_email: str
    phone: str = ""
    address: str = ""

    _validate = field_validator("customer_email")(_validate_email)


class ActivateRequestIn(BaseModel):
    email: str
    device_id: str
    device_name: str = ""

    _validate = field_validator("email")(_validate_email)


class ActivateVerifyIn(BaseModel):
    email: str
    code: str
    device_id: str
    device_name: str = ""

    _validate = field_validator("email")(_validate_email)


class DeviceTokenIn(BaseModel):
    device_token: str


class WebEmailIn(BaseModel):
    email: str
    app: str = "core"      # which app asked: the sign-in email's link goes back there
    flow: str = "signin"   # "trial": the app's guided setup is creating the account -> the sign-up email


class WebHandoffCreateIn(BaseModel):
    token: str
    target: str


class WebHandoffRedeemIn(BaseModel):
    code: str
    user_agent: str = ""


class WebVerifyIn(BaseModel):
    email: str
    code: str
    user_agent: str = ""
    promo_code: str = ""      # a partner code typed at signup (beats the cookie, R8)
    ref_cookie: str = ""      # the ps_ref cookie the app server saw, if any


class WebTokenIn(BaseModel):
    token: str


class WebCheckoutIn(BaseModel):
    token: str
    promo_code: str = ""


class WebPromoIn(BaseModel):
    token: str
    code: str


class WebProofsUseIn(BaseModel):
    token: str
    proof_ref: str


class WebProofsCheckoutIn(BaseModel):
    token: str
    success_url: str = ""
    cancel_url: str = ""


class WebProofsPortalIn(BaseModel):
    token: str
    return_url: str = ""


class WebPreferencesIn(BaseModel):
    token: str
    preferences: dict


class WebProjectIn(BaseModel):
    token: str
    id: str
    name: str = ""
    document: dict


class WebFeedbackIn(BaseModel):
    token: str
    note: str = ""
    design_name: str = ""
    stitch_count: int = 0
    original_image_base64: Optional[str] = None
    original_image_type: str = "image/png"
    digitized_image_base64: str
    digitized_image_type: str = "image/png"



# --------------------------------------------------------------- public ---


@app.get("/health")
def health():
    """For the hosting platform's health check (Railway, a load balancer):
    the process is up and the database opens. Nothing about Stripe."""
    with db.connection() as conn:
        conn.execute("SELECT 1")
    return {"status": "ok"}


@app.get("/", response_class=HTMLResponse)
def root():
    return RedirectResponse("/subscribe", status_code=303)


@app.get("/subscribe", response_class=HTMLResponse)
def subscribe_form(request: Request, name: str = "", email: str = ""):
    """The service's own subscribe form — a fallback and the target of
    email links. The marketing site's pricing page embeds the same flow
    via /api/checkout. ?name=&email= only prefill editable fields."""
    return templates.TemplateResponse(request, "subscribe.html", {"customer_name": name, "customer_email": email})


def _start_checkout(*, customer_name: str, customer_email: str, phone: str = "", address: str = "", promo_code: str = "") -> tuple[Optional["stripe.checkout.Session"], Optional[str]]:
    """Shared by the HTML form and the JSON API: upserts the customer (so
    the subscription's webhook can find them by our id), creates the
    Stripe Checkout Session in subscription mode, records it as pending."""
    customer_name = customer_name.strip()
    if not customer_name:
        return None, "Please give your name."
    existing = db.get_customer_by_email(customer_email)
    if existing is not None:
        validity = subscriptions.validity_for(existing["id"])
        if validity.entitled and validity.status != "comp":
            return None, "This email already has an active PiperStitch subscription — sign in inside the app, or manage it from your account page."
    customer_id = db.upsert_customer(name=customer_name, email=customer_email, phone=phone, address=address, source="checkout" if existing is None else existing["source"])

    promotion = None
    if promo_code.strip():
        try:
            promotion = promotions.validate(promo_code, email=customer_email)
        except promotions.PromoError as e:
            return None, e.message
    try:
        session = stripe_client.create_subscription_checkout(customer_name=customer_name, customer_email=customer_email, customer_id=customer_id, promotion=promotion)
    except stripe.error.StripeError as e:
        log.error("Stripe checkout session creation failed: %s", e)
        return None, "Payment setup failed — please try again in a moment."

    db.create_checkout_session(stripe_session_id=session.id, customer_name=customer_name, customer_email=customer_email, customer_id=customer_id,
                               promotion_id=promotion["id"] if promotion else None)
    return session, None


@app.post("/subscribe")
def subscribe_submit(request: Request, customer_name: str = Form(...), customer_email: str = Form(...)):
    try:
        customer_email = _validate_email(customer_email)
    except ValueError:
        return templates.TemplateResponse(request, "subscribe.html", {"error": "That doesn't look like an email address.", "customer_name": customer_name, "customer_email": customer_email}, status_code=400)
    session, error = _start_checkout(customer_name=customer_name, customer_email=customer_email)
    if error:
        status = 502 if "Payment setup failed" in error else 400
        return templates.TemplateResponse(request, "subscribe.html", {"error": error, "customer_name": customer_name, "customer_email": customer_email}, status_code=status)
    return RedirectResponse(session.url, status_code=303)


@app.post("/api/checkout")
def api_checkout(body: CheckoutIn):
    session, error = _start_checkout(customer_name=body.customer_name, customer_email=body.customer_email, phone=body.phone, address=body.address, promo_code=body.promo_code)
    if error:
        status = 502 if "Payment setup failed" in error else 400
        return JSONResponse({"error": error}, status_code=status)
    return {"checkout_url": session.url}


class PromoValidateIn(BaseModel):
    code: str
    email: str = ""


@app.post("/api/promo/validate")
def api_promo_validate(body: PromoValidateIn):
    """Public (CORS'd to the marketing site): is this code usable, and
    what does it give? Reveals nothing beyond what redeeming would."""
    try:
        promo = promotions.validate(body.code, email=body.email)
    except promotions.PromoError as e:
        return JSONResponse({"valid": False, "error": e.code, "message": e.message}, status_code=200)
    return {"valid": True, **promotions.payload(promo)}


@app.get("/subscribe/success", response_class=HTMLResponse)
def subscribe_success(request: Request, session_id: str = ""):
    checkout = db.get_checkout_session(session_id) if session_id else None
    email = checkout["customer_email"] if checkout else "your email"
    return templates.TemplateResponse(request, "subscribe_success.html", {"customer_email": email})


@app.get("/subscribe/cancel", response_class=HTMLResponse)
def subscribe_cancel(request: Request):
    return templates.TemplateResponse(request, "subscribe_cancel.html", {})


def _require_intake_key(x_api_key: Optional[str]) -> None:
    if not config.INTAKE_API_KEY or not x_api_key or not hmac.compare_digest(x_api_key, config.INTAKE_API_KEY):
        raise HTTPException(status_code=401, detail="invalid or missing API key")


@app.post("/api/customers")
def api_upsert_customer(body: CustomerIn, x_api_key: Optional[str] = Header(None)):
    """Called server-to-server by the website's register.php right after
    a download registration."""
    _require_intake_key(x_api_key)
    customer_id = db.upsert_customer(
        name=body.name, email=body.email, phone=body.phone, address=body.address, consent_terms_version=body.consent_terms_version, consent_accepted_at=body.consent_accepted_at
    )
    return {"customer_id": customer_id}


@app.post("/api/download-confirmed")
def api_download_confirmed(body: DownloadConfirmedIn, x_api_key: Optional[str] = Header(None)):
    _require_intake_key(x_api_key)
    db.mark_downloaded_by_email(body.email)
    return {"ok": True}


# ------------------------------------------------- customer self-service ---


@app.get("/account", response_class=HTMLResponse)
def account_request_form(request: Request):
    if request.session.get("account_customer_id"):
        return RedirectResponse("/account/manage", status_code=303)
    return templates.TemplateResponse(request, "account_request.html", {})


@app.post("/account", response_class=HTMLResponse)
def account_request_submit(request: Request, email: str = Form(...)):
    """Always shows the same "check your email" page whether or not the
    address is known — this one IS enumeration-resistant, since it's a
    public web form anyone can poke at, unlike the app's sign-in."""
    if not ratelimit.allow(request):
        return templates.TemplateResponse(request, "account_request.html", {"error": _TOO_MANY, "email": email}, status_code=429)
    try:
        email = _validate_email(email)
    except ValueError:
        return templates.TemplateResponse(request, "account_request.html", {"error": "That doesn't look like an email address.", "email": email}, status_code=400)
    customer = db.get_customer_by_email(email)
    if customer is not None:
        url = activation.create_account_link(customer["id"])
        try:
            email_sender.send_account_link_email(to_email=email, url=url)
        except email_sender.EmailSendError as e:
            log.error("Account link email failed for %s: %s", email, e)
    return templates.TemplateResponse(request, "account_link_sent.html", {"email": email})


@app.get("/account/open")
def account_open(request: Request, token: str = ""):
    customer_id = activation.resolve_account_link(token) if token else None
    if customer_id is None:
        return templates.TemplateResponse(request, "account_request.html", {"error": "That link has expired or was already used — request a new one below."}, status_code=400)
    request.session["account_customer_id"] = customer_id
    return RedirectResponse("/account/manage", status_code=303)


def _account_customer(request: Request):
    customer_id = request.session.get("account_customer_id")
    customer = db.get_customer(int(customer_id)) if customer_id else None
    if customer is None:
        raise HTTPException(status_code=303, headers={"Location": "/account"})
    return customer


@app.get("/account/manage", response_class=HTMLResponse)
def account_manage(request: Request, message: str = "", error: str = ""):
    customer = _account_customer(request)
    validity = subscriptions.validity_for(customer["id"])
    sub = db.get_subscription(validity.subscription_id) if validity.subscription_id else None
    return templates.TemplateResponse(request, "account_manage.html", {
        "customer": customer,
        "validity": validity,
        "subscription": sub,
        "devices": db.list_active_devices(customer["id"]),
        "web_sessions": db.list_active_web_sessions(customer["id"]),
        "payments": db.list_payments_for_customer(customer["id"]),
        "can_manage_billing": bool(customer["stripe_customer_id"]),
        "message": message or None,
        "error": error or None,
    })


@app.post("/account/web-sessions/{session_row_id}/revoke")
def account_revoke_web_session(request: Request, session_row_id: int):
    """Signs a browser out of the web app from the account page."""
    customer = _account_customer(request)
    row = db.get_web_session(session_row_id)
    if row is None or row["customer_id"] != customer["id"]:
        return RedirectResponse("/account/manage", status_code=303)
    db.revoke_web_session(session_row_id)
    db.add_event(customer_id=customer["id"], subscription_id=None, kind="web_signed_out", detail="Signed a browser out from the account page.")
    return RedirectResponse("/account/manage?message=" + quote_plus("That browser has been signed out."), status_code=303)


@app.post("/account/billing-portal")
def account_billing_portal(request: Request):
    customer = _account_customer(request)
    if not customer["stripe_customer_id"]:
        return RedirectResponse("/account/manage?error=" + quote_plus("There's no card on file to manage — this access was granted directly."), status_code=303)
    try:
        session = stripe_client.create_billing_portal_session(stripe_customer_id=customer["stripe_customer_id"], return_url=f"{config.PUBLIC_BASE_URL}/account/manage")
    except stripe.error.StripeError as e:
        log.error("Billing portal session failed for customer %s: %s", customer["id"], e)
        return RedirectResponse("/account/manage?error=" + quote_plus("Couldn't open the billing page right now — please try again in a moment."), status_code=303)
    return RedirectResponse(session.url, status_code=303)


@app.post("/account/devices/{device_row_id}/revoke")
def account_revoke_device(request: Request, device_row_id: int):
    customer = _account_customer(request)
    device = db.get_device(device_row_id)
    if device is None or device["customer_id"] != customer["id"]:
        return RedirectResponse("/account/manage", status_code=303)
    db.revoke_device(device_row_id)
    db.add_event(customer_id=customer["id"], subscription_id=None, kind="device_signed_out", detail=f"Signed out {device['device_name'] or 'a Mac'} from the account page.")
    return RedirectResponse("/account/manage?message=" + quote_plus("That Mac has been signed out."), status_code=303)


@app.post("/account/logout")
def account_logout(request: Request):
    request.session.pop("account_customer_id", None)
    return RedirectResponse("/account", status_code=303)


# ---------------------------------------------------------------- app API ---
# What the PiperStitch app itself talks to. JSON in, JSON out, never a
# redirect. Errors carry {"error": <code>, "message": <text to show>}.


def _activation_error(e: activation.ActivationError, status: int = 400) -> JSONResponse:
    return JSONResponse({"error": e.code, "message": e.message}, status_code=status)


def _validity_payload(validity: subscriptions.Validity) -> dict:
    return {
        "status": validity.status,
        "entitled": validity.entitled,
        "valid_until": validity.valid_until.isoformat().replace("+00:00", "Z") if validity.valid_until else None,
        "period_end": validity.period_end.isoformat().replace("+00:00", "Z") if validity.period_end else None,
        "cancel_at_period_end": validity.cancel_at_period_end,
        "account_url": f"{config.PUBLIC_BASE_URL}/account",
        "subscribe_url": f"{config.WEBSITE_BASE_URL}/pricing.html",
    }


@app.post("/api/app/activate/request")
def api_activate_request(body: ActivateRequestIn):
    try:
        result = activation.request_code(email=body.email, device_id=body.device_id, device_name=body.device_name)
    except activation.ActivationError as e:
        return _activation_error(e, status=429 if e.code == "rate_limited" else 400)
    result["subscribe_url"] = f"{config.WEBSITE_BASE_URL}/pricing.html"
    result["account_url"] = f"{config.PUBLIC_BASE_URL}/account"
    return result


@app.post("/api/app/activate/verify")
def api_activate_verify(body: ActivateVerifyIn):
    try:
        result = activation.verify_code(email=body.email, code=body.code, device_id=body.device_id, device_name=body.device_name)
    except activation.ActivationError as e:
        return _activation_error(e, status=402 if e.code == "subscription_ended" else 400)
    customer = db.get_customer(result.customer_id)
    return {"device_token": result.device_token, "entitlement": result.entitlement_token, "email": customer["email"], "name": customer["name"], **_validity_payload(result.validity)}


@app.post("/api/app/entitlement")
def api_entitlement(body: DeviceTokenIn):
    try:
        token, validity, who = activation.refresh(device_token=body.device_token)
    except activation.ActivationError as e:
        return _activation_error(e, status=401)
    payload = {"entitlement": token, **who, **_validity_payload(validity)}
    if token is None:
        return JSONResponse({"error": "subscription_ended", "message": "Your PiperStitch subscription has ended. Resubscribe to keep using it.", **payload}, status_code=402)
    return payload


@app.post("/api/app/signout")
def api_signout(body: DeviceTokenIn):
    return {"ok": activation.sign_out(device_token=body.device_token)}


@app.post("/api/app/billing-portal")
def api_billing_portal(body: DeviceTokenIn):
    """Lets the app's account panel open Stripe's portal directly."""
    device = activation.device_for_token(body.device_token)
    if device is None:
        return JSONResponse({"error": "device_revoked", "message": "This Mac is signed out."}, status_code=401)
    customer = db.get_customer(device["customer_id"])
    if not customer["stripe_customer_id"]:
        return {"url": f"{config.PUBLIC_BASE_URL}/account"}
    try:
        session = stripe_client.create_billing_portal_session(stripe_customer_id=customer["stripe_customer_id"])
    except stripe.error.StripeError as e:
        log.error("Billing portal session failed for customer %s: %s", customer["id"], e)
        return JSONResponse({"error": "stripe", "message": "Couldn't open the billing page right now."}, status_code=502)
    return {"url": session.url}


# ------------------------------------------------------------ web edition ---
# Server-to-server from the Swift web server (repo: server/), never from a
# browser: every route requires the WEB_API_KEY shared secret. Same JSON
# error shape as the app API. See web_access.py for the trial rule.


def _require_web_key(x_api_key: Optional[str]) -> None:
    if not config.WEB_API_KEY or not x_api_key or not hmac.compare_digest(x_api_key, config.WEB_API_KEY):
        raise HTTPException(status_code=401, detail="Invalid API key")


@app.post("/api/web/signin/request")
def api_web_signin_request(request: Request, body: WebEmailIn, x_api_key: Optional[str] = Header(None)):
    """The key proves this is our app; the per-address limit lives in
    activation.py; this one stops a script working through a list of
    strangers' addresses."""
    _require_web_key(x_api_key)
    if not ratelimit.allow(request):
        return JSONResponse({"error": "rate_limited", "message": _TOO_MANY}, status_code=429)
    try:
        return web_access.request_code(email=body.email, app="proofs" if body.app == "proofs" else "core", flow="trial" if body.flow == "trial" else "signin")
    except activation.ActivationError as e:
        return _activation_error(e, status=429 if e.code == "rate_limited" else 400)


@app.post("/api/web/signin/verify")
def api_web_signin_verify(body: WebVerifyIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        session = web_access.verify_code(email=body.email, code=body.code, user_agent=body.user_agent, promo_code=body.promo_code, ref_cookie=body.ref_cookie)
    except activation.ActivationError as e:
        return _activation_error(e, status=400)
    return {"token": session.token, **web_access.state(token=session.token)}


@app.post("/api/web/handoff/create")
def api_web_handoff_create(body: WebHandoffCreateIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        return {"code": web_access.create_handoff(token=body.token, target=body.target)}
    except activation.ActivationError as e:
        return _activation_error(e, status=401 if e.code == "session_revoked" else 400)


@app.post("/api/web/handoff/redeem")
def api_web_handoff_redeem(body: WebHandoffRedeemIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        session = web_access.redeem_handoff(code=body.code, user_agent=body.user_agent)
    except activation.ActivationError as e:
        return _activation_error(e, status=400)
    return {"token": session.token, **web_access.state(token=session.token)}


@app.post("/api/web/session")
def api_web_session(body: WebTokenIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        return web_access.state(token=body.token)
    except activation.ActivationError as e:
        return _activation_error(e, status=401)


@app.post("/api/web/signout")
def api_web_signout(body: WebTokenIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    return {"ok": web_access.sign_out(token=body.token)}


class WebProfileIn(BaseModel):
    token: str
    name: str


class WebSendFileIn(BaseModel):
    token: str
    to_email: str
    filename: str
    content_base64: str
    message: str = ""
    design_name: str = ""


@app.post("/api/web/profile")
def api_web_profile(body: WebProfileIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        return web_access.update_name(token=body.token, name=body.name)
    except activation.ActivationError as e:
        return _activation_error(e, status=401 if e.code == "session_revoked" else 400)


@app.post("/api/web/send-file")
def api_web_send_file(body: WebSendFileIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    import base64
    try:
        data = base64.b64decode(body.content_base64, validate=True)
    except (ValueError, binascii_error):
        return JSONResponse({"error": "invalid_file", "message": "The file couldn't be read."}, status_code=400)
    try:
        web_access.send_file(token=body.token, to_email=body.to_email, filename=body.filename, data=data, message=body.message, design_name=body.design_name)
    except activation.ActivationError as e:
        return _activation_error(e, status=401 if e.code == "session_revoked" else (429 if e.code == "rate_limited" else 400))
    return {"sent": True}


@app.post("/api/web/promo/validate")
def api_web_promo_validate(body: WebPromoIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        state = web_access.state(token=body.token)
        promo = promotions.validate(body.code, email=state["email"])
    except activation.ActivationError as e:
        return _activation_error(e, status=401)
    except promotions.PromoError as e:
        return JSONResponse({"valid": False, "error": e.code, "message": e.message}, status_code=200)
    return {"valid": True, **promotions.payload(promo)}


@app.post("/api/web/checkout")
def api_web_checkout(body: WebCheckoutIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        return {"url": web_access.checkout_url(token=body.token, promo_code=body.promo_code)}
    except promotions.PromoError as e:
        return JSONResponse({"error": e.code, "message": e.message}, status_code=400)
    except activation.ActivationError as e:
        return _activation_error(e, status=401 if e.code == "session_revoked" else 400)
    except stripe.error.StripeError as e:
        log.error("Web checkout session creation failed: %s", e)
        return JSONResponse({"error": "stripe", "message": "Payment setup failed — please try again in a moment."}, status_code=502)


@app.post("/api/web/billing-portal")
def api_web_billing_portal(body: WebTokenIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        url = web_access.billing_portal_url(token=body.token)
    except activation.ActivationError as e:
        return _activation_error(e, status=401)
    except stripe.error.StripeError as e:
        log.error("Web billing portal session failed: %s", e)
        return JSONResponse({"error": "stripe", "message": "Couldn't open the billing page right now."}, status_code=502)
    if url is None:
        return JSONResponse({"error": "no_billing", "message": "There's no billing to manage yet — this account is on a free trial."}, status_code=404)
    return {"url": url}


# PiperStitch Proofs: the same customer, tracked here -- three free
# proofs, then its own monthly subscription. The Proofs service calls
# these with the customer's web session token.
@app.post("/api/web/proofs/state")
def api_web_proofs_state(body: WebTokenIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        return web_access.proofs_state(token=body.token)
    except activation.ActivationError as e:
        return _activation_error(e, status=401)


@app.post("/api/web/proofs/use")
def api_web_proofs_use(body: WebProofsUseIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        return web_access.proofs_use(token=body.token, proof_ref=body.proof_ref)
    except activation.ActivationError as e:
        return _activation_error(e, status=401 if e.code == "session_revoked" else (402 if e.code == "proofs_exhausted" else 400))


@app.post("/api/web/proofs/checkout")
def api_web_proofs_checkout(body: WebProofsCheckoutIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        return {"url": web_access.proofs_checkout_url(token=body.token, success_url=body.success_url, cancel_url=body.cancel_url)}
    except activation.ActivationError as e:
        return _activation_error(e, status=401 if e.code == "session_revoked" else 400)
    except stripe.error.StripeError as e:
        log.error("Proofs checkout session creation failed: %s", e)
        return JSONResponse({"error": "stripe", "message": "Payment setup failed — please try again in a moment."}, status_code=502)


@app.post("/api/web/proofs/billing-portal")
def api_web_proofs_billing_portal(body: WebProofsPortalIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        url = web_access.proofs_billing_portal_url(token=body.token, return_url=body.return_url)
    except activation.ActivationError as e:
        return _activation_error(e, status=401)
    except stripe.error.StripeError as e:
        log.error("Proofs billing portal session failed: %s", e)
        return JSONResponse({"error": "stripe", "message": "Couldn't open the billing page right now."}, status_code=502)
    if url is None:
        return JSONResponse({"error": "no_billing", "message": "There's no billing to manage yet."}, status_code=404)
    return {"url": url}


@app.post("/api/web/preferences/get")
def api_web_preferences_get(body: WebTokenIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        return web_access.get_preferences(token=body.token)
    except activation.ActivationError as e:
        return _activation_error(e, status=401)


@app.post("/api/web/preferences/save")
def api_web_preferences_save(body: WebPreferencesIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        return web_access.save_preferences(token=body.token, preferences=body.preferences)
    except activation.ActivationError as e:
        return _activation_error(e, status=401 if e.code == "session_revoked" else 400)


@app.post("/api/web/projects/list")
def api_web_projects_list(body: WebTokenIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        return {"projects": web_access.list_projects(token=body.token)}
    except activation.ActivationError as e:
        return _activation_error(e, status=401)


@app.post("/api/web/projects/get")
def api_web_projects_get(body: WebTokenIn, id: str, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        project = web_access.get_project(token=body.token, project_id=id)
    except activation.ActivationError as e:
        return _activation_error(e, status=401)
    if project is None:
        return JSONResponse({"error": "not_found", "message": "That project doesn't exist."}, status_code=404)
    return project


@app.post("/api/web/projects/save")
def api_web_projects_save(body: WebProjectIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        return web_access.save_project(token=body.token, project_id=body.id, name=body.name, document=body.document)
    except activation.ActivationError as e:
        return _activation_error(e, status=401 if e.code == "session_revoked" else 400)


@app.post("/api/web/projects/delete")
def api_web_projects_delete(body: WebTokenIn, id: str, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        return {"deleted": web_access.delete_project(token=body.token, project_id=id)}
    except activation.ActivationError as e:
        return _activation_error(e, status=401)


@app.post("/api/web/feedback")
def api_web_feedback(body: WebFeedbackIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        return web_access.submit_feedback(
            token=body.token, note=body.note, design_name=body.design_name, stitch_count=body.stitch_count,
            original_image_base64=body.original_image_base64, original_image_type=body.original_image_type,
            digitized_image_base64=body.digitized_image_base64, digitized_image_type=body.digitized_image_type,
        )
    except activation.ActivationError as e:
        return _activation_error(e, status=401 if e.code == "session_revoked" else 400)


# -------------------------------------------------------- stripe webhook ---


@app.post("/webhooks/stripe")
async def stripe_webhook(request: Request):
    payload = await request.body()
    sig_header = request.headers.get("stripe-signature")
    try:
        event = stripe_client.construct_webhook_event(payload, sig_header)
    except (ValueError, stripe.error.SignatureVerificationError) as e:
        log.warning("Rejected webhook with invalid signature: %s", e)
        return HTMLResponse(status_code=400, content="invalid signature")

    if db.stripe_event_already_processed(event["id"]):
        return {"received": True, "duplicate": True}

    kind = event["type"]
    # A thin (v2) event -- the dashboard's default flavour since 2025 --
    # carries no object, only a pointer to fetch. This service subscribes
    # to snapshot events; a thin one that arrives anyway is acknowledged
    # and logged so Stripe does not retry it for three days.
    if kind.startswith("v2.") or "object" not in (event.get("data") or {}):
        log.warning("Webhook %s is a thin event (%s); this endpoint expects snapshot events -- check the endpoint's event selection", event["id"], kind)
        db.record_stripe_event(event["id"], kind)
        return {"received": True, "ignored": "thin event"}
    obj = event["data"]["object"]
    try:
        if kind == "checkout.session.completed":
            _fulfill_checkout(obj, stripe_event_id=event["id"])
        elif kind in ("customer.subscription.created", "customer.subscription.updated", "customer.subscription.deleted"):
            subscriptions.sync_from_stripe(dict(obj), stripe_event_id=event["id"])
        elif kind == "invoice.paid":
            subscriptions.record_invoice(dict(obj), paid=True, stripe_event_id=event["id"])
        elif kind == "invoice.payment_failed":
            subscriptions.record_invoice(dict(obj), paid=False, stripe_event_id=event["id"])
        elif kind == "charge.refunded":
            subscriptions.record_refund(dict(obj), stripe_event_id=event["id"])
        elif kind == "charge.dispute.created":
            charge = obj.get("charge")
            charge_obj = dict(charge) if isinstance(charge, dict) else {"id": charge, "invoice": None, "amount": obj.get("amount"), "created": obj.get("created")}
            if not charge_obj.get("invoice") and charge_obj.get("id"):
                try:
                    charge_obj = dict(stripe.Charge.retrieve(charge_obj["id"]))
                except stripe.error.StripeError as e:
                    log.error("Dispute %s: could not fetch charge %s: %s", event["id"], charge_obj["id"], e)
            subscriptions.record_refund(charge_obj, stripe_event_id=event["id"], dispute=True)
    except ValueError as e:
        # A subscription we can't tie to any customer — log loudly, but
        # ack so Stripe doesn't retry forever; the admin's "Sync from
        # Stripe" button can repair it once the customer record exists.
        # The failure is kept on the event row so the Partners page can
        # list it (§8 alerts).
        log.error("Webhook %s (%s) could not be applied: %s", event["id"], kind, e)
        db.record_stripe_event(event["id"], kind, result=str(e) or "could not be applied")
        return {"received": True, "error": str(e)}
    db.record_stripe_event(event["id"], kind)
    return {"received": True}


def _fulfill_checkout(session: dict, *, stripe_event_id: Optional[str]) -> None:
    session_id = session["id"]
    if session.get("mode") != "subscription":
        return
    existing = db.get_checkout_session(session_id)
    if existing and existing["status"] == "completed":
        return
    metadata = session.get("metadata") or {}
    stripe_sub_id = session.get("subscription") if isinstance(session.get("subscription"), str) else (session.get("subscription") or {}).get("id")
    if not stripe_sub_id:
        db.mark_checkout_failed(session_id, "Checkout completed without a subscription id.")
        return
    try:
        sub = stripe_client.retrieve_subscription(stripe_sub_id)
    except stripe.error.StripeError as e:
        log.error("Could not retrieve subscription %s after checkout: %s", stripe_sub_id, e)
        db.mark_checkout_failed(session_id, str(e))
        return
    email_hint = metadata.get("customer_email") or (session.get("customer_details") or {}).get("email") or ""
    name_hint = metadata.get("customer_name") or (session.get("customer_details") or {}).get("name") or ""
    subscriptions.sync_from_stripe(dict(sub), stripe_event_id=stripe_event_id, email_hint=email_hint, name_hint=name_hint)
    db.mark_checkout_completed(session_id)


@app.post("/webhooks/inbound-email/{token}")
async def inbound_email(token: str, request: Request):
    """Replies to recruitment email, delivered by the mail provider's
    inbound stream (Postmark's shape). The token in the path is the only
    thing standing between this and the open internet, so an unset token
    means no endpoint at all, and anything we can't match to someone we
    wrote to is dropped rather than stored."""
    if not config.INBOUND_EMAIL_TOKEN or not hmac.compare_digest(token, config.INBOUND_EMAIL_TOKEN):
        raise HTTPException(status_code=404)
    try:
        payload = await request.json()
    except ValueError:
        raise HTTPException(status_code=400, detail="expected JSON")
    sender = ((payload.get("FromFull") or {}).get("Email") or payload.get("From") or "").strip().lower()
    if "<" in sender:                                  # "Kathleen <kath@example.com>"
        sender = sender.split("<", 1)[1].split(">")[0].strip()
    body = payload.get("StrippedTextReply") or payload.get("TextBody") or ""
    reply_id = partners.inbound_reply(from_email=sender, subject=payload.get("Subject") or "", body=body)
    if reply_id is None:
        log.info("Inbound email from %s did not match anyone we wrote to; ignored.", sender or "(no sender)")
        return {"received": True, "matched": False}
    return {"received": True, "matched": True}


# ------------------------------------------------------- partner links ---


@app.get("/r/{code}", response_class=HTMLResponse)
def referral_link(request: Request, code: str, to: str = ""):
    """A partner's link (Partner Program §5.2): log the click, set the
    signed 90-day cookie for the whole piperstitch.com family, and show
    the partner's landing page -- or pass the visitor on to a marketing
    page with ?to=/path. An unknown or inactive code just goes home."""
    try:
        promo = promotions.validate(code)
    except promotions.PromoError:
        return RedirectResponse(config.WEBSITE_BASE_URL + "/", status_code=302)
    promoter = db.get_promoter(promo["promoter_id"]) if promo["promoter_id"] else None
    if promo["promoter_id"] and (promoter is None or promoter["status"] not in ("active", "approved") or not promoter["active"]):
        return RedirectResponse(config.WEBSITE_BASE_URL + "/", status_code=302)
    forwarded = request.headers.get("x-forwarded-for", "")
    ip = (forwarded.split(",")[0].strip() if forwarded else (request.client.host if request.client else "")) or ""
    referrals.record_click(promo["id"], ip=ip, user_agent=request.headers.get("user-agent", ""), landing_path=to or f"/r/{promo['code']}")
    path = referrals.safe_path(to)
    if path:
        response: Response = RedirectResponse(config.WEBSITE_BASE_URL + path, status_code=302)
    else:
        response = templates.TemplateResponse(request, "referral_landing.html", {**referrals.landing_context(promo), "config": config})
    domain = referrals.cookie_domain()
    response.set_cookie(referrals.COOKIE_NAME, referrals.cookie_value(promo["id"]), max_age=referrals.COOKIE_DAYS * 86400,
                        domain=domain or None, path="/", secure=config.PUBLIC_BASE_URL.startswith("https"), httponly=False, samesite="lax")
    return response


# ------------------------------------------------------- partner portal ---
# Magic links, like the customer account page: no password store.


def _portal_partner(request: Request):
    pid = request.session.get("partner_id")
    promoter = db.get_promoter(int(pid)) if pid else None
    if not partners.can_use_portal(promoter):
        request.session.pop("partner_id", None)
        return None
    return promoter


@app.get("/partners/portal", response_class=HTMLResponse)
def partner_portal(request: Request, message: str = "", error: str = ""):
    promoter = _portal_partner(request)
    if promoter is None:
        return templates.TemplateResponse(request, "partner_portal_request.html", {})
    ctx = partners.dashboard(promoter)
    ctx["payout"] = partners.payout_readiness(promoter)
    return templates.TemplateResponse(request, "partner_portal.html", {**ctx, "message": message or None, "error": error or None, "program": partners})


@app.post("/partners/portal", response_class=HTMLResponse)
def partner_portal_request_link(request: Request, email: str = Form(...)):
    """Enumeration-resistant like /account: the same page whether or not
    the address is a partner's."""
    if not ratelimit.allow(request):
        return templates.TemplateResponse(request, "partner_portal_request.html", {"error": _TOO_MANY, "email": email}, status_code=429)
    try:
        email = _validate_email(email)
    except ValueError:
        return templates.TemplateResponse(request, "partner_portal_request.html", {"error": "That doesn't look like an email address.", "email": email}, status_code=400)
    try:
        partners.send_portal_link(email)
    except email_sender.EmailSendError as e:
        log.error("Partner portal link email failed for %s: %s", email, e)
    return templates.TemplateResponse(request, "partner_portal_link_sent.html", {"email": email, "minutes": partners.LINK_TTL_MINUTES})


@app.get("/partners/portal/open")
def partner_portal_open(request: Request, token: str = ""):
    pid = partners.resolve_portal_link(token)
    if pid is None:
        return templates.TemplateResponse(request, "partner_portal_request.html", {"error": "That link has expired or was already used — request a new one below."}, status_code=400)
    request.session["partner_id"] = pid
    return RedirectResponse("/partners/portal", status_code=303)


@app.post("/partners/portal/logout")
def partner_portal_logout(request: Request):
    request.session.pop("partner_id", None)
    return RedirectResponse("/partners/portal", status_code=303)


@app.post("/partners/portal/codes")
def partner_portal_request_code(request: Request, code: str = Form(""), reason: str = Form("")):
    """A partner asking for another code -- usually one per channel."""
    promoter = _portal_partner(request)
    if promoter is None:
        return RedirectResponse("/partners/portal", status_code=303)
    try:
        partners.request_code(promoter, code=code, reason=reason)
    except (partners.PartnerError, promotions.PromoError) as e:
        return RedirectResponse("/partners/portal?error=" + quote_plus(e.message) + "#codes", status_code=303)
    return RedirectResponse("/partners/portal?message=" + quote_plus(f"Asked for {promotions.normalize_code(code)} — we'll set it up or come back to you, usually within a day.") + "#codes", status_code=303)


@app.post("/partners/portal/payout")
def partner_portal_payout(request: Request, method: str = Form("paypal"), payout_email: str = Form(""), payout_name: str = Form(""), payout_country: str = Form("")):
    promoter = _portal_partner(request)
    if promoter is None:
        return RedirectResponse("/partners/portal", status_code=303)
    try:
        partners.save_payout_details(promoter, method=method, payout_email=payout_email, payout_name=payout_name, payout_country=payout_country)
    except partners.PartnerError as e:
        return RedirectResponse("/partners/portal?error=" + quote_plus(e.message) + "#getting-paid", status_code=303)
    return RedirectResponse("/partners/portal?message=" + quote_plus("Payment details saved.") + "#getting-paid", status_code=303)


@app.post("/partners/portal/tax-form")
async def partner_portal_tax_form(request: Request, kind: str = Form("w9"), document: UploadFile = File(...)):
    promoter = _portal_partner(request)
    if promoter is None:
        return RedirectResponse("/partners/portal", status_code=303)
    try:
        partners.store_document(promoter, kind=kind, filename=document.filename or "", content_type=(document.content_type or "").split(";")[0], raw=await document.read())
    except partners.PartnerError as e:
        return RedirectResponse("/partners/portal?error=" + quote_plus(e.message) + "#getting-paid", status_code=303)
    return RedirectResponse("/partners/portal?message=" + quote_plus("Got it — we'll check it over and your portal will say when it's accepted.") + "#getting-paid", status_code=303)


@app.post("/partners/portal/feedback")
def partner_portal_feedback(request: Request, topic: str = Form(""), message: str = Form("")):
    promoter = _portal_partner(request)
    if promoter is None:
        return RedirectResponse("/partners/portal", status_code=303)
    try:
        partners.submit_feedback(promoter, topic=topic, message=message)
    except partners.PartnerError as e:
        return RedirectResponse("/partners/portal?error=" + quote_plus(e.message) + "#feedback", status_code=303)
    return RedirectResponse("/partners/portal?message=" + quote_plus("Thank you — that's with us, and a person reads every one.") + "#feedback", status_code=303)


@app.get("/partners/portal/qr/{code}.svg")
def partner_portal_qr(request: Request, code: str):
    promoter = _portal_partner(request)
    promo = db.get_promotion_by_code(code)
    if promoter is None or promo is None or promo["promoter_id"] != promoter["id"]:
        raise HTTPException(status_code=404)
    svg = partners.qr_svg(partners.link_url(promo["code"]))
    if svg is None:
        raise HTTPException(status_code=404)
    return Response(svg, media_type="image/svg+xml", headers={"Content-Disposition": f'inline; filename="piperstitch-{promo["code"]}-qr.svg"', "Cache-Control": "private, max-age=86400"})


@app.get("/partners/portal/statements/{period}.csv")
def partner_portal_statement(request: Request, period: str):
    promoter = _portal_partner(request)
    if promoter is None or not re.match(r"^\d{4}-\d{2}$", period):
        raise HTTPException(status_code=404)
    return Response(partners.statement_csv(promoter, period), media_type="text/csv", headers={"Content-Disposition": f'attachment; filename="piperstitch-partner-statement-{period}.csv"'})


def _program_reader(request: Request):
    """Who may read the program details: someone who registered (or
    followed a link we sent), or a partner already signed in to the
    portal. Returns (prospect_row_or_None, allowed)."""
    token = request.query_params.get("k", "")
    if token:
        pid = partners.resolve_program_token(token)
        if pid is not None:
            request.session["partner_prospect_id"] = pid
    pid = request.session.get("partner_prospect_id")
    prospect = db.get_partner_prospect(int(pid)) if pid else None
    if prospect is not None:
        return prospect, True
    request.session.pop("partner_prospect_id", None)
    return None, _portal_partner(request) is not None


def _program_gate(request: Request, error: str = "", form: Optional[dict] = None, status: int = 200) -> HTMLResponse:
    return templates.TemplateResponse(request, "partner_gate.html", {"error": error or None, "form": form or {}, "program": partners}, status_code=status)


@app.get("/partners/program", response_class=HTMLResponse)
def partner_program(request: Request, k: str = "", welcome: str = ""):
    """The full program: rates, the bounty, payouts and the terms. Kept
    off the public site (it is money, not marketing) -- a short
    registration or a link we sent opens it."""
    prospect, allowed = _program_reader(request)
    if not allowed:
        return _program_gate(request)
    if k and prospect is not None:
        return RedirectResponse("/partners/program", status_code=303)
    if prospect is not None:
        db.touch_partner_prospect(prospect["id"])
    return templates.TemplateResponse(request, "partner_program.html", {
        **partners.prospect_context(prospect), "program": partners, "welcome": bool(welcome),
        "trial_days": partners.OFFER_TRIAL_DAYS, "proofs": partners.OFFER_PROOFS,
    })


@app.get("/partners/video", response_class=HTMLResponse)
def partner_video(request: Request, k: str = ""):
    """The two-minute introduction, straight from a recruitment email:
    one click, nothing to fill in, and it counts as having opened
    something so the approach can be judged."""
    prospect, _ = _program_reader(request)
    if prospect is not None:
        db.touch_partner_prospect(prospect["id"])
    return templates.TemplateResponse(request, "partner_watch.html", {
        "p": prospect, "details_url": "/partners/program", "program": partners,
    })


@app.post("/partners/register", response_class=HTMLResponse)
def partner_register(request: Request, name: str = Form(""), email: str = Form(""), organization: str = Form(""), platforms: str = Form(""), website: str = Form("")):
    """The short registration in front of the program details. It is a
    doorway, not a wall: they are in as soon as they tell us who they
    are, and the same link reaches them by email."""
    if not ratelimit.allow(request):
        return _program_gate(request, error=_TOO_MANY, form={"name": name, "email": email}, status=429)
    if website.strip():                      # honeypot
        return RedirectResponse("/partners/program", status_code=303)
    form = {"name": name, "email": email, "organization": organization, "platforms": platforms}
    try:
        prospect_id = partners.register_prospect(name=name, email=email, organization=organization, platforms=platforms)
    except partners.PartnerError as e:
        return _program_gate(request, error=e.message, form=form, status=400)
    if config.PARTNER_PROGRAM_VERIFY_EMAIL:
        return templates.TemplateResponse(request, "partner_program_link_sent.html", {"email": email.strip().lower(), "days": partners.PROGRAM_TOKEN_DAYS})
    request.session["partner_prospect_id"] = prospect_id
    return RedirectResponse("/partners/program?welcome=1", status_code=303)


@app.get("/partners/terms", response_class=HTMLResponse)
def partner_terms(request: Request, k: str = ""):
    prospect, allowed = _program_reader(request)
    if not allowed:
        return _program_gate(request)
    return templates.TemplateResponse(request, "partner_terms.html", {"program": partners})


@app.get("/partners/no-thanks", response_class=HTMLResponse)
def partner_opt_out(request: Request, k: str = ""):
    """One click and we stop. No sign-in, no form, no "are you sure"."""
    prospect = partners.opt_out(k)
    return templates.TemplateResponse(request, "partner_opt_out.html", {"prospect": prospect})


@app.get("/partners/apply", response_class=HTMLResponse)
def partner_apply_form(request: Request):
    prospect, allowed = _program_reader(request)
    if not allowed:
        return _program_gate(request)
    form = {"name": prospect["name"], "email": prospect["email"], "organization": prospect["organization"], "platforms": prospect["platforms"]} if prospect else {}
    return templates.TemplateResponse(request, "partner_apply.html", {"form": form, "seats_left": partners.founding_seats_left(), "program": partners})


@app.post("/partners/apply", response_class=HTMLResponse)
def partner_apply_submit(request: Request, name: str = Form(""), email: str = Form(""), organization: str = Form(""), platforms: str = Form(""), application: str = Form(""),
                         has_social: str = Form(""), handles: str = Form(""), agree: str = Form(""), website: str = Form("")):
    """The public application (spec §8). `website` is a honeypot: real
    people never see it."""
    prospect, allowed = _program_reader(request)
    if not allowed:
        return _program_gate(request)
    if not ratelimit.allow(request):
        return templates.TemplateResponse(request, "partner_apply.html", {"form": {"name": name, "email": email}, "error": _TOO_MANY,
                                                                          "seats_left": partners.founding_seats_left(), "program": partners}, status_code=429)
    form = {"name": name, "email": email, "organization": organization, "platforms": platforms, "application": application, "has_social": has_social, "handles": handles}
    if website.strip():
        return templates.TemplateResponse(request, "partner_applied.html", {"email": email})
    if has_social and not handles.strip():
        return templates.TemplateResponse(request, "partner_apply.html", {"form": form, "error": "Pop in your handles or links so we can have a look at what you post.",
                                                                          "seats_left": partners.founding_seats_left(), "program": partners}, status_code=400)
    if not agree:
        return templates.TemplateResponse(request, "partner_apply.html", {"form": form, "error": "Please read and agree to the partner terms.", "seats_left": partners.founding_seats_left(), "program": partners}, status_code=400)
    try:
        partners.apply(name=name, email=email, organization=organization, platforms=platforms, application=application, handles=handles if has_social else "")
    except partners.PartnerError as e:
        return templates.TemplateResponse(request, "partner_apply.html", {"form": form, "error": e.message, "seats_left": partners.founding_seats_left(), "program": partners}, status_code=400)
    return templates.TemplateResponse(request, "partner_applied.html", {"email": email.strip().lower()})


# ---------------------------------------------------------------- admin ---


@app.get("/admin/login", response_class=HTMLResponse)
def login_form(request: Request):
    return templates.TemplateResponse(request, "login.html", {})


@app.post("/admin/login")
def login_submit(request: Request, username: str = Form(...), password: str = Form(...)):
    if auth.is_locked_out(request):
        return templates.TemplateResponse(request, "login.html", {"error": "Too many attempts — try again in a few minutes."}, status_code=429)
    if not auth.try_login(request, username, password):
        return templates.TemplateResponse(request, "login.html", {"error": "Incorrect username or password."}, status_code=401)
    return RedirectResponse("/admin", status_code=303)


@app.post("/admin/logout")
def logout_submit(request: Request):
    auth.logout(request)
    return RedirectResponse("/admin/login", status_code=303)


@app.get("/admin", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def dashboard(request: Request):
    return templates.TemplateResponse(request, "dashboard.html", {
        "active_nav": "dashboard",
        "counts": db.subscriber_counts(),
        "download_counts": db.count_downloads(),
        "pending_checkout_count": len(db.list_pending_checkouts()),
        "recent_events": db.recent_events(),
        "latest_update": db.latest_published_update(),
    })


@app.get("/admin/subscribers", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def subscribers(request: Request, q: str = "", status: str = "", product: str = "", message: str = "", error: str = ""):
    return templates.TemplateResponse(request, "subscribers.html", {
        "active_nav": "subscribers",
        "subscriptions": db.list_subscriptions(q, status=status, product=product),
        "pending_checkouts": db.list_pending_checkouts(),
        "query": q,
        "status": status,
        "product": product,
        "message": message or None,
        "error": error or None,
    })


@app.get("/admin/registrations", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def registrations(request: Request, q: str = "", message: str = "", error: str = ""):
    return templates.TemplateResponse(request, "registrations.html", {
        "active_nav": "registrations",
        "customers": db.list_customers(q),
        "query": q,
        "message": message or None,
        "error": error or None,
    })


def _customer_redirect(customer_id: int, *, message: str = "", error: str = "") -> RedirectResponse:
    param = f"error={quote_plus(error)}" if error else f"message={quote_plus(message)}"
    return RedirectResponse(f"/admin/customers/{customer_id}?{param}", status_code=303)


@app.get("/admin/customers/{customer_id}", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def customer_detail(request: Request, customer_id: int, message: str = "", error: str = ""):
    customer = db.get_customer(customer_id)
    if customer is None:
        return RedirectResponse("/admin/subscribers", status_code=303)
    validity = subscriptions.validity_for(customer_id)
    trial_ends = None
    if customer["downloaded_at"]:
        trial_ends = (db.parse_iso(customer["downloaded_at"]) + timedelta(days=config.TRIAL_DAYS)).date().isoformat()
    return templates.TemplateResponse(request, "customer_detail.html", {
        "active_nav": "subscribers",
        "customer": customer,
        "validity": validity,
        "proofs": subscriptions.proofs_state(customer_id),
        "subscriptions": db.list_subscriptions_for_customer(customer_id),
        "devices": db.list_active_devices(customer_id),
        "web_sessions": db.list_active_web_sessions(customer_id),
        "projects": db.list_projects(customer_id),
        "redemptions": [dict(r, cycles_remaining=promotions.cycles_remaining(r), description=promotions.describe(r)) for r in db.list_redemptions_for_customer(customer_id)],
        "promo_payouts": db.list_promo_payouts_for_customer(customer_id),
        "active_promotions": [p for p in db.list_promotions() if p["active"]],
        "describe": promotions.describe,
        "deliveries": db.list_deliveries_for_customer(customer_id),
        "email_log": db.list_email_log(customer_id),
        "sequence_options": db.list_sequences(),
        "payments": db.list_payments_for_customer(customer_id),
        "events": db.list_events_for_customer(customer_id),
        "trial_ends": trial_ends,
        "today": datetime.now(timezone.utc).date().isoformat(),
        "message": message or None,
        "error": error or None,
    })


@app.post("/admin/customers/{customer_id}/comp", dependencies=[Depends(auth.require_admin)])
def customer_comp(customer_id: int, months: str = Form("1"), until: str = Form(""), note: str = Form(""), send_email: str = Form(""), product: str = Form("core")):
    if db.get_customer(customer_id) is None:
        return RedirectResponse("/admin/subscribers", status_code=303)
    until_dt = None
    if until.strip():
        try:
            until_dt = datetime.fromisoformat(until.strip()).replace(hour=23, minute=59, second=59, tzinfo=timezone.utc)
        except ValueError:
            return _customer_redirect(customer_id, error="The end date must look like 2026-12-31.")
    months_n = int(months) if months.strip().isdigit() else 1
    product = "proofs" if product == "proofs" else "core"
    _, email_error = subscriptions.grant_comp(customer_id=customer_id, months=months_n, until=until_dt, note=note.strip(), send_email=bool(send_email), product=product)
    msg = "Complimentary PiperStitch Proofs granted." if product == "proofs" else "Complimentary access granted."
    if send_email:
        msg += " Email sent." if not email_error else f" Email NOT sent: {email_error}"
    return _customer_redirect(customer_id, message=msg)


@app.post("/admin/customers/{customer_id}/free-proofs", dependencies=[Depends(auth.require_admin)])
def customer_free_proofs(customer_id: int, count: str = Form("3")):
    if db.get_customer(customer_id) is None:
        return RedirectResponse("/admin/subscribers", status_code=303)
    n = int(count) if count.strip().lstrip("-").isdigit() else 0
    if n == 0:
        return _customer_redirect(customer_id, error="How many extra free proofs? A whole number, e.g. 3.")
    db.add_free_proofs(customer_id, n)
    db.add_event(customer_id=customer_id, subscription_id=None, kind="free_proofs", detail=f"{'+' if n > 0 else ''}{n} free proof{'s' if abs(n) != 1 else ''} (Proofs).")
    return _customer_redirect(customer_id, message=f"{n:+d} free proofs.")


@app.post("/admin/subscriptions/{subscription_id}/cancel", dependencies=[Depends(auth.require_admin)])
def subscription_cancel(subscription_id: int, when: str = Form("period_end")):
    sub = db.get_subscription(subscription_id)
    if sub is None:
        return RedirectResponse("/admin/subscribers", status_code=303)
    error = subscriptions.cancel(sub, at_period_end=(when != "now"))
    if error:
        return _customer_redirect(sub["customer_id"], error=error)
    return _customer_redirect(sub["customer_id"], message="Cancelled at the end of the current period." if when != "now" else "Cancelled immediately.")


@app.post("/admin/subscriptions/{subscription_id}/reactivate", dependencies=[Depends(auth.require_admin)])
def subscription_reactivate(subscription_id: int):
    sub = db.get_subscription(subscription_id)
    if sub is None:
        return RedirectResponse("/admin/subscribers", status_code=303)
    error = subscriptions.reactivate(sub)
    return _customer_redirect(sub["customer_id"], error=error or "", message="" if error else "Cancellation reversed — the subscription continues.")


@app.post("/admin/subscriptions/{subscription_id}/extend", dependencies=[Depends(auth.require_admin)])
def subscription_extend(subscription_id: int, until: str = Form(...)):
    sub = db.get_subscription(subscription_id)
    if sub is None:
        return RedirectResponse("/admin/subscribers", status_code=303)
    if sub["source"] != "manual":
        return _customer_redirect(sub["customer_id"], error="Only complimentary access can be extended here — a paid subscription's dates come from Stripe.")
    try:
        until_dt = datetime.fromisoformat(until.strip()).replace(hour=23, minute=59, second=59, tzinfo=timezone.utc)
    except ValueError:
        return _customer_redirect(sub["customer_id"], error="The end date must look like 2026-12-31.")
    subscriptions.extend_comp(sub, until=until_dt)
    if sub["status"] != "comp":
        db.update_subscription_status(subscription_id, status="comp", cancel_at_period_end=True)
    return _customer_redirect(sub["customer_id"], message=f"Extended through {until.strip()}.")


@app.post("/admin/subscriptions/{subscription_id}/sync", dependencies=[Depends(auth.require_admin)])
def subscription_sync(subscription_id: int):
    """Re-pulls one subscription from Stripe — the repair tool for a
    missed webhook."""
    sub = db.get_subscription(subscription_id)
    if sub is None:
        return RedirectResponse("/admin/subscribers", status_code=303)
    if not sub["stripe_subscription_id"]:
        return _customer_redirect(sub["customer_id"], error="This is complimentary access — there's nothing on Stripe to sync.")
    try:
        remote = stripe_client.retrieve_subscription(sub["stripe_subscription_id"])
        subscriptions.sync_from_stripe(dict(remote))
    except (stripe.error.StripeError, ValueError) as e:
        return _customer_redirect(sub["customer_id"], error=f"Sync failed: {e}")
    return _customer_redirect(sub["customer_id"], message="Synced from Stripe.")


@app.post("/admin/web-sessions/{session_row_id}/revoke", dependencies=[Depends(auth.require_admin)])
def admin_revoke_web_session(session_row_id: int):
    row = db.get_web_session(session_row_id)
    if row is None:
        return RedirectResponse("/admin/subscribers", status_code=303)
    db.revoke_web_session(session_row_id)
    db.add_event(customer_id=row["customer_id"], subscription_id=None, kind="web_signed_out", detail="A browser was signed out by the admin.")
    return _customer_redirect(row["customer_id"], message="That browser has been signed out.")


@app.post("/admin/devices/{device_row_id}/revoke", dependencies=[Depends(auth.require_admin)])
def admin_revoke_device(device_row_id: int):
    device = db.get_device(device_row_id)
    if device is None:
        return RedirectResponse("/admin/subscribers", status_code=303)
    db.revoke_device(device_row_id)
    db.add_event(customer_id=device["customer_id"], subscription_id=None, kind="device_signed_out", detail=f"Admin signed out {device['device_name'] or 'a Mac'}.")
    return _customer_redirect(device["customer_id"], message="That Mac has been signed out.")


@app.post("/admin/customers/{customer_id}/notes", dependencies=[Depends(auth.require_admin)])
def customer_notes(customer_id: int, notes: str = Form("")):
    db.set_customer_notes(customer_id, notes.strip())
    return _customer_redirect(customer_id, message="Notes saved.")


@app.post("/admin/customers/{customer_id}/resend-welcome", dependencies=[Depends(auth.require_admin)])
def customer_resend_welcome(customer_id: int):
    customer = db.get_customer(customer_id)
    if customer is None:
        return RedirectResponse("/admin/subscribers", status_code=303)
    try:
        email_sender.send_welcome_email(to_email=customer["email"], customer_name=customer["name"])
    except email_sender.EmailSendError as e:
        return _customer_redirect(customer_id, error=f"Send failed: {e}")
    db.add_event(customer_id=customer_id, subscription_id=None, kind="email", detail="Welcome email resent by admin.")
    return _customer_redirect(customer_id, message="Welcome email resent.")


@app.post("/admin/customers/{customer_id}/account-link", dependencies=[Depends(auth.require_admin)])
def customer_send_account_link(customer_id: int):
    customer = db.get_customer(customer_id)
    if customer is None:
        return RedirectResponse("/admin/subscribers", status_code=303)
    url = activation.create_account_link(customer_id)
    try:
        email_sender.send_account_link_email(to_email=customer["email"], url=url)
    except email_sender.EmailSendError as e:
        return _customer_redirect(customer_id, error=f"Send failed: {e}")
    db.add_event(customer_id=customer_id, subscription_id=None, kind="email", detail="Account-page link sent by admin.")
    return _customer_redirect(customer_id, message="Account-page link emailed.")


@app.get("/admin/customers/{customer_id}/email", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def email_customer_form(request: Request, customer_id: int):
    customer = db.get_customer(customer_id)
    if customer is None:
        return RedirectResponse("/admin/subscribers", status_code=303)
    validity = subscriptions.validity_for(customer_id)
    if validity.entitled:
        default_subject = "How's PiperStitch working for you?"
        default_body = f"Hi {customer['name'] or 'there'},\n\nJust checking in — how is PiperStitch working out? If anything's getting in your way, reply and tell me; I read every message.\n\n-- PiperStitch"
    else:
        default_subject = "Still thinking about PiperStitch?"
        default_body = (
            f"Hi {customer['name'] or 'there'},\n\n"
            f"You downloaded PiperStitch a little while ago — just checking in to see how the trial went. Whenever you're ready, it's {_price_label()} a month, cancel any time:\n"
            f"{config.WEBSITE_BASE_URL}/pricing.html\n\nHappy to answer any questions — just reply.\n\n-- PiperStitch"
        )
    return templates.TemplateResponse(request, "email_customer.html", {"customer": customer, "default_subject": default_subject, "default_body": default_body, "active_nav": "subscribers"})


@app.post("/admin/customers/{customer_id}/email", dependencies=[Depends(auth.require_admin)])
def email_customer_submit(request: Request, customer_id: int, subject: str = Form(...), body: str = Form(...)):
    customer = db.get_customer(customer_id)
    if customer is None:
        return RedirectResponse("/admin/subscribers", status_code=303)
    try:
        email_sender.send_plain_email(to_email=customer["email"], subject=subject, body=body)
    except email_sender.EmailSendError as e:
        return templates.TemplateResponse(request, "email_customer.html", {"customer": customer, "default_subject": subject, "default_body": body, "error": f"Send failed: {e}", "active_nav": "subscribers"}, status_code=502)
    db.record_reminder_sent(customer_id)
    db.add_event(customer_id=customer_id, subscription_id=None, kind="email", detail=f"Email sent: {subject}")
    return _customer_redirect(customer_id, message=f"Email sent to {customer['email']}.")


@app.post("/admin/customers/{customer_id}/delete", dependencies=[Depends(auth.require_admin)])
def delete_customer(customer_id: int):
    record = db.get_customer(customer_id)
    if record is None:
        return RedirectResponse("/admin/registrations", status_code=303)
    validity = subscriptions.validity_for(customer_id)
    if validity.entitled and validity.status != "comp":
        return _customer_redirect(customer_id, error="This customer has a live paid subscription — cancel it first, so nobody keeps being charged for a record that no longer exists.")
    db.delete_customer(customer_id)
    return RedirectResponse(f"/admin/registrations?message={quote_plus('Deleted ' + record['email'] + '.')}", status_code=303)


@app.get("/admin/export.csv", dependencies=[Depends(auth.require_admin)])
def export_csv():
    rows = db.all_subscriptions_for_export()
    buffer = io.StringIO()
    writer = csv.writer(buffer)
    writer.writerow(["id", "customer_name", "customer_email", "status", "source", "stripe_subscription_id", "current_period_end", "cancel_at_period_end", "amount_cents", "created_at", "ended_at", "notes"])
    for r in rows:
        writer.writerow([r["id"], r["customer_name"], r["customer_email"], r["status"], r["source"], r["stripe_subscription_id"], r["current_period_end"], r["cancel_at_period_end"], r["amount_cents"], r["created_at"], r["ended_at"], r["notes"]])
    buffer.seek(0)
    return StreamingResponse(buffer, media_type="text/csv", headers={"Content-Disposition": "attachment; filename=piperstitch_subscriptions.csv"})


# ---------------------------------------------------------------- emails ---
# Every email the system sends is editable here, and the drip sequences
# (trial, subscriber, win-back) with their steps. See emails.py.


def _emails_redirect(*, message: str = "", error: str = "", anchor: str = "") -> RedirectResponse:
    q = []
    if message: q.append("message=" + quote_plus(message))
    if error: q.append("error=" + quote_plus(error))
    return RedirectResponse("/admin/emails" + ("?" + "&".join(q) if q else "") + (f"#{anchor}" if anchor else ""), status_code=303)


@app.get("/admin/emails", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def admin_emails(request: Request, message: str = "", error: str = ""):
    emails.seed()
    sequences = []
    for seq in db.list_sequences():
        sequences.append({"row": seq, "steps": db.list_sequence_steps(seq["id"])})
    all_templates = db.list_email_templates()
    by_key = {t["key"]: t for t in all_templates}
    outreach_keys = [s["key"] for s in partners.OUTREACH_STEPS]
    return templates.TemplateResponse(request, "emails.html", {
        "active_nav": "emails",
        "customer_templates": [t for t in all_templates if not t["key"].startswith("partner_")],
        "partner_templates": [t for t in all_templates if t["key"].startswith("partner_") and t["key"] not in outreach_keys],
        "outreach_series": [dict(step, template=by_key[step["key"]]) for step in partners.OUTREACH_STEPS if step["key"] in by_key],
        "sequences": sequences,
        "stats": {s["key"]: s for s in db.sequence_stats()},
        "message": message or None, "error": error or None,
    })


@app.get("/admin/emails/system/{key}", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def admin_email_edit(request: Request, key: str, message: str = "", error: str = ""):
    row = db.get_email_template(key)
    if row is None:
        return _emails_redirect(error="That email doesn't exist.")
    sample = {"id": 0, "name": "Jane Example", "email": "jane@example.com", "marketing_opt_out": 0}
    extra = {"code": "123456", "code_minutes": config.ACTIVATION_CODE_TTL_MINUTES, "device": "", "link_line": "", "sign_in_url": "", "url": f"{config.PUBLIC_BASE_URL}/account/open?token=example",
             "link_minutes": config.ACCOUNT_LINK_TTL_MINUTES, "grace_days": config.ENTITLEMENT_GRACE_DAYS, "ends_on": "2026-12-31", "until": "2026-12-31", "note": "",
             "sender_name": "Jane Example", "sender_email": "jane@example.com", "filename": "logo.dst", "note_block": ""}
    subject, body, html = emails.render_template(row, emails.variables(sample, **extra))
    return templates.TemplateResponse(request, "email_edit.html", {
        "active_nav": "emails", "kind": "system", "row": row, "preview_subject": subject, "preview_body": body, "preview_html": html,
        "back": "/admin/emails", "message": message or None, "error": error or None,
    })


@app.post("/admin/emails/system/{key}", dependencies=[Depends(auth.require_admin)])
def admin_email_save(key: str, subject: str = Form(...), body: str = Form(...), cta_label: str = Form(""), cta_url: str = Form(""), preheader: str = Form(""), action: str = Form("save")):
    if db.get_email_template(key) is None:
        return _emails_redirect(error="That email doesn't exist.")
    if action == "reset":
        db.reset_email_template(key); emails.seed()
        return RedirectResponse(f"/admin/emails/system/{key}?message=" + quote_plus("Reset to the default text."), status_code=303)
    if not subject.strip() or not body.strip():
        return RedirectResponse(f"/admin/emails/system/{key}?error=" + quote_plus("Subject and body are required."), status_code=303)
    db.update_email_template(key, subject=subject.strip(), body=body.replace("\r\n", "\n"), cta_label=cta_label.strip(), cta_url=cta_url.strip(), preheader=preheader.strip())
    return RedirectResponse(f"/admin/emails/system/{key}?message=" + quote_plus("Saved. Every future send uses this text."), status_code=303)


@app.post("/admin/emails/system/{key}/test", dependencies=[Depends(auth.require_admin)])
def admin_email_test(key: str, to_email: str = Form(...)):
    row = db.get_email_template(key)
    if row is None:
        return _emails_redirect(error="That email doesn't exist.")
    sample = {"id": 0, "name": "Jane Example", "email": to_email, "marketing_opt_out": 0}
    extra = {"code": "123456", "code_minutes": config.ACTIVATION_CODE_TTL_MINUTES, "device": "", "link_line": "", "url": f"{config.PUBLIC_BASE_URL}/account", "link_minutes": config.ACCOUNT_LINK_TTL_MINUTES,
             "grace_days": config.ENTITLEMENT_GRACE_DAYS, "ends_on": "2026-12-31", "until": "2026-12-31", "note": "", "sender_name": "Jane Example", "sender_email": to_email, "filename": "logo.dst", "note_block": ""}
    hero, hero_alt = "", ""
    if key.startswith("partner_"):
        # The partner emails have placeholders of their own; a test that
        # shows "{code}" tells you nothing about how the real one reads.
        extra.update({"code": "JANE", "link": partners.link_url("JANE"), "portal_link": f"{config.PUBLIC_BASE_URL}/partners/portal",
                      "tier": "Founding partner", "share_pct": f"{partners.FOUNDING_SHARE:g}", "amount": "$186.40", "paid_at": date.today().isoformat(),
                      "method": "PayPal", "payout_email": to_email, "title": "Digitizing a cap logo, start to finish",
                      "description_line": "\n\nTwo minutes: artwork in, machine file out.", "kind": "video", "reason": "My YouTube channel",
                      "note": "Page 2 isn't signed.", "link_days": partners.PROGRAM_TOKEN_DAYS,
                      "url": f"{config.PUBLIC_BASE_URL}/partners/program?k=sample", "apply_url": f"{config.PUBLIC_BASE_URL}/partners/apply?k=sample",
                      "opt_out_url": f"{config.PUBLIC_BASE_URL}/partners/no-thanks?k=sample"})
        if key == "partner_welcome":
            hero, hero_alt = f"{config.WEBSITE_BASE_URL}{email_sender.PIPER_CONGRATULATIONS}", "Piper the sandpiper, mid-hop, with confetti"
    try:
        emails.send_system(key, to_email=to_email, vars=emails.variables(sample, **extra), hero_image=hero, hero_alt=hero_alt)
    except email_sender.EmailSendError as e:
        return RedirectResponse(f"/admin/emails/system/{key}?error=" + quote_plus(f"Test not sent: {e}"), status_code=303)
    return RedirectResponse(f"/admin/emails/system/{key}?message=" + quote_plus(f"Test sent to {to_email}."), status_code=303)


@app.post("/admin/emails/sequences/{sequence_id}/toggle", dependencies=[Depends(auth.require_admin)])
def admin_sequence_toggle(sequence_id: int):
    seq = db.get_sequence_by_id(sequence_id)
    if seq is None:
        return _emails_redirect(error="That sequence doesn't exist.")
    db.set_sequence_active(sequence_id, not seq["active"])
    return _emails_redirect(message=f"{seq['name']} {'paused — nothing more will be sent until it is resumed' if seq['active'] else 'resumed'}.", anchor=f"seq-{seq['key']}")


@app.post("/admin/emails/sequences/{sequence_id}/steps", dependencies=[Depends(auth.require_admin)])
def admin_step_add(sequence_id: int, delay_days: str = Form(...), name: str = Form(...), subject: str = Form(...), body: str = Form(...), cta_label: str = Form(""), cta_url: str = Form("")):
    seq = db.get_sequence_by_id(sequence_id)
    if seq is None:
        return _emails_redirect(error="That sequence doesn't exist.")
    if not delay_days.strip().isdigit() or not name.strip() or not subject.strip() or not body.strip():
        return _emails_redirect(error="A step needs a day number, a name, a subject and a body.", anchor=f"seq-{seq['key']}")
    step_id = db.add_sequence_step(sequence_id=sequence_id, delay_days=int(delay_days), name=name, subject=subject.strip(), body=body.replace("\r\n", "\n"), cta_label=cta_label.strip(), cta_url=cta_url.strip())
    return RedirectResponse(f"/admin/emails/steps/{step_id}?message=" + quote_plus("Step added. Customers already in the sequence keep their existing schedule; new enrolments include it."), status_code=303)


@app.get("/admin/emails/steps/{step_id}", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def admin_step_edit(request: Request, step_id: int, message: str = "", error: str = ""):
    step = db.get_sequence_step(step_id)
    if step is None:
        return _emails_redirect(error="That step doesn't exist.")
    seq = db.get_sequence_by_id(step["sequence_id"])
    sample = {"id": 0, "name": "Jane Example", "email": "jane@example.com", "marketing_opt_out": 0}
    subject, body, html = emails.render_template(step, emails.variables(sample, trial_ends="2026-12-31"), marketing=True)
    return templates.TemplateResponse(request, "email_edit.html", {
        "active_nav": "emails", "kind": "step", "row": step, "sequence": seq, "preview_subject": subject, "preview_body": body, "preview_html": html,
        "back": f"/admin/emails#seq-{seq['key']}", "message": message or None, "error": error or None,
    })


@app.post("/admin/emails/steps/{step_id}", dependencies=[Depends(auth.require_admin)])
def admin_step_save(step_id: int, delay_days: str = Form(...), name: str = Form(...), subject: str = Form(...), body: str = Form(...), cta_label: str = Form(""), cta_url: str = Form(""), active: str = Form(""), action: str = Form("save")):
    step = db.get_sequence_step(step_id)
    if step is None:
        return _emails_redirect(error="That step doesn't exist.")
    seq = db.get_sequence_by_id(step["sequence_id"])
    if action == "delete":
        db.delete_sequence_step(step_id)
        return _emails_redirect(message=f"Step “{step['name']}” deleted (its unsent emails were cancelled).", anchor=f"seq-{seq['key']}")
    if not delay_days.strip().isdigit() or not name.strip() or not subject.strip() or not body.strip():
        return RedirectResponse(f"/admin/emails/steps/{step_id}?error=" + quote_plus("A step needs a day number, a name, a subject and a body."), status_code=303)
    db.update_sequence_step(step_id, delay_days=int(delay_days), name=name, subject=subject.strip(), body=body.replace("\r\n", "\n"), cta_label=cta_label.strip(), cta_url=cta_url.strip(), active=bool(active))
    return RedirectResponse(f"/admin/emails/steps/{step_id}?message=" + quote_plus("Saved. Unsent emails use the new text."), status_code=303)


@app.post("/admin/emails/steps/{step_id}/test", dependencies=[Depends(auth.require_admin)])
def admin_step_test(step_id: int, to_email: str = Form(...)):
    step = db.get_sequence_step(step_id)
    if step is None:
        return _emails_redirect(error="That step doesn't exist.")
    sample = {"id": 0, "name": "Jane Example", "email": to_email, "marketing_opt_out": 0}
    subject, body, html = emails.render_template(step, emails.variables(sample, trial_ends="2026-12-31"), marketing=True)
    try:
        email_sender._send_smtp(email_sender._compose(to_email=to_email, subject=subject, body=body, html_body=html))
    except email_sender.EmailSendError as e:
        return RedirectResponse(f"/admin/emails/steps/{step_id}?error=" + quote_plus(f"Test not sent: {e}"), status_code=303)
    return RedirectResponse(f"/admin/emails/steps/{step_id}?message=" + quote_plus(f"Test sent to {to_email}."), status_code=303)


@app.post("/admin/emails/run-now", dependencies=[Depends(auth.require_admin)])
def admin_emails_run_now():
    result = emails.run_scheduled_work()
    return _emails_redirect(message=f"Ran the scheduler: {result['sent']} email(s) sent, {result['winback']} win-back(s) started.")


# per-customer sequence controls (on the customer page)

@app.post("/admin/customers/{customer_id}/sequences/enroll", dependencies=[Depends(auth.require_admin)])
def admin_customer_enroll(customer_id: int, sequence_key: str = Form(...)):
    if db.get_customer(customer_id) is None:
        return RedirectResponse("/admin/subscribers", status_code=303)
    n = emails.enroll(customer_id, sequence_key, force=True)
    return _customer_redirect(customer_id, message=f"Enrolled: {n} email(s) scheduled from today." if n else "Nothing scheduled — that sequence has no active steps.")


@app.post("/admin/customers/{customer_id}/sequences/{sequence_key}/stop", dependencies=[Depends(auth.require_admin)])
def admin_customer_stop_sequence(customer_id: int, sequence_key: str):
    n = emails.skip_pending(customer_id, sequence_key, "stopped by admin")
    return _customer_redirect(customer_id, message=f"Stopped: {n} unsent email(s) cancelled.")


@app.post("/admin/deliveries/{delivery_id}/send", dependencies=[Depends(auth.require_admin)])
def admin_delivery_send(delivery_id: int):
    d = db.get_delivery(delivery_id)
    if d is None:
        return RedirectResponse("/admin/subscribers", status_code=303)
    customer = db.get_customer(d["customer_id"])
    if customer and customer["marketing_opt_out"]:
        return _customer_redirect(d["customer_id"], error="They've unsubscribed from tips, so sequence emails can't be sent to them.")
    ok = emails.send_delivery(delivery_id, by="admin")
    d2 = db.get_delivery(delivery_id)
    return _customer_redirect(d["customer_id"], message=f"Sent “{d['step_name']}”." if ok else "", error="" if ok else f"Not sent: {d2['note'] if d2 else 'unknown error'}")


@app.post("/admin/customers/{customer_id}/marketing", dependencies=[Depends(auth.require_admin)])
def admin_customer_marketing(customer_id: int, opt_out: str = Form("")):
    if db.get_customer(customer_id) is None:
        return RedirectResponse("/admin/subscribers", status_code=303)
    db.set_marketing_opt_out(customer_id, bool(opt_out))
    if opt_out:
        emails.stop_all_marketing(customer_id, "unsubscribed by admin")
    return _customer_redirect(customer_id, message="Unsubscribed from tip emails; pending ones cancelled." if opt_out else "Re-subscribed to tip emails. Use Enroll from today to restart a series.")


# public unsubscribe (link in every sequence email)

@app.get("/unsubscribe", response_class=HTMLResponse)
def unsubscribe(request: Request, c: int = 0, t: str = ""):
    customer = db.get_customer(c) if c else None
    ok = customer is not None and hmac.compare_digest(t, emails.unsubscribe_token(c))
    if ok:
        already = bool(customer["marketing_opt_out"])
        db.set_marketing_opt_out(c, True)
        emails.stop_all_marketing(c, "unsubscribed")
        if not already:
            db.add_event(customer_id=c, subscription_id=None, kind="unsubscribed", detail="Unsubscribed from tip emails via the link.")
            # Say plainly, in their inbox, that the subscription itself is untouched.
            try:
                emails.send_system("unsubscribe_confirmed", to_email=customer["email"], customer_id=c, vars=emails.variables(customer))
            except email_sender.EmailSendError as e:
                log.warning("Unsubscribe confirmation not sent to %s: %s", customer["email"], e)
    return templates.TemplateResponse(request, "unsubscribe.html", {"ok": ok})


# ---------------------------------------------------------- project view ---
# Support's look at a customer's saved project. The Privacy Policy allows
# staff to view saved projects only "when you ask us for help with a
# specific project" (or for abuse/security/legal), so the page requires a
# reason and every view is written to the customer's timeline.


@app.get("/admin/customers/{customer_id}/projects/{project_id}", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def admin_project_gate(request: Request, customer_id: int, project_id: str):
    customer = db.get_customer(customer_id)
    project = db.get_project(customer_id, project_id) if customer else None
    if project is None:
        return _customer_redirect(customer_id, error="That project doesn't exist.")
    return templates.TemplateResponse(request, "project_gate.html", {"active_nav": "subscribers", "customer": customer, "project": project})


@app.post("/admin/customers/{customer_id}/projects/{project_id}", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def admin_project_view(request: Request, customer_id: int, project_id: str, reason: str = Form(""), basis: str = Form("support")):
    customer = db.get_customer(customer_id)
    project = db.get_project(customer_id, project_id) if customer else None
    if project is None:
        return _customer_redirect(customer_id, error="That project doesn't exist.")
    if len(reason.strip()) < 8:
        return templates.TemplateResponse(request, "project_gate.html", {"active_nav": "subscribers", "customer": customer, "project": project, "error": "Say why you're opening it — a sentence is enough. It's recorded on the customer's timeline."}, status_code=400)
    basis_label = {"support": "customer asked for help", "abuse": "abuse / security investigation", "legal": "legal requirement"}.get(basis, "customer asked for help")
    db.add_event(customer_id=customer_id, subscription_id=None, kind="project_viewed", detail=f"Admin opened saved project “{project['name']}” ({basis_label}): {reason.strip()[:300]}")
    document = json.loads(project["document"]) if isinstance(project["document"], str) else project["document"]
    digitized = project_view.digitize(document)
    return templates.TemplateResponse(request, "project_view.html", {
        "active_nav": "subscribers", "customer": customer, "project": project, "document": document,
        "outlines_svg": project_view.outlines_svg(document),
        "plan_svg": project_view.plan_svg(document, digitized) if digitized else None,
        "digitized": digitized, "objects": project_view.object_rows(document),
        "fabric": (document.get("objects") or [{}])[0].get("parameters", {}).get("fabricType", "standard") if document.get("objects") else "standard",
        "reason": reason.strip(),
    })


# ----------------------------------------------------------- promotions ---
# Promoter referral codes with revenue share, and direct discounts. Every
# code is a Stripe coupon + promotion code created from here; the admin
# never needs the Stripe Dashboard for any of it. See promotions.py.


def _promotions_redirect(*, message: str = "", error: str = "", anchor: str = "") -> RedirectResponse:
    q = []
    if message: q.append("message=" + quote_plus(message))
    if error: q.append("error=" + quote_plus(error))
    return RedirectResponse("/admin/promotions" + ("?" + "&".join(q) if q else "") + (f"#{anchor}" if anchor else ""), status_code=303)


def _promoter_redirect(promoter_id: int, *, message: str = "", error: str = "") -> RedirectResponse:
    q = []
    if message: q.append("message=" + quote_plus(message))
    if error: q.append("error=" + quote_plus(error))
    return RedirectResponse(f"/admin/promoters/{promoter_id}" + ("?" + "&".join(q) if q else ""), status_code=303)


def _parse_expiry(value: str) -> Optional[datetime]:
    if not value.strip():
        return None
    try:
        return datetime.fromisoformat(value.strip()).replace(hour=23, minute=59, second=59, tzinfo=timezone.utc)
    except ValueError:
        raise promotions.PromoError("invalid_expiry", "The expiry date must look like 2026-12-31.")


def _parse_number(value: str, *, name: str, lo: float, hi: float, blank_ok: bool = False) -> Optional[float]:
    v = value.strip().replace("%", "")
    if not v:
        if blank_ok:
            return None
        raise promotions.PromoError("invalid_number", f"{name} is required.")
    try:
        n = float(v)
    except ValueError:
        raise promotions.PromoError("invalid_number", f"{name} must be a number.")
    if not (lo <= n <= hi):
        raise promotions.PromoError("invalid_number", f"{name} must be between {lo:g} and {hi:g}.")
    return n


def _partners_redirect(*, message: str = "", error: str = "", status: str = "", anchor: str = "") -> RedirectResponse:
    q = []
    if status:
        q.append("status=" + quote_plus(status))
    if message:
        q.append("message=" + quote_plus(message))
    if error:
        q.append("error=" + quote_plus(error))
    return RedirectResponse("/admin/partners" + ("?" + "&".join(q) if q else "") + (("#" + anchor) if anchor else ""), status_code=303)


@app.get("/admin/partners", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def admin_partners(request: Request, status: str = "", message: str = "", error: str = ""):
    """The Partner Program (spec §8): the application queue and the
    partner list with each one's numbers."""
    rows = []
    for p in db.list_partners(status or None):
        totals = db.promoter_totals(p["id"])
        rows.append(dict(p, totals=totals, tier_label=partners.tier_label(p), bounty=partners.bounty_state(p)))
    year = datetime.now(timezone.utc).year
    return templates.TemplateResponse(request, "partners.html", {
        "active_nav": "partners", "rows": rows, "status": status, "counts": db.count_partners_by_status(),
        "seats_left": partners.founding_seats_left(), "program": partners, "today": datetime.now(timezone.utc).date().isoformat(),
        "alerts": partners.alerts(), "tax": partners.tax_report(year), "year": year,
        "prospects": db.list_partner_prospects(), "prospect_counts": db.count_partner_prospects(), "program_link": lambda pid: partners.program_url(pid),
        "code_requests": db.list_code_requests(), "resources": db.list_partner_resources(), "partner_feedback": db.list_partner_feedback(limit=25),
        "recruits": db.list_recruits(), "recruit_counts": db.recruitment_counts(), "pending_documents": db.list_partner_documents(pending_only=True),
        "replies": db.prospects_with_unanswered_replies(),
        "outreach_steps": partners.OUTREACH_STEPS,
        "payable_total": sum(r["totals"]["payable_cents"] for r in rows), "owed_total": sum(r["totals"]["owed_cents"] for r in rows),
        "message": message or None, "error": error or None,
    })


@app.post("/admin/partners/invite", dependencies=[Depends(auth.require_admin)])
def admin_partner_invite(name: str = Form(""), email: str = Form(""), note: str = Form("")):
    """Send someone the program details directly -- the link opens the
    gated page without them registering first (spec §8)."""
    try:
        prospect_id = partners.register_prospect(name=name, email=email, source="invite", note=note)
    except partners.PartnerError as e:
        return _partners_redirect(error=e.message)
    return _partners_redirect(message=f"Invitation sent to {email.strip().lower()}. Their link: {partners.program_url(prospect_id)}")


@app.get("/admin/partners/payouts", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def admin_partner_payouts(request: Request, message: str = "", error: str = ""):
    """The payout run (spec §8): who is payable this month, who is
    excluded and why, and one button to record it all."""
    rows = db.payout_run_preview()
    return templates.TemplateResponse(request, "partner_payouts.html", {
        "active_nav": "partners", "rows": rows, "today": datetime.now(timezone.utc).date().isoformat(), "program": partners,
        "eligible_total": sum(r["totals"]["payable_cents"] for r in rows if r["eligible"]), "eligible_count": sum(1 for r in rows if r["eligible"]),
        "message": message or None, "error": error or None,
    })


@app.post("/admin/partners/payouts", dependencies=[Depends(auth.require_admin)])
def admin_partner_payouts_run(promoter_ids: list[str] = Form([]), paid_at: str = Form(""), note: str = Form("")):
    when = paid_at.strip() or datetime.now(timezone.utc).date().isoformat()
    try:
        datetime.fromisoformat(when)
    except ValueError:
        return RedirectResponse("/admin/partners/payouts?error=" + quote_plus("The date must look like 2026-12-31."), status_code=303)
    ids = [int(x) for x in promoter_ids if x.strip().isdigit()]
    if not ids:
        return RedirectResponse("/admin/partners/payouts?error=" + quote_plus("Tick at least one partner."), status_code=303)
    results = partners.run_payouts(ids, paid_at=when, note=note)
    paid = [r for r in results if r["paid_cents"]]
    skipped = [r for r in results if r["skipped"]]
    msg = f"Paid {len(paid)} partner{'' if len(paid) == 1 else 's'} — ${sum(r['paid_cents'] for r in paid) / 100:,.2f} in all."
    if skipped:
        msg += " Skipped: " + "; ".join(f"{r['promoter']['name']} ({r['skipped']})" for r in skipped) + "."
    return RedirectResponse("/admin/partners/payouts?message=" + quote_plus(msg), status_code=303)


@app.get("/admin/partners/ledger", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def admin_partner_ledger(request: Request, promoter_id: str = "", kind: str = "", month: str = "", format: str = ""):
    pid = int(promoter_id) if promoter_id.strip().isdigit() else None
    kind = kind if kind in ("recurring", "bounty", "reversal") else ""
    month = month if re.match(r"^\d{4}-\d{2}$", month or "") else ""
    rows = db.list_ledger(promoter_id=pid, kind=kind, month=month)
    if format == "csv":
        return Response(partners.ledger_csv(rows), media_type="text/csv", headers={"Content-Disposition": f'attachment; filename="partner-ledger{"-" + month if month else ""}.csv"'})
    return templates.TemplateResponse(request, "partner_ledger.html", {
        "active_nav": "partners", "rows": rows, "promoters": db.list_partners(), "promoter_id": pid, "kind": kind, "month": month,
        "total_cents": sum(r["share_cents"] for r in rows),
    })


@app.get("/admin/partners/1099.csv", dependencies=[Depends(auth.require_admin)])
def admin_partner_tax_report(year: str = ""):
    y = int(year) if year.strip().isdigit() else datetime.now(timezone.utc).year
    return Response(partners.tax_report_csv(y), media_type="text/csv", headers={"Content-Disposition": f'attachment; filename="partner-1099-nec-{y}.csv"'})


@app.post("/admin/promoters/{promoter_id}/content", dependencies=[Depends(auth.require_admin)])
def admin_partner_content_add(promoter_id: int, url: str = Form(...), platform: str = Form(""), posted_at: str = Form(""), disclosure: str = Form(""), note: str = Form("")):
    """The FTC monitoring log (spec §10.1): where they posted and whether
    the disclosure was there when we looked."""
    if db.get_promoter(promoter_id) is None:
        return _partners_redirect(error="That partner doesn't exist.")
    if not url.strip().lower().startswith(("http://", "https://")):
        return _promoter_redirect(promoter_id, error="The content URL should start with http:// or https://.")
    present = {"yes": True, "no": False}.get(disclosure)
    db.add_partner_content(promoter_id=promoter_id, url=url, platform=platform, posted_at=posted_at.strip() or None, disclosure_present=present, note=note)
    return _promoter_redirect(promoter_id, message="Content logged.")


@app.post("/admin/promoters/{promoter_id}/content/{content_id}", dependencies=[Depends(auth.require_admin)])
def admin_partner_content_update(promoter_id: int, content_id: int, disclosure: str = Form(""), note: str = Form(""), delete: str = Form("")):
    row = db.get_partner_content(content_id)
    if row is None or row["promoter_id"] != promoter_id:
        return _promoter_redirect(promoter_id, error="That content entry doesn't exist.")
    if delete:
        db.delete_partner_content(content_id)
        return _promoter_redirect(promoter_id, message="Content entry removed.")
    db.update_partner_content(content_id, disclosure_present={"yes": True, "no": False}.get(disclosure), note=note)
    return _promoter_redirect(promoter_id, message="Content entry updated.")


@app.get("/admin/partners/{promoter_id}/review", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def admin_partner_review(request: Request, promoter_id: int, message: str = "", error: str = ""):
    """Everything they told us, on one page, with the decision at the
    bottom -- so approval follows a read rather than a glance at a row."""
    p = db.get_promoter(promoter_id)
    if p is None:
        return _partners_redirect(error="That partner doesn't exist.")
    return templates.TemplateResponse(request, "partner_review.html", {
        "active_nav": "partners", "p": p, "seats_left": partners.founding_seats_left(), "program": partners,
        "suggested_code": re.sub(r"[^A-Z0-9]", "", (p["name"] or "").split(" ")[0].upper())[:20],
        "message": message or None, "error": error or None,
    })


@app.post("/admin/partners/{promoter_id}/approve", dependencies=[Depends(auth.require_admin)])
def admin_partner_approve(promoter_id: int, tier: str = Form("standard"), share_pct: str = Form(""), code: str = Form(...), window_days: str = Form("120"), notes: str = Form("")):
    try:
        share = _parse_number(share_pct, name="Revenue share", lo=0.5, hi=100, blank_ok=True)
        days = _parse_number(window_days or "0", name="Bounty window", lo=0, hi=3650) or 0
        partners.approve(promoter_id, tier=tier, share_pct=share, code=code, window_days=int(days), notes=notes)
    except (partners.PartnerError, promotions.PromoError) as e:
        return _partners_redirect(error=e.message)
    p = db.get_promoter(promoter_id)
    return _promoter_redirect(promoter_id, message=f"{p['name']} approved as a {partners.tier_label(p).lower()} — the welcome email with their link is on its way.")


@app.post("/admin/partners/{promoter_id}/decline", dependencies=[Depends(auth.require_admin)])
def admin_partner_decline(promoter_id: int, note: str = Form("")):
    try:
        partners.decline(promoter_id, note=note)
    except partners.PartnerError as e:
        return _partners_redirect(error=e.message)
    return _partners_redirect(message="Application declined; they've been told.")


@app.post("/admin/partners/{promoter_id}/portal-link", dependencies=[Depends(auth.require_admin)])
def admin_partner_portal_link(promoter_id: int):
    p = db.get_promoter(promoter_id)
    if p is None:
        return _partners_redirect(error="That partner doesn't exist.")
    if not p["email"]:
        return _promoter_redirect(promoter_id, error="They have no email address on file.")
    try:
        email_sender.send_partner_link_email(to_email=p["email"], partner_name=p["name"], url=partners.create_portal_link(promoter_id))
    except email_sender.EmailSendError as e:
        return _promoter_redirect(promoter_id, error=f"Couldn't send the link: {e}")
    return _promoter_redirect(promoter_id, message=f"Portal link sent to {p['email']}.")


@app.post("/admin/partners/codes/{request_id}", dependencies=[Depends(auth.require_admin)])
def admin_partner_code_request(request_id: int, decision: str = Form("approve"), code: str = Form(""), note: str = Form("")):
    """Approve the code a partner asked for (creating it on their terms),
    or decline it with a reason they'll be told."""
    try:
        if decision == "approve":
            promotion_id = partners.approve_code_request(request_id, code=code, note=note)
            return _partners_redirect(message=f"{db.get_promotion(promotion_id)['code']} is live and they've been told.", anchor="codes")
        if not note.strip():
            return _partners_redirect(error="Say why, so we can tell them something useful.", anchor="codes")
        partners.decline_code_request(request_id, note=note)
        return _partners_redirect(message="Declined, with your reason sent on.", anchor="codes")
    except (partners.PartnerError, promotions.PromoError) as e:
        return _partners_redirect(error=e.message, anchor="codes")


@app.post("/admin/partners/resources", dependencies=[Depends(auth.require_admin)])
def admin_partner_resource_add(title: str = Form(...), url: str = Form(...), kind: str = Form("video"), description: str = Form(""), sort_order: str = Form("0"), announce: str = Form("")):
    """The creative kit's library -- videos and anything else partners can
    use as it is."""
    if not url.strip().lower().startswith(("http://", "https://")):
        return _partners_redirect(error="The link should start with http:// or https://.", anchor="kit")
    if kind not in ("video", "graphic", "document", "link"):
        kind = "link"
    resource_id = db.add_partner_resource(title=title, url=url, kind=kind, description=description, sort_order=int(sort_order) if sort_order.strip().lstrip("-").isdigit() else 0)
    message = f"Added “{title.strip()}” to the partner kit."
    if announce:
        sent = partners.announce_resource(resource_id)
        message += f" Told {sent} partner{'' if sent == 1 else 's'} about it."
    return _partners_redirect(message=message, anchor="kit")


@app.post("/admin/partners/resources/{resource_id}", dependencies=[Depends(auth.require_admin)])
def admin_partner_resource_update(resource_id: int, title: str = Form(""), url: str = Form(""), kind: str = Form("video"), description: str = Form(""),
                                  sort_order: str = Form("0"), active: str = Form(""), delete: str = Form("")):
    row = db.get_partner_resource(resource_id)
    if row is None:
        return _partners_redirect(error="That item isn't in the kit.", anchor="kit")
    if delete:
        db.delete_partner_resource(resource_id)
        return _partners_redirect(message="Removed from the kit.", anchor="kit")
    db.update_partner_resource(resource_id, title=title or row["title"], url=url or row["url"], kind=kind, description=description,
                               sort_order=int(sort_order) if sort_order.strip().lstrip("-").isdigit() else row["sort_order"], active=bool(active))
    return _partners_redirect(message="Kit updated.", anchor="kit")


@app.post("/admin/partner-feedback/{feedback_id}/reviewed", dependencies=[Depends(auth.require_admin)])
def admin_partner_feedback_reviewed(feedback_id: int):
    db.mark_partner_feedback_reviewed(feedback_id)
    return _partners_redirect(message="Marked as read.", anchor="feedback")


@app.get("/admin/partner-documents/{document_id}", dependencies=[Depends(auth.require_admin)])
def admin_partner_document(document_id: int):
    """The file itself, for reading before accepting it."""
    doc = db.get_partner_document(document_id)
    if doc is None:
        raise HTTPException(status_code=404)
    return Response(base64.b64decode(doc["data"]), media_type=doc["content_type"],
                    headers={"Content-Disposition": f'inline; filename="{doc["promoter_name"].replace(chr(34), "")}-{doc["kind"]}-{doc["filename"]}"'})


@app.post("/admin/partner-documents/{document_id}", dependencies=[Depends(auth.require_admin)])
def admin_partner_document_decide(document_id: int, decision: str = Form("accept"), note: str = Form("")):
    doc = db.get_partner_document(document_id)
    if doc is None:
        return _partners_redirect(error="That document isn't here.")
    try:
        if decision == "accept":
            partners.accept_document(document_id)
            return _promoter_redirect(doc["promoter_id"], message="Tax form accepted — they can be paid now.")
        if not note.strip():
            return _promoter_redirect(doc["promoter_id"], error="Say what's wrong with it, so they can fix it.")
        partners.reject_document(document_id, note=note)
        return _promoter_redirect(doc["promoter_id"], message="Sent back, with your reason.")
    except partners.PartnerError as e:
        return _promoter_redirect(doc["promoter_id"], error=e.message)


@app.post("/admin/partners/resources/{resource_id}/announce", dependencies=[Depends(auth.require_admin)])
def admin_partner_resource_announce(resource_id: int):
    try:
        sent = partners.announce_resource(resource_id)
    except partners.PartnerError as e:
        return _partners_redirect(error=e.message, anchor="kit")
    return _partners_redirect(message=f"Told {sent} partner{'' if sent == 1 else 's'} about it.", anchor="kit")


@app.post("/admin/partners/recruit", dependencies=[Depends(auth.require_admin)])
async def admin_partner_recruit(people: str = Form(""), note: str = Form(""), file: Optional[UploadFile] = File(None)):
    """Paste a list or upload a CSV; everyone on it gets the recruitment
    sequence, which then runs itself."""
    text = people or ""
    if file is not None and file.filename:
        raw = await file.read()
        if len(raw) > 512 * 1024:
            return _partners_redirect(error="That file is larger than 512 KB — paste the list instead.", anchor="recruit")
        try:
            text += "\n" + raw.decode("utf-8-sig", errors="replace")
        except Exception:  # noqa: BLE001
            return _partners_redirect(error="Couldn't read that file — a plain CSV of name,email works best.", anchor="recruit")
    found, bad = partners.parse_recruits(text)
    if not found:
        return _partners_redirect(error="Nothing to send to — one per line, as “Kathleen Reyes <kathleen@example.com>” or “Kathleen Reyes, kathleen@example.com”.", anchor="recruit")
    result = partners.start_outreach(found, note=note)
    msg = f"Started {result['started']} approach{'' if result['started'] == 1 else 'es'}: {result['sent']} first email{'' if result['sent'] == 1 else 's'} sent"
    msg += f", {result['queued']} queued for the next few minutes." if result["queued"] else "."
    if result["skipped"]:
        msg += " Skipped: " + "; ".join(result["skipped"][:6]) + ("…" if len(result["skipped"]) > 6 else "") + "."
    if bad:
        msg += f" Couldn't read {len(bad)} line{'' if len(bad) == 1 else 's'}: " + "; ".join(bad[:3]) + ("…" if len(bad) > 3 else "") + "."
    return _partners_redirect(message=msg, anchor="recruit")


@app.get("/admin/partners/recruit/{prospect_id}", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def admin_partner_recruit_detail(request: Request, prospect_id: int, message: str = "", error: str = ""):
    """One person's approach: where they are in the sequence, everything
    sent and received, and the controls for both."""
    prospect = db.get_partner_prospect(prospect_id)
    if prospect is None:
        return _partners_redirect(error="That person isn't on the list.", anchor="recruit")
    promoter = db.get_promoter_by_email(prospect["email"])
    return templates.TemplateResponse(request, "partner_recruit.html", {
        "active_nav": "partners", "p": prospect, "plan": partners.outreach_plan(prospect), "timeline": partners.recruit_timeline(prospect),
        "program_link": partners.program_url(prospect_id), "promoter": promoter, "program": partners,
        "message": message or None, "error": error or None,
    })


def _recruit_redirect(prospect_id: int, *, message: str = "", error: str = "") -> RedirectResponse:
    q = []
    if message:
        q.append("message=" + quote_plus(message))
    if error:
        q.append("error=" + quote_plus(error))
    return RedirectResponse(f"/admin/partners/recruit/{prospect_id}" + ("?" + "&".join(q) if q else ""), status_code=303)


@app.post("/admin/partners/recruit/{prospect_id}/send/{step}", dependencies=[Depends(auth.require_admin)])
def admin_partner_recruit_send_step(prospect_id: int, step: int, advance: str = Form("")):
    """Send one particular email again -- the same words, and the
    schedule left where it was unless you say otherwise."""
    prospect = db.get_partner_prospect(prospect_id)
    if prospect is None:
        return _partners_redirect(error="That person isn't on the list.", anchor="recruit")
    if not partners.send_outreach_step(prospect, step, advance=bool(advance)):
        return _recruit_redirect(prospect_id, error="That email couldn't be sent — check the mail settings.")
    return _recruit_redirect(prospect_id, message=f"Email {step} sent to {prospect['email']}.")


@app.post("/admin/partners/recruit/{prospect_id}/reply", dependencies=[Depends(auth.require_admin)])
def admin_partner_recruit_reply(prospect_id: int, subject: str = Form(""), body: str = Form(...)):
    """Their reply, when it reached your inbox rather than the hook."""
    prospect = db.get_partner_prospect(prospect_id)
    if prospect is None:
        return _partners_redirect(error="That person isn't on the list.", anchor="recruit")
    if not body.strip():
        return _recruit_redirect(prospect_id, error="Paste what they wrote.")
    partners.record_reply(prospect, subject=subject, body=body)
    return _recruit_redirect(prospect_id, message="Reply saved — the sequence is paused while you talk to them.")


@app.post("/admin/partners/recruit/{prospect_id}/resume", dependencies=[Depends(auth.require_admin)])
def admin_partner_recruit_resume(prospect_id: int):
    partners.resume_outreach(prospect_id)
    return _recruit_redirect(prospect_id, message="Back in the sequence, from where it left off.")


@app.post("/admin/partners/recruit/{prospect_id}", dependencies=[Depends(auth.require_admin)])
def admin_partner_recruit_action(prospect_id: int, action: str = Form("stop")):
    prospect = db.get_partner_prospect(prospect_id)
    if prospect is None:
        return _partners_redirect(error="That person isn't on the list.", anchor="recruit")
    if action == "stop":
        partners.stop_outreach(prospect_id)
        return _partners_redirect(message=f"Stopped writing to {prospect['email']}.", anchor="recruit")
    if action == "send":
        if partners.send_outreach_step(prospect, int(prospect["outreach_step"] or 0) + 1):
            return _partners_redirect(message=f"Next email sent to {prospect['email']}.", anchor="recruit")
        return _partners_redirect(error="Nothing left to send them — the sequence is finished.", anchor="recruit")
    if action == "restart":
        db.set_prospect_outreach(prospect_id, outreach_step=0, outreach_status="active", outreach_next_at=db.now_iso())
        return _partners_redirect(message=f"Starting again with {prospect['email']}.", anchor="recruit")
    return _partners_redirect(error="Unknown action.", anchor="recruit")


@app.post("/admin/partners/windows", dependencies=[Depends(auth.require_admin)])
def admin_partner_windows(promoter_ids: list[str] = Form([]), bounty_window_start: str = Form(""), bounty_window_end: str = Form("")):
    """Bulk-set a cohort's bounty window (spec §4.1)."""
    try:
        start = datetime.fromisoformat(bounty_window_start.strip()).date(); end = datetime.fromisoformat(bounty_window_end.strip()).date()
    except ValueError:
        return _partners_redirect(error="Both window dates are needed, like 2026-12-31.")
    if end < start:
        return _partners_redirect(error="The window can't end before it starts.")
    n = 0
    for raw in promoter_ids:
        if raw.strip().isdigit() and db.get_promoter(int(raw)) is not None:
            db.update_partner_fields(int(raw), bounty_window_start=start.isoformat(), bounty_window_end=end.isoformat()); n += 1
    return _partners_redirect(message=f"Bounty window {start} → {end} set on {n} partner{'' if n == 1 else 's'}.")


@app.get("/admin/promotions", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def admin_promotions(request: Request, message: str = "", error: str = ""):
    promoters = [dict(p, totals=db.promoter_totals(p["id"])) for p in db.list_promoters()]
    return templates.TemplateResponse(request, "promotions.html", {
        "active_nav": "promotions",
        "overview": db.promotions_overview(),
        "promoters": promoters,
        "promotions": db.list_promotions(),
        "describe": promotions.describe,
        "trial_days": config.TRIAL_DAYS,
        "message": message or None,
        "error": error or None,
    })


@app.post("/admin/promoters", dependencies=[Depends(auth.require_admin)])
def admin_create_promoter(name: str = Form(...), email: str = Form(""), organization: str = Form(""), default_share_pct: str = Form("0"), notes: str = Form("")):
    if not name.strip():
        return _promotions_redirect(error="A promoter needs a name.", anchor="promoters")
    try:
        share = _parse_number(default_share_pct or "0", name="Default revenue share", lo=0, hi=100) or 0
    except promotions.PromoError as e:
        return _promotions_redirect(error=e.message, anchor="promoters")
    pid = db.create_promoter(name=name, email=email, organization=organization, default_share_pct=share, notes=notes)
    return _promoter_redirect(pid, message=f"Promoter {name.strip()} added. Now give them a code.")


@app.get("/admin/promoters/{promoter_id}", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def admin_promoter_detail(request: Request, promoter_id: int, message: str = "", error: str = ""):
    promoter = db.get_promoter(promoter_id)
    if promoter is None:
        return _promotions_redirect(error="That promoter doesn't exist.")
    return templates.TemplateResponse(request, "promoter_detail.html", {
        "active_nav": "promotions",
        "promoter": promoter,
        "totals": db.promoter_totals(promoter_id),
        "codes": db.list_promotions(promoter_id),
        "redemptions": db.list_redemptions_for_promoter(promoter_id),
        "payouts": db.list_promo_payouts_for_promoter(promoter_id),
        "payments": db.list_promoter_payments(promoter_id),
        "referrals_by_id": {r["id"]: r for r in partners.referral_rows(promoter_id)},
        "content": db.list_partner_content(promoter_id),
        "feedback": db.list_partner_feedback(promoter_id=promoter_id),
        "code_requests": db.list_code_requests(promoter_id=promoter_id),
        "documents": db.list_partner_documents(promoter_id),
        "bounty": partners.bounty_state(promoter),
        "tier_label": partners.tier_label(promoter),
        "is_partner": partners.is_partner(promoter),
        "program": partners,
        "describe": promotions.describe,
        "today": datetime.now(timezone.utc).date().isoformat(),
        "message": message or None,
        "error": error or None,
    })


@app.post("/admin/promoters/{promoter_id}", dependencies=[Depends(auth.require_admin)])
def admin_update_promoter(promoter_id: int, name: str = Form(...), email: str = Form(""), organization: str = Form(""), default_share_pct: str = Form("0"), notes: str = Form(""), active: str = Form("")):
    if db.get_promoter(promoter_id) is None:
        return _promotions_redirect(error="That promoter doesn't exist.")
    try:
        share = _parse_number(default_share_pct or "0", name="Default revenue share", lo=0, hi=100) or 0
    except promotions.PromoError as e:
        return _promoter_redirect(promoter_id, error=e.message)
    db.update_promoter(promoter_id, name=name, email=email, organization=organization, default_share_pct=share, notes=notes, active=bool(active))
    return _promoter_redirect(promoter_id, message="Promoter updated.")


@app.post("/admin/promoters/{promoter_id}/partner", dependencies=[Depends(auth.require_admin)])
def admin_update_partner(promoter_id: int, status: str = Form("active"), tier: str = Form(""), bounty_window_start: str = Form(""), bounty_window_end: str = Form(""),
                         payout_method: str = Form("paypal"), payout_email: str = Form(""), tax_form_type: str = Form(""), tax_form_received_at: str = Form("")):
    """The Partner Program fields (spec §4, §8): lifecycle, tier, bounty
    window, payout and tax details. Tier only ever holds founding or
    standard -- 'Established' is derived from bounty_reinstated_at."""
    p = db.get_promoter(promoter_id)
    if p is None:
        return _promotions_redirect(error="That promoter doesn't exist.")
    if status not in ("applied", "approved", "active", "suspended", "closed"):
        return _promoter_redirect(promoter_id, error="Status must be applied, approved, active, suspended or closed.")
    if tier not in ("", "founding", "standard"):
        return _promoter_redirect(promoter_id, error="Tier is founding or standard (Established is earned, not set).")
    for label, value in (("Bounty window start", bounty_window_start), ("Bounty window end", bounty_window_end), ("Tax form received", tax_form_received_at)):
        if value.strip():
            try:
                datetime.fromisoformat(value.strip())
            except ValueError:
                return _promoter_redirect(promoter_id, error=f"{label} must look like 2026-12-31.")
    fields = dict(status=status, tier=tier, bounty_window_start=bounty_window_start.strip() or None, bounty_window_end=bounty_window_end.strip() or None,
                  payout_method=payout_method.strip() or "paypal", payout_email=payout_email.strip().lower(),
                  tax_form_type=tax_form_type.strip(), tax_form_received_at=tax_form_received_at.strip() or None)
    if status in ("approved", "active") and not p["approved_at"]:
        fields["approved_at"] = db.now_iso()
        # Per-partner bounty window: 120 days from approval unless set by hand (§4.1).
        if not fields["bounty_window_start"]:
            start = datetime.now(timezone.utc).date()
            fields["bounty_window_start"] = start.isoformat()
            fields["bounty_window_end"] = (start + timedelta(days=120)).isoformat()
    db.update_partner_fields(promoter_id, **fields)
    return _promoter_redirect(promoter_id, message="Partner details updated.")


@app.post("/admin/promoters/{promoter_id}/payments", dependencies=[Depends(auth.require_admin)])
def admin_record_promoter_payment(promoter_id: int, amount: str = Form(...), paid_at: str = Form(""), note: str = Form("")):
    if db.get_promoter(promoter_id) is None:
        return _promotions_redirect(error="That promoter doesn't exist.")
    try:
        dollars = _parse_number(amount, name="Amount", lo=0.01, hi=1_000_000)
    except promotions.PromoError as e:
        return _promoter_redirect(promoter_id, error=e.message)
    when = paid_at.strip() or datetime.now(timezone.utc).date().isoformat()
    db.record_promoter_payment(promoter_id=promoter_id, amount_cents=round(dollars * 100), paid_at=when, note=note)
    return _promoter_redirect(promoter_id, message=f"Recorded a ${dollars:,.2f} payout.")


@app.post("/admin/promotions", dependencies=[Depends(auth.require_admin)])
def admin_create_promotion(code: str = Form(...), kind: str = Form("direct"), promoter_id: str = Form(""), percent_off: str = Form("0"), duration_months: str = Form(""),
                           share_pct: str = Form(""), max_redemptions: str = Form(""), expires_at: str = Form(""), allowed_emails: str = Form(""), notes: str = Form(""),
                           trial_days: str = Form(""), proofs_extra: str = Form(""), commission_months: str = Form("")):
    anchor = "codes"
    try:
        pid = int(promoter_id) if promoter_id.strip().isdigit() else None
        promoter = db.get_promoter(pid) if pid else None
        pct = _parse_number(percent_off or "0", name="Discount", lo=0, hi=100)
        months = _parse_number(duration_months, name="Duration", lo=1, hi=120, blank_ok=True)
        share = _parse_number(share_pct, name="Revenue share", lo=0, hi=100, blank_ok=True)
        if share is None:
            share = float(promoter["default_share_pct"]) if promoter else 0
        max_r = _parse_number(max_redemptions, name="Maximum uses", lo=1, hi=1_000_000, blank_ok=True)
        trial = _parse_number(trial_days, name="Trial days", lo=1, hi=365, blank_ok=True)
        extra = _parse_number(proofs_extra, name="Extra proofs", lo=0, hi=100, blank_ok=True)
        term = _parse_number(commission_months, name="Commission term", lo=1, hi=240, blank_ok=True)
        promotion_id = promotions.create_promotion(
            code=code, kind=kind, promoter_id=pid, percent_off=pct, duration_months=int(months) if months else None, share_pct=share,
            max_redemptions=int(max_r) if max_r else None, expires_at=_parse_expiry(expires_at), allowed_emails=allowed_emails, notes=notes,
            trial_days=int(trial) if trial else None, proofs_extra=int(extra or 0), commission_months=int(term) if term else None,
        )
    except promotions.PromoError as e:
        return (_promoter_redirect(int(promoter_id), error=e.message) if promoter_id.strip().isdigit() else _promotions_redirect(error=e.message, anchor=anchor))
    promo = db.get_promotion(promotion_id)
    msg = f"Code {promo['code']} created: {promotions.describe(promo)}."
    return _promoter_redirect(promo["promoter_id"], message=msg) if promo["promoter_id"] else _promotions_redirect(message=msg, anchor=anchor)


@app.get("/admin/promotions/{promotion_id}", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def admin_promotion_detail(request: Request, promotion_id: int, message: str = "", error: str = ""):
    promo = db.get_promotion(promotion_id)
    if promo is None:
        return _promotions_redirect(error="That code doesn't exist.")
    rows = [dict(r, cycles_remaining=promotions.cycles_remaining(r)) for r in db.list_redemptions_for_promotion(promotion_id)]
    return templates.TemplateResponse(request, "promotion_detail.html", {
        "active_nav": "promotions",
        "promo": promo,
        "promoter": db.get_promoter(promo["promoter_id"]) if promo["promoter_id"] else None,
        "redemptions": rows,
        "describe": promotions.describe,
        "message": message or None,
        "error": error or None,
    })


@app.post("/admin/promotions/{promotion_id}/toggle", dependencies=[Depends(auth.require_admin)])
def admin_toggle_promotion(promotion_id: int):
    promo = db.get_promotion(promotion_id)
    if promo is None:
        return _promotions_redirect(error="That code doesn't exist.")
    try:
        promotions.set_active(promotion_id, not promo["active"])
    except promotions.PromoError as e:
        return _promotions_redirect(error=e.message, anchor="codes")
    state = "reactivated" if not promo["active"] else "deactivated"
    return RedirectResponse(f"/admin/promotions/{promotion_id}?message=" + quote_plus(f"Code {promo['code']} {state}."), status_code=303)


@app.post("/admin/customers/{customer_id}/apply-promotion", dependencies=[Depends(auth.require_admin)])
def admin_apply_promotion(customer_id: int, code: str = Form(...)):
    """Give a current subscriber a discount from their next invoice."""
    customer = db.get_customer(customer_id)
    if customer is None:
        return RedirectResponse("/admin/subscribers", status_code=303)
    sub = db.best_subscription_for_customer(customer_id)
    if sub is None or sub["status"] not in db.ENTITLED_STATUSES:
        return _customer_redirect(customer_id, error="They don't have a live subscription to discount. Give them a code to use when they subscribe instead.")
    try:
        promo = promotions.validate(code, email=customer["email"])
        promotions.apply_to_existing_subscription(promotion_id=promo["id"], subscription_row=sub)
    except promotions.PromoError as e:
        return _customer_redirect(customer_id, error=e.message)
    return _customer_redirect(customer_id, message=f"Applied {promo['code']} ({promotions.describe(promo)}) from their next invoice.")


# ----------------------------------------------------------- financials ---


def _financials_redirect(*, view: str = "monthly", year: Optional[int] = None, message: str = "", error: str = "") -> RedirectResponse:
    q = [f"view={view}", f"year={year or finance.today().year}"]
    if message: q.append("message=" + quote_plus(message))
    if error: q.append("error=" + quote_plus(error))
    return RedirectResponse("/admin/financials?" + "&".join(q), status_code=303)


def _report_context(view: str, year: int) -> dict:
    view = view if view in ("mtd", "monthly", "quarterly", "annual") else "monthly"
    rows = finance.report(view, year)
    categories = sorted({c for r in rows for c in r["expenses_by_category"]})
    return {"view": view, "year": year, "rows": rows, "categories": categories}


@app.get("/admin/financials", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def financials(request: Request, view: str = "monthly", year: int = 0, month: str = "", message: str = "", error: str = ""):
    year = year or finance.today().year
    ctx = _report_context(view, year)
    # The expense ledger shown below the report: one month at a time.
    t = finance.today()
    ledger_month = month if re.match(r"^\d{4}-\d{2}$", month or "") else f"{t.year:04d}-{t.month:02d}"
    ly, lm = (int(x) for x in ledger_month.split("-"))
    start, end = finance.month_bounds(ly, lm)
    return templates.TemplateResponse(request, "financials.html", {
        **ctx,
        "active_nav": "financials",
        "counts": db.subscriber_counts(),
        "ledger_month": ledger_month,
        "ledger_label": date(ly, lm, 1).strftime("%B %Y"),
        "prev_month": f"{(ly if lm > 1 else ly - 1):04d}-{(lm - 1 if lm > 1 else 12):02d}",
        "next_month": f"{(ly if lm < 12 else ly + 1):04d}-{(lm + 1 if lm < 12 else 1):02d}",
        "expenses": db.list_expenses(start, end),
        "recurring": db.list_recurring_expenses(),
        "expense_categories": db.EXPENSE_CATEGORIES,
        "years": list(range((finance._first_year() or t.year), t.year + 1)),
        "today": t.isoformat(),
        "message": message or None,
        "error": error or None,
    })


@app.post("/admin/expenses", dependencies=[Depends(auth.require_admin)])
def add_expense(date_: str = Form(..., alias="date"), category: str = Form(...), vendor: str = Form(""), description: str = Form(""), amount: str = Form(...), view: str = Form("monthly"), year: str = Form("")):
    try:
        cents = round(float(amount.replace("$", "").replace(",", "")) * 100)
        datetime.fromisoformat(date_)
    except ValueError:
        return _financials_redirect(view=view, year=int(year) if year.isdigit() else None, error="Give a date like 2026-09-13 and an amount like 19.99.")
    if cents == 0:
        return _financials_redirect(view=view, year=int(year) if year.isdigit() else None, error="The amount can't be zero.")
    db.add_expense(date=date_, category=category if category in db.EXPENSE_CATEGORIES else "Other", vendor=vendor, description=description, amount_cents=cents)
    return _financials_redirect(view=view, year=int(year) if year.isdigit() else None, message=f"Expense of ${cents / 100:,.2f} recorded.")


@app.post("/admin/expenses/{expense_id}/delete", dependencies=[Depends(auth.require_admin)])
def delete_expense(expense_id: int, view: str = Form("monthly"), year: str = Form("")):
    ok = db.delete_expense(expense_id)
    return _financials_redirect(view=view, year=int(year) if year.isdigit() else None, message="Expense deleted." if ok else "", error="" if ok else "Imported Stripe entries can't be deleted — they'd come back on the next import.")


@app.post("/admin/recurring", dependencies=[Depends(auth.require_admin)])
def add_recurring(vendor: str = Form(...), category: str = Form(...), description: str = Form(""), amount: str = Form(...), day_of_month: str = Form("1"), start_month: str = Form(...), end_month: str = Form(""), view: str = Form("monthly"), year: str = Form("")):
    try:
        cents = round(float(amount.replace("$", "").replace(",", "")) * 100)
        if not re.match(r"^\d{4}-\d{2}$", start_month) or (end_month and not re.match(r"^\d{4}-\d{2}$", end_month)):
            raise ValueError
        day = max(1, min(28, int(day_of_month or 1)))
    except ValueError:
        return _financials_redirect(view=view, year=int(year) if year.isdigit() else None, error="Give an amount like 5.00, a start month like 2026-09, and a day between 1 and 28.")
    db.add_recurring_expense(vendor=vendor, category=category if category in db.EXPENSE_CATEGORIES else "Other", description=description, amount_cents=cents, day_of_month=day, start_month=start_month, end_month=end_month or None)
    created = finance.materialize_recurring(through=finance.today())
    return _financials_redirect(view=view, year=int(year) if year.isdigit() else None, message=f"Recurring bill added; {created} month(s) booked so far.")


@app.post("/admin/recurring/{recurring_id}", dependencies=[Depends(auth.require_admin)])
def update_recurring(recurring_id: int, amount: str = Form(...), active: str = Form(""), end_month: str = Form(""), view: str = Form("monthly"), year: str = Form("")):
    if db.get_recurring_expense(recurring_id) is None:
        return _financials_redirect(view=view, year=int(year) if year.isdigit() else None, error="That recurring bill doesn't exist.")
    try:
        cents = round(float(amount.replace("$", "").replace(",", "")) * 100)
    except ValueError:
        return _financials_redirect(view=view, year=int(year) if year.isdigit() else None, error="Give an amount like 5.00.")
    db.update_recurring_expense(recurring_id, amount_cents=cents, active=bool(active), end_month=end_month or None)
    return _financials_redirect(view=view, year=int(year) if year.isdigit() else None, message="Recurring bill updated (future months use the new amount).")


@app.post("/admin/financials/import-stripe", dependencies=[Depends(auth.require_admin)])
def import_stripe_fees(months: str = Form("3"), view: str = Form("monthly"), year: str = Form("")):
    n = max(1, min(24, int(months) if months.isdigit() else 3))
    t = finance.today()
    y, m = t.year, t.month
    for _ in range(n - 1):
        y, m = (y, m - 1) if m > 1 else (y - 1, 12)
    start = date(y, m, 1)
    try:
        counts = finance.import_stripe_fees(start=start, end=t)
    except stripe.error.StripeError as e:
        return _financials_redirect(view=view, year=int(year) if year.isdigit() else None, error=f"Stripe import failed: {getattr(e, 'user_message', None) or e}")
    msg = f"Imported from Stripe since {start.isoformat()}: {counts['fees']} new fee entr{'y' if counts['fees'] == 1 else 'ies'} (${counts['fee_cents'] / 100:,.2f}), {counts['refunds']} refund{'' if counts['refunds'] == 1 else 's'} (${counts['refund_cents'] / 100:,.2f})."
    return _financials_redirect(view=view, year=int(year) if year.isdigit() else None, message=msg)


@app.get("/admin/financials.csv", dependencies=[Depends(auth.require_admin)])
def financials_csv(view: str = "monthly", year: int = 0):
    ctx = _report_context(view, year or finance.today().year)
    buffer = io.StringIO()
    writer = csv.writer(buffer)
    cats = ctx["categories"]
    writer.writerow(["period", "payments", "revenue_usd", "stripe_fees_usd", "refunds_usd", "net_revenue_usd", *[f"{c.lower().replace(' ', '_')}_usd" for c in cats], "total_expenses_usd", "net_usd", "promoter_share_accrued_usd", "subscriptions_started", "subscriptions_ended"])
    for r in ctx["rows"]:
        writer.writerow([r["label"], r["payments"], f"{r['revenue_cents'] / 100:.2f}", f"{r['stripe_fees_cents'] / 100:.2f}", f"{r['refunds_cents'] / 100:.2f}", f"{r['net_revenue_cents'] / 100:.2f}",
                         *[f"{r['expenses_by_category'].get(c, 0) / 100:.2f}" for c in cats], f"{r['total_expenses_cents'] / 100:.2f}", f"{r['net_cents'] / 100:.2f}", f"{r['promoter_share_accrued_cents'] / 100:.2f}", r["started"], r["ended"]])
    buffer.seek(0)
    return StreamingResponse(buffer, media_type="text/csv", headers={"Content-Disposition": f"attachment; filename=piperstitch_financials_{ctx['view']}_{ctx['year']}.csv"})


# -------------------------------------------------------------- feedback ---
# "Send feedback" in the web editor: the original artwork and a picture of
# the digitized result, for reviewing where the algorithm did well or
# poorly. See db.feedback_submissions and web_access.submit_feedback.


@app.get("/admin/feedback", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def admin_feedback(request: Request, only_unreviewed: bool = False, customer_id: int = 0):
    submissions = db.list_feedback(only_unreviewed=only_unreviewed)
    if customer_id:
        submissions = [f for f in submissions if f["customer_id"] == customer_id]
    return templates.TemplateResponse(request, "feedback.html", {
        "active_nav": "feedback",
        "submissions": submissions,
        "unreviewed_count": db.count_feedback_unreviewed(),
        "only_unreviewed": only_unreviewed,
    })


@app.get("/admin/feedback/{feedback_id}", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def admin_feedback_detail(request: Request, feedback_id: int, message: str = "", error: str = ""):
    submission = db.get_feedback(feedback_id)
    if submission is None:
        return RedirectResponse("/admin/feedback", status_code=303)
    return templates.TemplateResponse(request, "feedback_detail.html", {
        "active_nav": "feedback", "submission": submission, "message": message or None, "error": error or None,
    })


@app.get("/admin/feedback/{feedback_id}/image/{which}", dependencies=[Depends(auth.require_admin)])
def admin_feedback_image(feedback_id: int, which: str):
    submission = db.get_feedback(feedback_id)
    if submission is None or which not in ("original", "digitized"):
        raise HTTPException(status_code=404)
    data = submission[f"{which}_image_data"]
    if not data:
        raise HTTPException(status_code=404)
    content_type = submission[f"{which}_image_type"] or "image/png"
    ext = "jpg" if "jpeg" in content_type else content_type.split("/")[-1]
    filename = f"piperstitch_feedback_{feedback_id}_{which}.{ext}"
    return Response(base64.b64decode(data), media_type=content_type, headers={"Content-Disposition": f'inline; filename="{filename}"'})


@app.post("/admin/feedback/{feedback_id}/review", dependencies=[Depends(auth.require_admin)])
def admin_feedback_review(feedback_id: int):
    submission = db.get_feedback(feedback_id)
    if submission is None:
        return RedirectResponse("/admin/feedback", status_code=303)
    if submission["reviewed_at"] is None:
        db.mark_feedback_reviewed(feedback_id, reviewed_by="admin")
    customer = db.get_customer(submission["customer_id"]) if submission["customer_id"] else None
    try:
        email_sender.send_feedback_reviewed_email(to_email=submission["customer_email"], customer_name=customer["name"] if customer else "", account_url=config.WEB_APP_URL)
    except email_sender.EmailSendError as e:
        return RedirectResponse(f"/admin/feedback/{feedback_id}?error=Send failed: {quote_plus(str(e))}", status_code=303)
    if submission["customer_id"]:
        db.add_event(customer_id=submission["customer_id"], subscription_id=None, kind="email",
                     detail=f"Told we used their feedback (submission #{feedback_id}) and to try PiperStitch again.")
    return RedirectResponse(f"/admin/feedback/{feedback_id}?message=" + quote_plus("Marked reviewed and emailed the customer."), status_code=303)


# --------------------------------------------------------------- updates ---

_VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")


def _version_tuple(v: str) -> tuple[int, ...]:
    return tuple(int(p) for p in v.split("."))


@app.get("/admin/go-live", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def go_live_page(request: Request, message: str = "", error: str = ""):
    counts = db.customer_data_counts()
    problems = config.stripe_mode_problems()
    if config.STRIPE_SECRET_KEY:
        problems += stripe_client.check_prices()
    return templates.TemplateResponse(request, "go_live.html", {
        "counts": counts,
        "total": sum(counts.values()),
        "stripe_mode": config.stripe_mode() or "not configured",
        "problems": problems,
        "price_monthly": config.STRIPE_PRICE_MONTHLY,
        "price_proofs": config.STRIPE_PRICE_PROOFS_MONTHLY,
        "message": message or None,
        "error": error or None,
        "active_nav": "go_live",
    })


@app.post("/admin/go-live/reset", dependencies=[Depends(auth.require_admin)])
def go_live_reset(confirm: str = Form("")):
    if confirm.strip() != "RESET":
        return RedirectResponse("/admin/go-live?error=" + quote("Type RESET in the box to confirm."), status_code=303)
    removed = db.reset_customer_data()
    total = sum(removed.values())
    log.warning("Customer data reset by admin: %s rows removed", total)
    return RedirectResponse("/admin/go-live?message=" + quote(f"Removed {total} rows of test customer data. The database is clean."), status_code=303)


@app.get("/admin/updates", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def updates_page(request: Request, message: str = "", error: str = ""):
    return templates.TemplateResponse(request, "updates.html", {
        "configured": bool(config.WEBSITE_SFTP_HOST),
        "latest": db.latest_published_update(),
        "history": db.list_published_updates(),
        "message": message or None,
        "error": error or None,
        "active_nav": "updates",
    })


@app.post("/admin/updates", dependencies=[Depends(auth.require_admin)])
async def updates_publish(request: Request, version: str = Form(...), notes: str = Form(""), build_file: UploadFile = File(...)):
    def _redirect(*, error: str = "", message: str = "") -> RedirectResponse:
        param = f"error={quote_plus(error)}" if error else f"message={quote_plus(message)}"
        return RedirectResponse(f"/admin/updates?{param}", status_code=303)

    if not config.WEBSITE_SFTP_HOST:
        return _redirect(error="Website publishing isn't configured — see .env.example for WEBSITE_SFTP_* settings.")
    version = version.strip()
    if not _VERSION_RE.match(version):
        return _redirect(error="Version must look like X.Y.Z (e.g. 0.2.0).")
    latest = db.latest_published_update()
    if latest and _version_tuple(version) <= _version_tuple(latest["version"]):
        return _redirect(error=f"{version} is not newer than the currently live version ({latest['version']}).")

    suffix = Path(build_file.filename or "").suffix or ".dmg"
    remote_filename = f"PiperStitch-{version}{suffix}"
    with tempfile.NamedTemporaryFile(delete=True) as tmp:
        sha256 = hashlib.sha256()
        size = 0
        while chunk := await build_file.read(1024 * 1024):
            tmp.write(chunk)
            sha256.update(chunk)
            size += len(chunk)
        tmp.flush()
        download_url = f"{config.DOWNLOAD_BASE_URL}/{remote_filename}"
        try:
            website_publish.upload_build(tmp.name, remote_filename)
            website_publish.write_feed_json(version=version, download_url=download_url, notes=notes)
        except website_publish.PublishError as e:
            log.error("Update publish failed for version %s: %s", version, e)
            return _redirect(error=str(e))

    db.insert_published_update(version=version, notes=notes, download_url=download_url, file_size=size, sha256=sha256.hexdigest())
    verified = ""
    try:
        live = httpx.get(config.UPDATE_FEED_URL, timeout=10).json()
        verified = " Verified live." if live.get("latest_version") == version else " Warning: the live feed doesn't show this version yet — check it manually."
    except (httpx.HTTPError, ValueError) as e:
        verified = f" Could not verify the live feed: {e}"
    return _redirect(message=f"Published {version}.{verified}")
