#!/usr/bin/env python3
"""
Windows Healing System (WHS) - Full Documentation & Config Ingestion Pipeline
Crawls, sanitizes, chunks, and consolidates:
- All Markdown/MDX documentation (guides, faq, known issues, architecture)
- config/tweaks.json (with robust control-character repair)
- config/feature.json
- config/preset.json
- config/applications.json
- Local Windows Healing System Config/Features.json
Outputs a unified, high-density KnowledgeBase.json for local Ollama RAG.
"""

import os
import sys
import re
import json
import shutil
import tempfile
import zipfile
import urllib.request
import subprocess

REPO_GIT_URL = "https://github.com/ChrisTitusTech/winutil.git"
REPO_ZIP_URL = "https://github.com/ChrisTitusTech/winutil/archive/refs/heads/main.zip"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = os.path.join(SCRIPT_DIR, "Config")
OUTPUT_FILE = os.path.join(OUTPUT_DIR, "KnowledgeBase.json")

# Parameter mapping from CTT keys to Windows Healing System (WHS) switches
WHS_PARAM_MAPPING = {
    "WPFTweaksTelemetry": "-DisableTelemetry",
    "WPFTweaksBing": "-DisableBing",
    "WPFTweaksGameDVR": "-DisableDVR",
    "WPFTweaksStorageSense": "-DisableStorageSense",
    "WPFTweaksLocation": "-DisableLocationServices",
    "WPFTweaksHome": "-DisableSettingsHome",
    "WPFTweaksShowHiddenFolders": "-ShowHiddenFolders",
    "WPFTweaksShowFileExt": "-ShowKnownFileExt",
    "WPFTweaksDarkMode": "-EnableDarkMode",
    "WPFTweaksFastStartup": "-DisableFastStartup",
    "WPFTweaksCopilot": "-DisableCopilot",
    "WPFTweaksRecall": "-DisableRecall",
    "WPFTweaksEdgeAds": "-DisableEdgeAds",
    "WPFTweaksDeliveryOptimization": "-DisableDeliveryOptimization",
    "WPFTweaksSearchHighlights": "-DisableSearchHighlights",
    "WPFTweaksStickyKeys": "-DisableStickyKeys",
    "WPFTweaksMouseAcceleration": "-DisableMouseAcceleration",
    "WPFTweaksTaskbarAlignLeft": "-TaskbarAlignLeft",
    "WPFTweaksEndTask": "-EnableEndTask",
    "WPFTweaksClassicContextMenu": "-RevertContextMenu",
    "WPFTweaksModernStandby": "-DisableModernStandbyNetworking",
    "WPFTweaksBitlocker": "-DisableBitlockerAutoEncryption",
    "WPFTweaksWidgets": "-DisableWidgets",
    "WPFTweaksRemoveEdge": "-ForceRemoveEdge"
}

# ----------------------------------------------------------------------
# Robust File & Network Handlers
# ----------------------------------------------------------------------

def download_and_extract_repo(target_dir: str) -> str:
    """Clones via git or downloads the repository zip archive as a fallback."""
    # Attempt 1: Shallow git clone
    try:
        print("[*] Attempting shallow git clone of winutil...")
        subprocess.run(
            ["git", "clone", "--depth", "1", REPO_GIT_URL, target_dir],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        print("[✔] Successfully cloned repository via git.")
        return target_dir
    except Exception as e:
        print(f"[i] Git clone unavailable or failed ({e}). Falling back to ZIP download...")

    # Attempt 2: Download ZIP archive
    zip_path = os.path.join(tempfile.gettempdir(), "winutil_main.zip")
    print(f"[*] Downloading {REPO_ZIP_URL} ...")
    req = urllib.request.Request(
        REPO_ZIP_URL,
        headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) WHS-Ingest/1.0"}
    )
    with urllib.request.urlopen(req, timeout=30) as resp, open(zip_path, "wb") as out_f:
        shutil.copyfileobj(resp, out_f)

    print("[*] Extracting repository archive...")
    with zipfile.ZipFile(zip_path, "r") as z:
        z.extractall(target_dir)

    # In zip archives, contents are under a root folder (e.g., winutil-main)
    entries = os.listdir(target_dir)
    for entry in entries:
        full = os.path.join(target_dir, entry)
        if os.path.isdir(full) and "winutil" in entry.lower():
            return full

    return target_dir

def robust_json_loads(raw_content: str):
    """
    Robust JSON parser that:
    1. Strips UTF-8 BOM.
    2. Uses strict=False to tolerate literal unescaped newlines/tabs.
    3. Strips illegal unprintable control characters.
    4. Auto-repairs unescaped Windows backslashes in registry paths.
    """
    if raw_content.startswith('\ufeff'):
        raw_content = raw_content[1:]

    # Attempt 1: Standard load with strict=False
    try:
        return json.loads(raw_content, strict=False)
    except Exception:
        pass

    # Attempt 2: Strip unprintable ASCII control characters (0x00 - 0x1F except \r, \n, \t)
    sanitized = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f]', '', raw_content)
    try:
        return json.loads(sanitized, strict=False)
    except Exception:
        pass

    # Attempt 3: Fix unescaped single backslashes in Windows paths (e.g. \Policies, \Software)
    fixed_escapes = re.sub(r'\\(?![/\\\"bfnrtu])', r'\\\\', sanitized)
    try:
        return json.loads(fixed_escapes, strict=False)
    except Exception as err:
        raise ValueError(f"JSON parsing failed after sanitization attempts: {err}")

# ----------------------------------------------------------------------
# Text Sanitization & Cleaning Filters
# ----------------------------------------------------------------------

def clean_doc_text(text: str) -> str:
    """Strips Markdown/Astro markup, URLs, social callouts, and promo links."""
    if not text:
        return ""

    # Remove Astro/JSX components: <Aside ...>, </Aside>, <Tabs>, etc.
    text = re.sub(r'</?[A-Za-z0-9]+[^>]*>', ' ', text)

    # Convert Markdown images and links: [Text](URL) -> Text, ![Alt](URL) -> Alt
    text = re.sub(r'!\[([^\]]*)\]\([^\)]+\)', r'\1', text)
    text = re.sub(r'\[([^\]]+)\]\([^\)]+\)', r'\1', text)

    # Remove bare URLs
    text = re.sub(r'https?://\S+|www\.\S+', '', text)

    # Filter out promotional, sponsor, and social noise line-by-line
    junk_patterns = [
        'cttstore', 'patreon', 'discord', 'sponsor', 'youtube', 'leave a star',
        'donate', 'subscribe', 'christitus.com', 'merch', 'paypal', 'watch the video',
        'faster dotnet implementation', 'buy an exe', 'github sponsors'
    ]

    cleaned_lines = []
    for line in text.split('\n'):
        line_clean = line.strip()
        if not line_clean or line_clean in ['*', '-', '•', '---']:
            continue
        line_lower = line_clean.lower()
        if any(junk in line_lower for junk in junk_patterns):
            continue
        cleaned_lines.append(line_clean)

    text = ' '.join(cleaned_lines)
    return re.sub(r'\s+', ' ', text).strip()

def generate_search_tags(text_corpus: str) -> list:
    """Generates unique, meaningful keyword tokens for lexical search."""
    stop_words = {
        'this', 'that', 'with', 'from', 'have', 'were', 'will', 'your', 'about',
        'windows', 'system', 'microsoft', 'using', 'which', 'their', 'there',
        'enable', 'disable', 'tweak', 'tweaks', 'setting', 'settings', 'click',
        'apply', 'user', 'users', 'should', 'could', 'would', 'value', 'default'
    }
    raw_tokens = re.findall(r'[a-zA-Z0-9]{3,}', text_corpus.lower())
    tags = {t for t in raw_tokens if t not in stop_words and len(t) > 2}
    return sorted(list(tags))[:18]

# ----------------------------------------------------------------------
# Documentation & Configuration Processors
# ----------------------------------------------------------------------

def process_markdown_file(file_path: str, repo_root: str) -> list:
    """Chunks a Markdown/MDX file by headings into discrete knowledge entries."""
    rel_path = os.path.relpath(file_path, repo_root)
    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()

    # Strip YAML frontmatter
    body = re.sub(r'^---[\s\S]*?---\n*', '', content)
    # Strip Astro/JS imports
    body = re.sub(r'import\s+.*?from\s+[\'"].*?[\'"];?', '', body)

    # Chunk by markdown headers (h1, h2, h3)
    sections = re.split(r'\n(?=#{1,3}\s+)', body)
    entries = []

    for sec in sections:
        sec = sec.strip()
        if not sec:
            continue

        match = re.match(r'^(#{1,3})\s+(.+?)\n([\s\S]*)', sec)
        if match:
            heading = match.group(2).strip()
            text_body = match.group(3).strip()
        else:
            base_name = os.path.basename(file_path).replace(".mdx", "").replace(".md", "")
            heading = base_name.replace("-", " ").replace("_", " ").title()
            text_body = sec

        cleaned_body = clean_doc_text(text_body)
        if len(cleaned_body) < 35:
            continue

        slug = re.sub(r'[^a-zA-Z0-9]+', '_', heading).strip('_')
        doc_id = f"DOC_{slug}"

        summary = cleaned_body[:220] + ("..." if len(cleaned_body) > 220 else "")
        tags = generate_search_tags(heading + " " + cleaned_body)

        entries.append({
            "id": doc_id,
            "title": heading,
            "category": "Documentation & Guides",
            "source": rel_path.replace("\\", "/"),
            "summary": summary,
            "technical_details": cleaned_body,
            "whs_parameter": "",
            "safety_level": "Informational",
            "search_keywords": tags
        })

    return entries

def process_tweaks_json(file_path: str) -> list:
    """Extracts all tweaks, registry modifications, and tooltips from tweaks.json."""
    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
        raw_text = f.read()

    tweaks_data = robust_json_loads(raw_text)
    entries = []

    for tweak_id, tweak_val in tweaks_data.items():
        if not isinstance(tweak_val, dict):
            continue

        title = clean_doc_text(tweak_val.get("Content", tweak_id))
        summary = clean_doc_text(tweak_val.get("Description", ""))
        category = tweak_val.get("category", "Optimization")

        # Format registry operations
        reg_entries = []
        for reg in tweak_val.get("registry", []):
            p = reg.get("Path", "").replace("HKLM:\\", "HKLM\\").replace("HKCU:\\", "HKCU\\")
            n = reg.get("Name", "")
            v = reg.get("Value", "")
            if p and n:
                reg_entries.append(f"{p}\\{n} = {v}")

        tech = ("Registry: " + "; ".join(reg_entries[:3])) if reg_entries else summary

        # Map to WHS parameter if available
        param = WHS_PARAM_MAPPING.get(tweak_id, "")
        if not param:
            clean_name = tweak_id.replace("WPFTweaks", "").lower()
            for k, v in WHS_PARAM_MAPPING.items():
                if clean_name in k.lower():
                    param = v
                    break

        safety = "Safe"
        cat_lower = category.lower()
        if any(w in cat_lower for w in ["essential", "recommended"]):
            safety = "Recommended"
        elif any(w in cat_lower for w in ["advanced", "caution"]) or "remove" in title.lower():
            safety = "Caution"

        tags = generate_search_tags(title + " " + summary + " " + category)

        entries.append({
            "id": tweak_id,
            "title": title,
            "category": category,
            "source": "config/tweaks.json",
            "summary": summary if summary else title,
            "technical_details": tech,
            "whs_parameter": param,
            "safety_level": safety,
            "search_keywords": tags
        })

    return entries

def process_features_json(file_path: str) -> list:
    """Extracts Windows Optional Features from config/feature.json."""
    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
        raw_text = f.read()

    features_data = robust_json_loads(raw_text)
    entries = []

    for feat_id, feat_val in features_data.items():
        if not isinstance(feat_val, dict):
            continue

        title = clean_doc_text(feat_val.get("Content", feat_id))
        summary = clean_doc_text(feat_val.get("Description", f"Windows Optional Feature: {title}"))
        category = feat_val.get("category", "Windows Features")

        entries.append({
            "id": feat_id,
            "title": title,
            "category": category,
            "source": "config/feature.json",
            "summary": summary,
            "technical_details": f"Controls Windows Optional Feature packages for {title}.",
            "whs_parameter": "",
            "safety_level": "Safe",
            "search_keywords": generate_search_tags(title + " " + summary)
        })

    return entries

def process_presets_json(file_path: str) -> list:
    """Extracts system preset configurations (Standard, Minimal, Advanced)."""
    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
        raw_text = f.read()

    preset_data = robust_json_loads(raw_text)
    entries = []

    for preset_name, preset_val in preset_data.items():
        if not isinstance(preset_val, dict):
            continue

        desc = clean_doc_text(preset_val.get("Description", f"{preset_name} optimization preset."))
        tweak_list = preset_val.get("Tweaks", [])
        tech_summary = f"Applies {len(tweak_list)} curated system tweaks: {', '.join(tweak_list[:10])}..."

        entries.append({
            "id": f"PRESET_{preset_name.upper()}",
            "title": f"{preset_name} Optimization Preset",
            "category": "Presets",
            "source": "config/preset.json",
            "summary": desc,
            "technical_details": tech_summary,
            "whs_parameter": "-RunDefaults" if preset_name.lower() == "standard" else "",
            "safety_level": "Recommended" if preset_name.lower() in ["standard", "minimal"] else "Caution",
            "search_keywords": generate_search_tags(preset_name + " preset " + desc)
        })

    return entries

def process_applications_json(file_path: str) -> list:
    """Extracts installable and removable applications catalog."""
    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
        raw_text = f.read()

    app_data = robust_json_loads(raw_text)
    entries = []

    for app_id, app_val in app_data.items():
        if not isinstance(app_val, dict):
            continue

        name = clean_doc_text(app_val.get("Content", app_id))
        desc = clean_doc_text(app_val.get("Description", f"Software package {name}"))
        cat = app_val.get("category", "Applications")
        winget_id = app_val.get("winget", "")

        entries.append({
            "id": f"APP_{app_id}",
            "title": name,
            "category": f"Apps - {cat}",
            "source": "config/applications.json",
            "summary": desc if desc else f"Manage {name} installation and packages.",
            "technical_details": f"WinGet Package ID: {winget_id}" if winget_id else "Managed via package manager.",
            "whs_parameter": "-RemoveApps",
            "safety_level": "Safe",
            "search_keywords": generate_search_tags(name + " " + desc + " " + cat)
        })

    return entries

# ----------------------------------------------------------------------
# Main Execution Pipeline
# ----------------------------------------------------------------------

def main():
    print("================================================================")
    print("  Windows Healing System - Knowledge Base Ingestion Pipeline    ")
    print("================================================================")

    work_dir = tempfile.mkdtemp(prefix="whs_ingest_")
    try:
        repo_root = download_and_extract_repo(work_dir)
        print(f"[*] Parsing files from repository root: {repo_root}")

        kb_items = []
        counts = {"tweaks": 0, "features": 0, "presets": 0, "apps": 0, "docs": 0}

        # 1. Parse config/tweaks.json
        tweaks_file = os.path.join(repo_root, "config", "tweaks.json")
        if os.path.exists(tweaks_file):
            print("[*] Processing config/tweaks.json ...")
            try:
                tweaks = process_tweaks_json(tweaks_file)
                counts["tweaks"] = len(tweaks)
                kb_items.extend(tweaks)
                print(f"    -> Extracted {len(tweaks)} tweaks.")
            except Exception as e:
                print(f"[!] Warning processing tweaks.json: {e}")

        # 2. Parse config/feature.json
        features_file = os.path.join(repo_root, "config", "feature.json")
        if os.path.exists(features_file):
            print("[*] Processing config/feature.json ...")
            try:
                features = process_features_json(features_file)
                counts["features"] = len(features)
                kb_items.extend(features)
                print(f"    -> Extracted {len(features)} features.")
            except Exception as e:
                print(f"[!] Warning processing feature.json: {e}")

        # 3. Parse config/preset.json
        preset_file = os.path.join(repo_root, "config", "preset.json")
        if os.path.exists(preset_file):
            print("[*] Processing config/preset.json ...")
            try:
                presets = process_presets_json(preset_file)
                counts["presets"] = len(presets)
                kb_items.extend(presets)
                print(f"    -> Extracted {len(presets)} presets.")
            except Exception as e:
                print(f"[!] Warning processing preset.json: {e}")

        # 4. Parse config/applications.json
        apps_file = os.path.join(repo_root, "config", "applications.json")
        if os.path.exists(apps_file):
            print("[*] Processing config/applications.json ...")
            try:
                apps = process_applications_json(apps_file)
                counts["apps"] = len(apps)
                kb_items.extend(apps)
                print(f"    -> Extracted {len(apps)} application profiles.")
            except Exception as e:
                print(f"[!] Warning processing applications.json: {e}")

        # 5. Recursively crawl and chunk all Markdown documentation
        docs_dir = os.path.join(repo_root, "docs")
        if os.path.exists(docs_dir):
            print("[*] Crawling and chunking all Markdown/MDX documentation in docs/ ...")
            doc_count = 0
            for root, _, files in os.walk(docs_dir):
                for file in files:
                    if file.lower().endswith((".md", ".mdx")):
                        full_path = os.path.join(root, file)
                        try:
                            doc_entries = process_markdown_file(full_path, repo_root)
                            kb_items.extend(doc_entries)
                            doc_count += len(doc_entries)
                        except Exception as e:
                            print(f"[!] Warning parsing {file}: {e}")
            counts["docs"] = doc_count
            print(f"    -> Extracted {doc_count} documentation sections.")

        # 6. Ingest local WHS Features if running inside the WHS workspace
        local_features_path = os.path.join(SCRIPT_DIR, "Config", "Features.json")
        if os.path.exists(local_features_path):
            print("[*] Incorporating local Windows Healing System Features.json ...")
            try:
                with open(local_features_path, "r", encoding="utf-8") as f:
                    local_feats = json.load(f)
                local_count = 0
                for feat in local_feats.get("Features", []):
                    f_id = feat.get("FeatureId", "")
                    if not any(item["id"] == f_id for item in kb_items):
                        kb_items.append({
                            "id": f_id,
                            "title": feat.get("DisplayName", f_id),
                            "category": feat.get("Category", "Windows Healing System"),
                            "source": "Config/Features.json",
                            "summary": feat.get("Description", ""),
                            "technical_details": feat.get("RegistryFile", "Direct registry change"),
                            "whs_parameter": f"-{f_id}",
                            "safety_level": "Recommended",
                            "search_keywords": generate_search_tags(f_id + " " + feat.get("Description", ""))
                        })
                        local_count += 1
                print(f"    -> Merged {local_count} unique WHS features.")
            except Exception as e:
                print(f"[!] Warning reading local Features.json: {e}")

        # 7. Deduplicate entries by ID
        unique_kb = {}
        for item in kb_items:
            if item["id"] not in unique_kb:
                unique_kb[item["id"]] = item

        final_dataset = list(unique_kb.values())

        # Ensure output directory exists and write final JSON
        os.makedirs(OUTPUT_DIR, exist_ok=True)
        print(f"[*] Writing {len(final_dataset)} total entries to {OUTPUT_FILE} ...")
        with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
            json.dump(final_dataset, f, indent=2, ensure_ascii=False)

        print("\n================================================================")
        print(" [✔] INGESTION SUMMARY REPORT")
        print(f"  - System Tweaks:          {counts['tweaks']}")
        print(f"  - Windows Features:       {counts['features']}")
        print(f"  - Presets (Std/Adv):      {counts['presets']}")
        print(f"  - Application Catalog:    {counts['apps']}")
        print(f"  - Documentation Sections: {counts['docs']}")
        print(f"  - TOTAL KNOWLEDGE CHUNKS: {len(final_dataset)}")
        print(f"  - Output Target:          {OUTPUT_FILE}")
        print("================================================================")

    finally:
        shutil.rmtree(work_dir, ignore_errors=True)

if __name__ == "__main__":
    main()