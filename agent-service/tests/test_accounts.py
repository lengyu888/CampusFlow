from campusflow_agent.accounts import AccountConflictError, AccountStore, AuthenticationError


def test_account_password_session_and_onboarding() -> None:
    accounts = AccountStore(":memory:")
    user = accounts.register(
        email=" Student@Example.com ",
        password="correct-horse-42",
        display_name="小航",
        api_key_encrypted="encrypted-test-key",
        api_key_hint="•••• test",
    )
    assert user.email == "student@example.com"
    assert user.onboarding_complete is False

    authenticated = accounts.authenticate(
        email="student@example.com",
        password="correct-horse-42",
    )
    token = accounts.create_session(authenticated.user_id)
    assert accounts.resolve_session(token).user_id == user.user_id  # type: ignore[union-attr]

    updated = accounts.update_onboarding(
        user_id=user.user_id,
        school="杭州电子科技大学",
        campus="下沙校区",
        semester="2026-2027 第一学期",
        timetable=[{"date": "2026-10-01", "title": "操作系统"}],
        campus_map={"places": [{"name": "图书馆"}]},
    )
    assert updated.onboarding_complete is True
    timetable, campus_map = accounts.get_context(user.user_id)
    assert timetable[0]["title"] == "操作系统"
    assert campus_map["places"][0]["name"] == "图书馆"

    accounts.delete_session(token)
    assert accounts.resolve_session(token) is None


def test_duplicate_email_and_bad_password_are_rejected() -> None:
    accounts = AccountStore(":memory:")
    accounts.register(
        email="student@example.com",
        password="password-123",
        display_name="A",
        api_key_encrypted="encrypted-a",
        api_key_hint="•••• test",
    )

    try:
        accounts.register(
            email="student@example.com",
            password="password-456",
            display_name="B",
            api_key_encrypted="encrypted-b",
            api_key_hint="•••• test",
        )
    except AccountConflictError:
        pass
    else:
        raise AssertionError("duplicate email must be rejected")

    try:
        accounts.authenticate(email="student@example.com", password="wrong-password")
    except AuthenticationError:
        pass
    else:
        raise AssertionError("wrong password must be rejected")
