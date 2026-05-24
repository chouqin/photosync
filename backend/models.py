import uuid
from datetime import datetime
from sqlalchemy import String, Integer, DateTime, Text, create_engine
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker, Session

from config import get_settings

settings = get_settings()

import sqlite3

# Sync engine (async SQLAlchemy + aiosqlite has greenlet issues in Docker)
# Use creator to bypass SQLAlchemy's default SQLite connection logic
_db_path = settings.database_url.replace("sqlite+aiosqlite://", "").replace("sqlite://", "")
# sqlite:///app/data/db/photosync.db -> /app/data/db/photosync.db (absolute path)

def _sqlite_creator():
    conn = sqlite3.connect(
        _db_path,
        check_same_thread=False,
        timeout=30.0,
    )
    # WAL mode allows concurrent reads while a write is in progress
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA synchronous=NORMAL;")
    return conn

engine = create_engine(
    "sqlite://",
    creator=_sqlite_creator,
    echo=settings.debug,
    future=True,
    pool_pre_ping=True,
)

SessionLocal = sessionmaker(
    engine,
    expire_on_commit=False,
    autoflush=False,
    autocommit=False,
)


class Base(DeclarativeBase):
    pass


class Photo(Base):
    __tablename__ = "photos"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    filename: Mapped[str] = mapped_column(String(512), nullable=False)
    original_path: Mapped[str] = mapped_column(Text, nullable=False)
    file_size: Mapped[int] = mapped_column(Integer, nullable=False)
    width: Mapped[int] = mapped_column(Integer, nullable=True)
    height: Mapped[int] = mapped_column(Integer, nullable=True)
    mime_type: Mapped[str] = mapped_column(String(64), nullable=True)
    checksum: Mapped[str] = mapped_column(String(64), nullable=True)
    device_id: Mapped[str] = mapped_column(String(128), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    taken_at: Mapped[datetime] = mapped_column(DateTime, nullable=True)

    def to_dict(self):
        return {
            "id": self.id,
            "filename": self.filename,
            "file_size": self.file_size,
            "width": self.width,
            "height": self.height,
            "mime_type": self.mime_type,
            "checksum": self.checksum,
            "device_id": self.device_id,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "taken_at": self.taken_at.isoformat() if self.taken_at else None,
        }


class Thumbnail(Base):
    __tablename__ = "thumbnails"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    photo_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    size: Mapped[int] = mapped_column(Integer, nullable=False)
    local_path: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)


def init_db_sync():
    Base.metadata.create_all(bind=engine)


def get_db_sync():
    session = SessionLocal()
    try:
        yield session
    finally:
        session.close()
