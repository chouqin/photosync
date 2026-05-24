import os
import io
import hashlib
from pathlib import Path
from PIL import Image, ExifTags

from config import get_settings

settings = get_settings()
THUMB_DIR = Path(settings.thumbnail_cache_dir)
THUMB_DIR.mkdir(parents=True, exist_ok=True)
SIZES = [int(s.strip()) for s in settings.thumbnail_sizes.split(",") if s.strip()]


def _get_cache_path(checksum: str, size: int) -> Path:
    """Use checksum prefix for directory sharding to avoid too many files in one dir."""
    prefix = checksum[:2] if len(checksum) >= 2 else "xx"
    return THUMB_DIR / prefix / f"{checksum}_{size}.jpg"


def _correct_orientation(img: Image.Image) -> Image.Image:
    """Correct image orientation based on EXIF data."""
    try:
        exif = img._getexif()
        if exif is None:
            return img
        orientation = None
        for tag, value in exif.items():
            if ExifTags.TAGS.get(tag) == "Orientation":
                orientation = value
                break
        if orientation == 3:
            img = img.rotate(180, expand=True)
        elif orientation == 6:
            img = img.rotate(270, expand=True)
        elif orientation == 8:
            img = img.rotate(90, expand=True)
    except Exception:
        pass
    return img


def generate_thumbnail(data: bytes, size: int = 256, quality: int = 85) -> bytes:
    """Generate a thumbnail from image bytes. Returns JPEG bytes."""
    img = Image.open(io.BytesIO(data))
    img = _correct_orientation(img)
    img.thumbnail((size, size), Image.LANCZOS)

    # Convert to RGB if necessary
    if img.mode in ("RGBA", "P"):
        img = img.convert("RGB")

    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=quality, optimize=True)
    return buf.getvalue()


def get_or_create_thumbnail(data: bytes, checksum: str, size: int = 256) -> Path:
    """Return path to cached thumbnail, generating if needed."""
    if size not in SIZES:
        size = SIZES[0] if SIZES else 256

    cache_path = _get_cache_path(checksum, size)
    if cache_path.exists():
        return cache_path

    cache_path.parent.mkdir(parents=True, exist_ok=True)
    thumb_bytes = generate_thumbnail(data, size)
    cache_path.write_bytes(thumb_bytes)
    return cache_path


def get_thumbnail_path(checksum: str, size: int) -> Path:
    """Return the expected filesystem path for a thumbnail."""
    return _get_cache_path(checksum, size)


def get_thumbnail_bytes(data: bytes, checksum: str, size: int = 256) -> bytes:
    """Generate thumbnail and return raw bytes (without caching)."""
    if size not in SIZES:
        size = SIZES[0] if SIZES else 256
    return generate_thumbnail(data, size)


def cleanup_old_thumbnails(max_age_days: int = 30):
    """Remove thumbnail files older than max_age_days."""
    import time
    now = time.time()
    max_age = max_age_days * 86400
    removed = 0
    for f in THUMB_DIR.rglob("*.jpg"):
        if now - f.stat().st_mtime > max_age:
            f.unlink()
            removed += 1
    return removed


def get_image_dimensions(data: bytes) -> tuple:
    """Return (width, height) from image bytes."""
    img = Image.open(io.BytesIO(data))
    return img.width, img.height


def get_exif_datetime(data: bytes) -> str:
    """Try to extract DateTimeOriginal from EXIF."""
    try:
        img = Image.open(io.BytesIO(data))
        exif = img._getexif()
        if exif:
            for tag, value in exif.items():
                if ExifTags.TAGS.get(tag) == "DateTimeOriginal":
                    return value
    except Exception:
        pass
    return None
