from cryptography.fernet import Fernet

from campusflow_agent.config import Settings
from campusflow_agent.key_vault import ApiKeyVault


def test_api_key_is_encrypted_and_round_trips() -> None:
    settings = Settings(
        app_env="test",
        database_path=":memory:",
        app_secret_key=Fernet.generate_key().decode("ascii"),
    )
    vault = ApiKeyVault(settings)
    raw = "sk-never-store-this-value"
    encrypted = vault.encrypt(raw)

    assert raw not in encrypted
    assert vault.decrypt(encrypted) == raw
