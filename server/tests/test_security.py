from app.security import decrypt_password, protect_password, query_fingerprint


def test_password_round_trip_and_fingerprint_are_stable():
    protected = protect_password("Sup3r$ecret!")

    assert decrypt_password(protected.encrypted_password) == "Sup3r$ecret!"
    assert protected.password_fingerprint == query_fingerprint("Sup3r$ecret!")
    assert protected.password_hash.startswith("$argon2id$")
