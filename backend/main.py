import os
import io
import hashlib
from datetime import datetime
from typing import Optional

from fastapi import FastAPI, APIRouter, Depends, HTTPException, UploadFile, File, Query, Request
from fastapi.responses import FileResponse, StreamingResponse, RedirectResponse
from sqlalchemy import select, desc
from sqlalchemy.orm import Session

from config import get_settings
from models import init_db_sync, get_db_sync, Photo, Thumbnail
from auth import create_access_token, get_current_user
from storage import blob_storage
from thumbnails import (
    get_or_create_thumbnail,
    get_thumbnail_bytes,
    get_image_dimensions,
    get_exif_datetime,
)

settings = get_settings()

app = FastAPI(title=settings.app_name)
router = APIRouter(prefix="/api")

# Initialize DB on startup
@app.on_event("startup")
def on_startup():
    init_db_sync()


# ---------- Auth ----------

@router.post("/auth/token")
async def login(request: Request):
    try:
        data = await request.json()
    except Exception:
        data = {}
    username = data.get("username", "")
    password = data.get("password", "")

    if password != settings.photosync_password:
        raise HTTPException(status_code=401, detail="Incorrect password")

    token = create_access_token(data={"sub": username})
    return {"access_token": token, "token_type": "bearer"}


# ---------- Photos ----------

@router.get("/photos")
def list_photos(
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=200),
    db: Session = Depends(get_db_sync),
    user_id: str = Depends(get_current_user),
):
    offset = (page - 1) * page_size
    result = db.execute(
        select(Photo)
        .order_by(desc(Photo.taken_at))
        .offset(offset)
        .limit(page_size)
    )
    photos = result.scalars().all()

    total = db.execute(select(Photo)).scalars().all()
    total_count = len(total)

    return {
        "items": [p.to_dict() for p in photos],
        "page": page,
        "page_size": page_size,
        "total": total_count,
    }


@router.post("/photos/upload")
def upload_photo(
    file: UploadFile = File(...),
    device_id: Optional[str] = None,
    db: Session = Depends(get_db_sync),
    user_id: str = Depends(get_current_user),
):
    if not file.filename:
        raise HTTPException(status_code=400, detail="No file provided")

    contents = file.file.read()
    max_size = settings.max_upload_size_mb * 1024 * 1024
    if len(contents) > max_size:
        raise HTTPException(status_code=413, detail=f"File too large, max {settings.max_upload_size_mb}MB")

    checksum = hashlib.sha256(contents).hexdigest()

    existing = db.execute(select(Photo).where(Photo.checksum == checksum)).scalar_one_or_none()
    if existing:
        return {"id": existing.id, "duplicate": True}

    mime_type = file.content_type or "application/octet-stream"
    width, height = get_image_dimensions(contents)
    exif_date_str = get_exif_datetime(contents)
    taken_at = None
    if exif_date_str:
        try:
            taken_at = datetime.strptime(exif_date_str, "%Y:%m:%d %H:%M:%S")
        except ValueError:
            pass

    blob_path = blob_storage.upload_file(
        io.BytesIO(contents),
        filename=file.filename,
        mime_type=mime_type,
        file_size=len(contents),
    )

    photo = Photo(
        filename=file.filename,
        original_path=blob_path,
        file_size=len(contents),
        width=width,
        height=height,
        mime_type=mime_type,
        checksum=checksum,
        device_id=device_id,
        taken_at=taken_at,
    )
    db.add(photo)
    db.commit()
    db.refresh(photo)

    for size in [int(s) for s in settings.thumbnail_sizes.split(",") if s.strip()]:
        thumb_path = get_or_create_thumbnail(contents, checksum, size)
        thumb = Thumbnail(
            photo_id=photo.id,
            size=size,
            local_path=str(thumb_path),
        )
        db.add(thumb)
    db.commit()

    return {"id": photo.id, "duplicate": False, "photo": photo.to_dict()}


@router.get("/photos/{photo_id}")
def get_photo(
    photo_id: str,
    db: Session = Depends(get_db_sync),
    user_id: str = Depends(get_current_user),
):
    photo = db.execute(select(Photo).where(Photo.id == photo_id)).scalar_one_or_none()
    if not photo:
        raise HTTPException(status_code=404, detail="Photo not found")
    return photo.to_dict()


@router.get("/photos/{photo_id}/thumbnail")
def get_thumbnail(
    photo_id: str,
    size: int = Query(256),
    db: Session = Depends(get_db_sync),
    user_id: str = Depends(get_current_user),
):
    photo = db.execute(select(Photo).where(Photo.id == photo_id)).scalar_one_or_none()
    if not photo:
        raise HTTPException(status_code=404, detail="Photo not found")

    thumb = db.execute(
        select(Thumbnail).where(Thumbnail.photo_id == photo_id, Thumbnail.size == size)
    ).scalar_one_or_none()

    if thumb and os.path.exists(thumb.local_path):
        return FileResponse(thumb.local_path, media_type="image/jpeg")

    buf = io.BytesIO()
    blob_storage.download_file(photo.original_path, buf)
    thumb_bytes = get_thumbnail_bytes(buf.getvalue(), photo.checksum, size)

    cache_path = get_or_create_thumbnail(buf.getvalue(), photo.checksum, size)

    if not thumb:
        thumb = Thumbnail(photo_id=photo_id, size=size, local_path=str(cache_path))
        db.add(thumb)
    else:
        thumb.local_path = str(cache_path)
    db.commit()

    return FileResponse(cache_path, media_type="image/jpeg")


@router.get("/photos/{photo_id}/original")
def get_original(
    photo_id: str,
    redirect: bool = Query(True),
    db: Session = Depends(get_db_sync),
    user_id: str = Depends(get_current_user),
):
    photo = db.execute(select(Photo).where(Photo.id == photo_id)).scalar_one_or_none()
    if not photo:
        raise HTTPException(status_code=404, detail="Photo not found")

    if redirect:
        sas_url = blob_storage.get_sas_url(photo.original_path, expiry_hours=1)
        return RedirectResponse(url=sas_url)

    buf = io.BytesIO()
    blob_storage.download_file(photo.original_path, buf)
    buf.seek(0)
    return StreamingResponse(
        buf,
        media_type=photo.mime_type or "application/octet-stream",
        headers={"Content-Disposition": f'attachment; filename="{photo.filename}"'},
    )


@router.delete("/photos/{photo_id}")
def delete_photo(
    photo_id: str,
    db: Session = Depends(get_db_sync),
    user_id: str = Depends(get_current_user),
):
    photo = db.execute(select(Photo).where(Photo.id == photo_id)).scalar_one_or_none()
    if not photo:
        raise HTTPException(status_code=404, detail="Photo not found")

    blob_storage.delete_file(photo.original_path)

    thumbs = db.execute(select(Thumbnail).where(Thumbnail.photo_id == photo_id)).scalars().all()
    for thumb in thumbs:
        if os.path.exists(thumb.local_path):
            os.remove(thumb.local_path)
        db.delete(thumb)

    db.delete(photo)
    db.commit()
    return {"deleted": True}


# ---------- Health ----------

@app.get("/health")
def health():
    return {"status": "ok"}


app.include_router(router)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=settings.api_host, port=settings.api_port)
