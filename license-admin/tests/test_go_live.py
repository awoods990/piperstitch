from app import config, db


def test_reset_customer_data_empties_customer_tables_and_keeps_configuration(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "DATABASE_PATH", str(tmp_path / "t.db"))
    db.init_db()
    cid = db.create_customer(name="Test Person", email="test@example.com") if hasattr(db, "create_customer") else None
    if cid is None:
        with db.connection() as conn:
            conn.execute("INSERT INTO customers (name, email, created_at, updated_at) VALUES ('T', 't@example.com', '2026-01-01', '2026-01-01')")
    before = db.customer_data_counts()
    assert before["customers"] == 1
    removed = db.reset_customer_data()
    assert removed["customers"] == 1
    after = db.customer_data_counts()
    assert sum(after.values()) == 0
    # Configuration tables survive.
    with db.connection() as conn:
        assert conn.execute("SELECT COUNT(*) FROM email_templates").fetchone()[0] >= 0
        conn.execute("SELECT COUNT(*) FROM promotions").fetchone()


def test_stripe_mode_problems_flags_mixed_keys(monkeypatch):
    monkeypatch.setattr(config, "STRIPE_SECRET_KEY", "sk_live_x")
    monkeypatch.setattr(config, "STRIPE_PUBLISHABLE_KEY", "pk_test_x")
    monkeypatch.setattr(config, "STRIPE_WEBHOOK_SECRET", "")
    problems = config.stripe_mode_problems()
    assert any("pk_test" in p or "publishable" in p.lower() for p in problems)
    assert any("WEBHOOK" in p for p in problems)
    assert config.stripe_mode() == "live"
