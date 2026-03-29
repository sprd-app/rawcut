"""Application configuration loaded from environment variables."""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Rawcut backend configuration.

    All values are read from environment variables or a .env file.
    """

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=True,
    )

    # Azure Storage
    AZURE_STORAGE_CONNECTION_STRING: str = ""
    AZURE_STORAGE_CONTAINER: str = "rawcut-media"

    # AI
    OPENAI_API_KEY: str = ""
    ANTHROPIC_API_KEY: str = ""

    # Apple Sign-In
    APPLE_TEAM_ID: str = ""

    # Database
    DATABASE_URL: str = "sqlite+aiosqlite:///rawcut.db"

    # Dev mode: skip auth token verification, use a fixed dev user
    DEV_MODE: bool = False

    # Internal signing
    SECRET_KEY: str = "change-me-to-a-random-secret"

    @property
    def sqlite_path(self) -> str:
        """Extract the raw file path from the DATABASE_URL."""
        prefix = "sqlite+aiosqlite:///"
        if self.DATABASE_URL.startswith(prefix):
            return self.DATABASE_URL[len(prefix):]
        return self.DATABASE_URL


settings = Settings()
