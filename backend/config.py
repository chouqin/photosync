from pydantic_settings import BaseSettings
from functools import lru_cache


class Settings(BaseSettings):
    # API
    app_name: str = "PhotoSync API"
    debug: bool = False
    api_host: str = "0.0.0.0"
    api_port: int = 8000

    # Security
    secret_key: str = "change-me-in-production-please-use-a-strong-random-key"
    algorithm: str = "HS256"
    access_token_expire_minutes: int = 60 * 24 * 30  # 30 days for mobile app

    # Azure Blob Storage
    azure_storage_account: str = ""
    azure_storage_key: str = ""  # or use SAS / managed identity
    azure_storage_container: str = "photos"
    azure_storage_tier: str = "Cool"  # Cool | Hot | Archive

    # Auth
    photosync_password: str = "change-me-to-a-strong-password"

    # Database
    database_url: str = "sqlite+aiosqlite:///data/db/photosync.db"

    # Thumbnails
    thumbnail_cache_dir: str = "/app/data/cache"
    thumbnail_sizes: str = "256,512,1024"  # comma separated

    # Upload
    max_upload_size_mb: int = 50
    upload_chunk_size: int = 4 * 1024 * 1024  # 4MB

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"


@lru_cache()
def get_settings() -> Settings:
    return Settings()
