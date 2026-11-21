"""Stream the pinned runtime's screenshot component downloads during setup."""

from contextlib import contextmanager
import time


CONNECT_TIMEOUT = 10
READ_TIMEOUT = 20
DOWNLOAD_TIMEOUT = 12 * 60
READ_SIZE = 64 * 1024


class ImageDownloadError(Exception):
    pass


def download_blob(url, headers, progress=None):
    import requests
    from urllib3.exceptions import HTTPError

    deadline = time.monotonic() + DOWNLOAD_TIMEOUT
    try:
        with requests.get(url, headers=headers, stream=True, timeout=(CONNECT_TIMEOUT, READ_TIMEOUT)) as response:
            if response.status_code == 404:
                return None
            if response.status_code != 200:
                raise ImageDownloadError(f"HTTP {response.status_code}")

            length = response.raw.length_remaining
            encoding = response.headers.get("Content-Encoding", "identity").lower()
            total = length if encoding == "identity" and length else None
            payload = bytearray()
            last_percent = None
            if progress is not None and total is not None:
                progress(0)
                last_percent = 0
            while True:
                if time.monotonic() >= deadline:
                    raise ImageDownloadError("download deadline reached")
                chunk = response.raw.read1(READ_SIZE, decode_content=True)
                if not chunk:
                    break
                payload.extend(chunk)
                if progress is not None and total is not None:
                    percent = min(99, len(payload) * 100 // total)
                    if percent != last_percent:
                        progress(percent)
                        last_percent = percent
            if total is not None and len(payload) != total:
                raise ImageDownloadError("incomplete response")
            if progress is not None and total is not None:
                progress(100)
            return bytes(payload)
    except (requests.RequestException, HTTPError, OSError) as error:
        raise ImageDownloadError("component download interrupted") from error


@contextmanager
def report_image_download(progress, finished):
    """Use bounded streaming for the vendor repository in the setup process."""
    from developer_disk_image.repo import DeveloperDiskImageRepository, DEVELOPER_DISK_IMAGE_REPO_RAW_URL_FORMAT

    original = DeveloperDiskImageRepository._get_blob

    def get_blob(repository, path):
        url = DEVELOPER_DISK_IMAGE_REPO_RAW_URL_FORMAT.format(ref=repository.ref, path=path)
        headers = {"Accept-Encoding": "identity"}
        if repository.github_token is not None:
            headers["Authorization"] = "Bearer " + repository.github_token
        if not path.endswith(".dmg"):
            return download_blob(url, headers)
        progress(None)
        try:
            return download_blob(url, headers, progress)
        finally:
            finished()

    DeveloperDiskImageRepository._get_blob = get_blob
    try:
        yield
    finally:
        DeveloperDiskImageRepository._get_blob = original
