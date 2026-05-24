import os
import uuid
from datetime import datetime, timedelta
from typing import Optional, BinaryIO

from azure.storage.blob import BlobServiceClient, ContentSettings, StandardBlobTier
from azure.core.exceptions import ResourceNotFoundError

from config import get_settings

settings = get_settings()


class BlobStorage:
    def __init__(self):
        self.account = settings.azure_storage_account
        self.key = settings.azure_storage_key
        self.container = settings.azure_storage_container
        self.tier = settings.azure_storage_tier

        if self.account and self.key:
            conn_str = (
                f"DefaultEndpointsProtocol=https;"
                f"AccountName={self.account};"
                f"AccountKey={self.key};"
                f"EndpointSuffix=core.windows.net"
            )
            self.client = BlobServiceClient.from_connection_string(conn_str)
        else:
            # Fallback: try managed identity or env-based auth
            account_url = f"https://{self.account}.blob.core.windows.net"
            from azure.identity import DefaultAzureCredential
            self.client = BlobServiceClient(account_url, credential=DefaultAzureCredential())

        self.container_client = self.client.get_container_client(self.container)

    def ensure_container(self):
        try:
            self.container_client.create_container()
        except Exception:
            pass  # Already exists

    def _blob_path(self, original_filename: str) -> str:
        now = datetime.utcnow()
        ext = os.path.splitext(original_filename)[1].lower()
        return f"{now.year:04d}/{now.month:02d}/{uuid.uuid4().hex}{ext}"

    def upload_file(
        self,
        data: BinaryIO,
        filename: str,
        mime_type: Optional[str] = None,
        file_size: Optional[int] = None,
    ) -> str:
        """Upload file to blob and return blob path."""
        self.ensure_container()
        blob_path = self._blob_path(filename)
        blob_client = self.container_client.get_blob_client(blob_path)

        content_settings = ContentSettings(content_type=mime_type) if mime_type else None

        blob_client.upload_blob(
            data,
            overwrite=True,
            content_settings=content_settings,
            standard_blob_tier=getattr(StandardBlobTier, self.tier, StandardBlobTier.Cool),
        )
        return blob_path

    def download_file(self, blob_path: str, stream: BinaryIO):
        """Download blob to a stream."""
        blob_client = self.container_client.get_blob_client(blob_path)
        downloader = blob_client.download_blob()
        downloader.readinto(stream)

    def delete_file(self, blob_path: str):
        """Delete blob."""
        blob_client = self.container_client.get_blob_client(blob_path)
        try:
            blob_client.delete_blob()
        except ResourceNotFoundError:
            pass

    def get_sas_url(self, blob_path: str, expiry_hours: int = 1) -> str:
        """Generate a SAS URL for direct download (optional, can also proxy via API)."""
        from azure.storage.blob import generate_blob_sas, BlobSasPermissions

        sas_token = generate_blob_sas(
            account_name=self.account,
            container_name=self.container,
            blob_name=blob_path,
            account_key=self.key,
            permission=BlobSasPermissions(read=True),
            expiry=datetime.utcnow() + timedelta(hours=expiry_hours),
        )
        return f"https://{self.account}.blob.core.windows.net/{self.container}/{blob_path}?{sas_token}"

    def get_properties(self, blob_path: str) -> dict:
        blob_client = self.container_client.get_blob_client(blob_path)
        props = blob_client.get_blob_properties()
        return {
            "size": props.size,
            "tier": props.blob_tier,
            "content_type": props.content_settings.content_type,
        }


blob_storage = BlobStorage()
