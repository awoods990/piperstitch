from app import config, email_branding, email_sender


def test_branding_renders_lists_codes_and_cta():
    html = email_branding.render(body_text="Hi\n\n- one\n- two\n\n123456\n\n---\n\nBye", cta_label="Go", cta_url="https://x.test/?a=1&b=2")
    assert "&bull;" in html and "123456" in html and "letter-spacing" in html and "https://x.test/?a=1&amp;b=2" in html and "<hr" in html
    assert "<script" not in html


def test_every_email_is_multipart_with_text_first(fake_smtp):
    email_sender.send_welcome_email(to_email="a@b.co", customer_name="A")
    email_sender.send_activation_code_email(to_email="a@b.co", code="123456", device_name="Mac")
    email_sender.send_account_link_email(to_email="a@b.co", url="https://x/account/open?token=abc")
    email_sender.send_payment_failed_email(to_email="a@b.co", customer_name="A", account_url="https://x/account")
    email_sender.send_cancellation_scheduled_email(to_email="a@b.co", customer_name="A", ends_on="2026-10-01", account_url="https://x/account")
    email_sender.send_comp_email(to_email="a@b.co", customer_name="A", until="2026-12-31", note="thanks")
    email_sender.send_plain_email(to_email="a@b.co", subject="S", body="B")
    assert len(fake_smtp.sent) == 7
    for msg in fake_smtp.sent:
        assert msg.is_multipart()
        parts = [p.get_content_type() for p in msg.iter_parts()]
        assert parts == ["text/plain", "text/html"]
        assert msg["To"] == "a@b.co"
    assert fake_smtp.sent[1]["Subject"].startswith("123456")
    assert "https://x/account/open?token=abc" in fake_smtp.sent[2].get_body(preferencelist=("plain",)).get_content()


def test_reply_to_header(fake_smtp, monkeypatch):
    monkeypatch.setattr(config, "REPLY_TO_EMAIL", "help@piperstitch.com")
    email_sender.send_welcome_email(to_email="a@b.co", customer_name="A")
    assert fake_smtp.sent[0]["Reply-To"] == "help@piperstitch.com"


def test_postmark_route_when_configured(monkeypatch, fake_smtp):
    import httpx

    from types import SimpleNamespace

    monkeypatch.setattr(config, "POSTMARK_API_TOKEN", "pm-token")
    monkeypatch.setattr(config, "POSTMARK_FROM", "PiperStitch <hello@piperstitch.com>")
    calls = []

    def fake_post(url, json, headers, timeout):
        calls.append((url, json, headers))
        return SimpleNamespace(status_code=200, text="ok")

    monkeypatch.setattr(httpx, "post", fake_post)
    email_sender.send_activation_code_email(to_email="a@b.co", code="654321", device_name="Mac")
    assert fake_smtp.sent == [] and len(calls) == 1
    url, payload, headers = calls[0]
    assert headers["X-Postmark-Server-Token"] == "pm-token" and payload["From"].startswith("PiperStitch") and "654321" in payload["TextBody"] and "<html" in payload["HtmlBody"]

    monkeypatch.setattr(httpx, "post", lambda url, **kw: SimpleNamespace(status_code=422, text="bad"))
    import pytest

    with pytest.raises(email_sender.EmailSendError, match="422"):
        email_sender.send_plain_email(to_email="a@b.co", subject="s", body="b")


def test_auth_hash_roundtrip():
    from app import auth

    h = auth.hash_password("hunter2hunter2")
    assert auth.verify_password("hunter2hunter2", h) and not auth.verify_password("nope", h) and not auth.verify_password("x", "garbage")
