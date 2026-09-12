"""PiperStitch License Admin — a standalone service, separate from the
PiperStitch desktop app, that runs the subscription business: takes
monthly subscriptions through Stripe, mirrors their state from Stripe's
webhooks, signs Macs in to them, hands the app short-lived signed
entitlements, gives customers a self-service account page, and gives
the one admin a dashboard over all of it. See README.md for what this
is, how to configure it, and how to deploy it.
"""

from __future__ import annotations

import csv
import hashlib
import hmac
import io
import logging
import re
import tempfile
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional
from urllib.parse import quote_plus

import httpx
import stripe
from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel, field_validator
from starlette.middleware.sessions import SessionMiddleware

from . import activation, auth, config, db, email_sender, stripe_client, subscriptions, web_access, website_publish

log = logging.getLogger("license_admin")


@asynccontextmanager
async def _lifespan(app: FastAPI):
    db.init_db()
    missing = config.require_for_serving()
    if missing:
        log.warning("License Admin is running with missing configuration: %s — see .env.example", ", ".join(missing))
    yield


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

templates = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))
app.mount("/static", StaticFiles(directory=str(Path(__file__).parent / "static")), name="static")

_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def _validate_email(v: str) -> str:
    v = v.strip().lower()
    if not _EMAIL_RE.match(v):
        raise ValueError("not a valid email address")
    return v


def _price_label() -> str:
    cents = config.MONTHLY_PRICE_CENTS
    return f"${cents // 100}" if cents % 100 == 0 else f"${cents / 100:.2f}"


templates.env.globals.update(price_label=_price_label, config=config, max_devices=config.MAX_DEVICES)


def _short_date(iso: Optional[str]) -> str:
    return iso[:10] if iso else "—"


templates.env.filters["short_date"] = _short_date


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


class WebVerifyIn(BaseModel):
    email: str
    code: str
    user_agent: str = ""


class WebTokenIn(BaseModel):
    token: str


class WebProjectIn(BaseModel):
    token: str
    id: str
    name: str = ""
    document: dict



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


def _start_checkout(*, customer_name: str, customer_email: str, phone: str = "", address: str = "") -> tuple[Optional["stripe.checkout.Session"], Optional[str]]:
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

    try:
        session = stripe_client.create_subscription_checkout(customer_name=customer_name, customer_email=customer_email, customer_id=customer_id)
    except stripe.error.StripeError as e:
        log.error("Stripe checkout session creation failed: %s", e)
        return None, "Payment setup failed — please try again in a moment."

    db.create_checkout_session(stripe_session_id=session.id, customer_name=customer_name, customer_email=customer_email, customer_id=customer_id)
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
    session, error = _start_checkout(customer_name=body.customer_name, customer_email=body.customer_email, phone=body.phone, address=body.address)
    if error:
        status = 502 if "Payment setup failed" in error else 400
        return JSONResponse({"error": error}, status_code=status)
    return {"checkout_url": session.url}


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
        "payments": db.list_payments_for_customer(customer["id"]),
        "can_manage_billing": bool(customer["stripe_customer_id"]),
        "message": message or None,
        "error": error or None,
    })


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
def api_web_signin_request(body: WebEmailIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        return web_access.request_code(email=body.email)
    except activation.ActivationError as e:
        return _activation_error(e, status=429 if e.code == "rate_limited" else 400)


@app.post("/api/web/signin/verify")
def api_web_signin_verify(body: WebVerifyIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        session = web_access.verify_code(email=body.email, code=body.code, user_agent=body.user_agent)
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


@app.post("/api/web/checkout")
def api_web_checkout(body: WebTokenIn, x_api_key: Optional[str] = Header(None)):
    _require_web_key(x_api_key)
    try:
        return {"url": web_access.checkout_url(token=body.token)}
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

    obj = event["data"]["object"]
    kind = event["type"]
    try:
        if kind == "checkout.session.completed":
            _fulfill_checkout(obj, stripe_event_id=event["id"])
        elif kind in ("customer.subscription.created", "customer.subscription.updated", "customer.subscription.deleted"):
            subscriptions.sync_from_stripe(dict(obj), stripe_event_id=event["id"])
        elif kind == "invoice.paid":
            subscriptions.record_invoice(dict(obj), paid=True, stripe_event_id=event["id"])
        elif kind == "invoice.payment_failed":
            subscriptions.record_invoice(dict(obj), paid=False, stripe_event_id=event["id"])
    except ValueError as e:
        # A subscription we can't tie to any customer — log loudly, but
        # ack so Stripe doesn't retry forever; the admin's "Sync from
        # Stripe" button can repair it once the customer record exists.
        log.error("Webhook %s (%s) could not be applied: %s", event["id"], kind, e)
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
def subscribers(request: Request, q: str = "", status: str = "", message: str = "", error: str = ""):
    return templates.TemplateResponse(request, "subscribers.html", {
        "active_nav": "subscribers",
        "subscriptions": db.list_subscriptions(q, status=status),
        "pending_checkouts": db.list_pending_checkouts(),
        "query": q,
        "status": status,
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
        "subscriptions": db.list_subscriptions_for_customer(customer_id),
        "devices": db.list_active_devices(customer_id),
        "payments": db.list_payments_for_customer(customer_id),
        "events": db.list_events_for_customer(customer_id),
        "trial_ends": trial_ends,
        "today": datetime.now(timezone.utc).date().isoformat(),
        "message": message or None,
        "error": error or None,
    })


@app.post("/admin/customers/{customer_id}/comp", dependencies=[Depends(auth.require_admin)])
def customer_comp(customer_id: int, months: str = Form("1"), until: str = Form(""), note: str = Form(""), send_email: str = Form("")):
    if db.get_customer(customer_id) is None:
        return RedirectResponse("/admin/subscribers", status_code=303)
    until_dt = None
    if until.strip():
        try:
            until_dt = datetime.fromisoformat(until.strip()).replace(hour=23, minute=59, second=59, tzinfo=timezone.utc)
        except ValueError:
            return _customer_redirect(customer_id, error="The end date must look like 2026-12-31.")
    months_n = int(months) if months.strip().isdigit() else 1
    _, email_error = subscriptions.grant_comp(customer_id=customer_id, months=months_n, until=until_dt, note=note.strip(), send_email=bool(send_email))
    msg = "Complimentary access granted."
    if send_email:
        msg += " Email sent." if not email_error else f" Email NOT sent: {email_error}"
    return _customer_redirect(customer_id, message=msg)


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


# ----------------------------------------------------------- financials ---


@app.get("/admin/financials", response_class=HTMLResponse, dependencies=[Depends(auth.require_admin)])
def financials(request: Request):
    return templates.TemplateResponse(request, "financials.html", {"months": db.monthly_revenue(), "counts": db.subscriber_counts(), "active_nav": "financials"})


@app.get("/admin/financials.csv", dependencies=[Depends(auth.require_admin)])
def financials_csv():
    buffer = io.StringIO()
    writer = csv.writer(buffer)
    writer.writerow(["month", "payments", "revenue_usd", "subscriptions_started", "subscriptions_ended"])
    for m in db.monthly_revenue(months=1000):
        writer.writerow([m["month"], m["payment_count"], f"{m['revenue_cents'] / 100:.2f}", m["started"], m["ended"]])
    buffer.seek(0)
    return StreamingResponse(buffer, media_type="text/csv", headers={"Content-Disposition": "attachment; filename=piperstitch_revenue.csv"})


# --------------------------------------------------------------- updates ---

_VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")


def _version_tuple(v: str) -> tuple[int, ...]:
    return tuple(int(p) for p in v.split("."))


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
