import os
import io
import hashlib
from datetime import datetime
from typing import Optional, List

from fastapi import FastAPI, APIRouter, Depends, HTTPException, UploadFile, File, Query, Request
from fastapi.responses import FileResponse, StreamingResponse, RedirectResponse, JSONResponse
from pydantic import BaseModel
from sqlalchemy import select, desc
from sqlalchemy.orm import Session
from sqlalchemy.exc import SQLAlchemyError

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


# ---------- Pydantic Response Models (for Swagger docs) ----------

class TokenResponse(BaseModel):
    access_token: str
    token_type: str


class PhotoDict(BaseModel):
    id: str
    filename: str
    file_size: int
    width: Optional[int] = None
    height: Optional[int] = None
    mime_type: Optional[str] = None
    checksum: Optional[str] = None
    device_id: Optional[str] = None
    created_at: Optional[str] = None
    taken_at: Optional[str] = None


class PhotoListResponse(BaseModel):
    items: List[PhotoDict]
    page: int
    page_size: int
    total: int


class UploadResponse(BaseModel):
    id: str
    duplicate: bool
    photo: Optional[PhotoDict] = None


class DeleteResponse(BaseModel):
    deleted: bool


class HealthResponse(BaseModel):
    status: str


# ---------- FastAPI App + Swagger Tags ----------

tags_metadata = [
    {"name": "认证", "description": "用户登录与 JWT Token 获取"},
    {"name": "照片", "description": "照片的上传、浏览、下载与删除"},
    {"name": "系统", "description": "健康检查等服务端点"},
]

app = FastAPI(
    title=settings.app_name,
    description="PhotoSync 家庭照片云同步后端 API",
    version="1.0.0",
    openapi_tags=tags_metadata,
)
router = APIRouter(prefix="/api")

# Initialize DB on startup
@app.on_event("startup")
def on_startup():
    init_db_sync()


# ---------- Auth ----------

@router.post(
    "/auth/token",
    tags=["认证"],
    summary="用户登录",
    response_model=TokenResponse,
    response_description="登录成功，返回 JWT Token",
)
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

@router.get(
    "/photos",
    tags=["照片"],
    summary="获取照片列表",
    response_model=PhotoListResponse,
    response_description="分页返回照片元数据列表",
)
def list_photos(
    page: int = Query(1, ge=1, description="页码，从 1 开始"),
    page_size: int = Query(50, ge=1, le=200, description="每页数量"),
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


@router.post(
    "/photos/upload",
    tags=["照片"],
    summary="上传照片",
    response_model=UploadResponse,
    response_description="上传成功返回照片信息；若重复则返回 duplicate=true",
)
def upload_photo(
    file: UploadFile = File(..., description="照片文件"),
    device_id: Optional[str] = Query(None, description="设备标识"),
    db: Session = Depends(get_db_sync),
    user_id: str = Depends(get_current_user),
):
    if not file.filename:
        raise HTTPException(status_code=400, detail="未提供文件")

    # 1. 读取文件
    try:
        contents = file.file.read()
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"读取文件失败: {e}")

    # 2. 大小检查
    max_size = settings.max_upload_size_mb * 1024 * 1024
    if len(contents) > max_size:
        raise HTTPException(status_code=413, detail=f"文件过大，最大允许 {settings.max_upload_size_mb}MB")

    # 3. 计算 checksum 并查重
    checksum = hashlib.sha256(contents).hexdigest()
    try:
        existing = db.execute(select(Photo).where(Photo.checksum == checksum)).scalar_one_or_none()
    except SQLAlchemyError as e:
        raise HTTPException(status_code=500, detail=f"数据库查询失败: {e}")

    if existing:
        return {"id": existing.id, "duplicate": True, "photo": existing.to_dict()}

    # 4. 解析图片元数据
    mime_type = file.content_type or "application/octet-stream"
    try:
        width, height = get_image_dimensions(contents)
    except Exception as e:
        raise HTTPException(status_code=422, detail=f"无法解析图片: {e}")

    exif_date_str = get_exif_datetime(contents)
    taken_at = None
    if exif_date_str:
        try:
            taken_at = datetime.strptime(exif_date_str, "%Y:%m:%d %H:%M:%S")
        except ValueError:
            pass

    # 5. 上传到云存储
    try:
        blob_path = blob_storage.upload_file(
            io.BytesIO(contents),
            filename=file.filename,
            mime_type=mime_type,
            file_size=len(contents),
        )
    except Exception as e:
        # 存储服务异常（Azure 连接失败、认证失败、容器不存在等）
        raise HTTPException(status_code=502, detail=f"云存储上传失败: {e}")

    # 6. 写入数据库
    try:
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
    except SQLAlchemyError as e:
        # 数据库写入失败，但文件已上传成功 —— 记录不一致，但先返回错误
        raise HTTPException(status_code=500, detail=f"数据库写入失败: {e}")

    # 7. 生成缩略图
    try:
        for size in [int(s) for s in settings.thumbnail_sizes.split(",") if s.strip()]:
            thumb_path = get_or_create_thumbnail(contents, checksum, size)
            thumb = Thumbnail(
                photo_id=photo.id,
                size=size,
                local_path=str(thumb_path),
            )
            db.add(thumb)
        db.commit()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"缩略图生成失败: {e}")

    return {"id": photo.id, "duplicate": False, "photo": photo.to_dict()}


@router.get(
    "/photos/{photo_id}",
    tags=["照片"],
    summary="获取单张照片元数据",
    response_model=PhotoDict,
    response_description="照片详细信息",
)
def get_photo(
    photo_id: str,
    db: Session = Depends(get_db_sync),
    user_id: str = Depends(get_current_user),
):
    photo = db.execute(select(Photo).where(Photo.id == photo_id)).scalar_one_or_none()
    if not photo:
        raise HTTPException(status_code=404, detail="Photo not found")
    return photo.to_dict()


@router.get(
    "/photos/{photo_id}/thumbnail",
    tags=["照片"],
    summary="获取照片缩略图",
    response_description="JPEG 缩略图",
)
def get_thumbnail(
    photo_id: str,
    size: int = Query(256, description="缩略图尺寸（像素）"),
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


@router.get(
    "/photos/{photo_id}/original",
    tags=["照片"],
    summary="获取原图",
    response_description="原图文件，或 302 跳转到 SAS URL",
)
def get_original(
    photo_id: str,
    redirect: bool = Query(True, description="是否 302 跳转到 SAS URL"),
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


@router.delete(
    "/photos/{photo_id}",
    tags=["照片"],
    summary="删除照片",
    response_model=DeleteResponse,
    response_description="删除成功",
)
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

@app.get(
    "/health",
    tags=["系统"],
    summary="健康检查",
    response_model=HealthResponse,
    response_description="服务正常运行",
)
def health():
    return {"status": "ok"}


# ---------- Global Exception Handlers ----------

@app.exception_handler(SQLAlchemyError)
async def sqlalchemy_exception_handler(request: Request, exc: SQLAlchemyError):
    return JSONResponse(
        status_code=500,
        content={"detail": "数据库错误", "error": str(exc)},
    )


@app.exception_handler(Exception)
async def general_exception_handler(request: Request, exc: Exception):
    # 兜底：未捕获的异常返回安全信息（不暴露堆栈）
    return JSONResponse(
        status_code=500,
        content={"detail": "服务器内部错误", "error": str(exc)},
    )


app.include_router(router)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=settings.api_host, port=settings.api_port)
