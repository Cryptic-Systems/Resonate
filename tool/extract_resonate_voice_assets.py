#!/usr/bin/env python3
"""Extract the Resonate voice archives and activate filename-mapped manifest assets.

This intentionally does not normalize or transcode the original MP3s.
"""
from __future__ import annotations

import json
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VOICE_ROOT = ROOT / "assets/audio/resonate_voice"
MANIFEST_PATH = VOICE_ROOT / "voice_manifest.json"
ARCHIVE_ROOT = VOICE_ROOT / "source_archives"


def safe_basename(value: str) -> str:
    name = Path(value.replace("\\", "/")).name
    if not name or name in {".", ".."}:
        raise ValueError(f"Unsafe archive path: {value!r}")
    return name


def main() -> None:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    entries = manifest["assets"]
    if len(entries) != 84:
        raise SystemExit(f"Expected 84 manifest records, found {len(entries)}")

    grouped: dict[str, list[dict]] = {}
    for entry in entries:
        grouped.setdefault(entry["sourceArchive"], []).append(entry)

    ARCHIVE_ROOT.mkdir(parents=True, exist_ok=True)
    extracted = 0
    missing: list[str] = []

    for old_archive, records in grouped.items():
        source = ROOT / old_archive
        category = records[0]["category"]
        basename = safe_basename(old_archive)
        archive_name = basename if basename.startswith(f"{category}__") else f"{category}__{basename}"
        archive_destination = ARCHIVE_ROOT / archive_name
        archive_destination.parent.mkdir(parents=True, exist_ok=True)
        if not archive_destination.is_file():
            if not source.is_file():
                missing.append(f"source archive missing: {old_archive}")
                continue
            if source.resolve() != archive_destination.resolve():
                shutil.move(str(source), str(archive_destination))

        with zipfile.ZipFile(archive_destination) as archive:
            members = [m for m in archive.namelist() if not m.endswith("/") and m.lower().endswith(".mp3")]
            by_basename: dict[str, list[str]] = {}
            for member in members:
                by_basename.setdefault(safe_basename(member), []).append(member)

            category_dir = VOICE_ROOT / category
            category_dir.mkdir(parents=True, exist_ok=True)
            for entry in records:
                filename = entry["filename"]
                candidates = by_basename.get(filename, [])
                if not candidates:
                    missing.append(f"{filename} not found in {archive_destination.relative_to(ROOT)}")
                    continue
                # Preserve the filename exactly; nested archive directories are flattened
                # into their manifest category to give Flutter a stable asset path.
                member = candidates[0]
                destination = category_dir / filename
                destination.write_bytes(archive.read(member))
                entry["sourceArchive"] = str(archive_destination.relative_to(ROOT)).replace("\\", "/")
                entry["assetPath"] = str(destination.relative_to(ROOT)).replace("\\", "/")
                entry["runtimeEnabled"] = True
                extracted += 1

    if missing:
        raise SystemExit("Voice archive extraction did not match the manifest:\n" + "\n".join(missing))
    if extracted != 84:
        raise SystemExit(f"Expected 84 extracted cues, got {extracted}")

    manifest["status"] = "filename_routes_enabled_audio_assets_extracted_listening_review_pending"
    manifest["description"] = (
        "84 original MP3s extracted into stable Flutter asset paths using the manifest filenames. "
        "No clips were transcribed by listening and no audio was normalized or transcoded. "
        "Routing and semantic groups are filename-derived proposals and are now wired for playback; "
        "review any phrase/trigger mismatch during real playback."
    )
    MANIFEST_PATH.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    # Source ZIPs are retained outside the Flutter asset directories. Register
    # each category folder so all extracted clips are bundled by Flutter.
    pubspec = ROOT / "pubspec.yaml"
    text = pubspec.read_text(encoding="utf-8")
    marker = "    - assets/sfx/\n"
    categories = sorted({entry["category"] for entry in entries})
    missing_asset_dirs = [
        category for category in categories
        if f"    - assets/audio/resonate_voice/{category}/" not in text
    ]
    additions = "".join(
        f"    - assets/audio/resonate_voice/{category}/\n"
        for category in missing_asset_dirs
    )
    if additions:
        if marker not in text:
            raise SystemExit("Could not find assets/sfx entry in pubspec.yaml")
        text = text.replace(marker, marker + additions)
        pubspec.write_text(text, encoding="utf-8")


