#!/usr/bin/env python3
"""
Windows Healing System (WHS) - Robust Embedding Cache Generator
Auto-detects model tags, probes Ollama endpoints, prints detailed error bodies,
and compiles Config/KnowledgeBase.embeddings.json.
"""

import os
import sys
import json
import time
import urllib.request
import urllib.error
import subprocess

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
KB_PATH = os.path.join(SCRIPT_DIR, "Config", "KnowledgeBase.json")
CACHE_PATH = os.path.join(SCRIPT_DIR, "Config", "KnowledgeBase.embeddings.json")

OLLAMA_ENDPOINT = "http://localhost:11434"

def get_installed_models():
    """Fetches the exact list of models installed in Ollama."""
    try:
        req = urllib.request.Request(f"{OLLAMA_ENDPOINT}/api/tags")
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return [m.get("name", "") for m in data.get("models", [])]
    except Exception as e:
        print(f"\n[!] ERROR: Cannot reach Ollama at {OLLAMA_ENDPOINT} ({e})")
        print("    Please ensure Ollama is running (`ollama serve` or start Ollama app).\n")
        sys.exit(1)

def extract_error_detail(http_error: urllib.error.HTTPError) -> str:
    """Extracts the underlying JSON or text error body returned by Ollama."""
    try:
        body = http_error.read().decode("utf-8", errors="ignore")
        try:
            parsed = json.loads(body)
            return parsed.get("error", body)
        except Exception:
            return body.strip()
    except Exception:
        return str(http_error)

def find_working_configuration(installed_models):
    """
    Runs pre-flight tests across model name variants and API endpoints
    to find the exact configuration that succeeds on your system.
    """
    print("[*] Detecting installed Ollama models:")
    for m in installed_models:
        print(f"    - {m}")

    # Identify candidate model names
    matching = [m for m in installed_models if "nomic" in m or "embed" in m]
    if not matching:
        print("\n[!] No embedding model found in Ollama.")
        print("[*] Attempting to pull 'nomic-embed-text' automatically...")
        try:
            subprocess.run(["ollama", "pull", "nomic-embed-text"], check=True)
            installed_models = get_installed_models()
            matching = [m for m in installed_models if "nomic" in m or "embed" in m]
        except Exception as e:
            print(f"[!] Failed to pull model automatically: {e}")
            print("    Please run in your terminal:  ollama pull nomic-embed-text\n")
            sys.exit(1)

    # Test candidate permutations
    model_candidates = []
    for m in matching:
        model_candidates.append(m)
        if ":" in m:
            model_candidates.append(m.split(":")[0])
    model_candidates.append("nomic-embed-text")
    # Deduplicate while preserving order
    seen = set()
    model_candidates = [x for x in model_candidates if not (x in seen or seen.add(x))]

    test_text = "search_document: Windows Healing System test probe"
    print("\n[*] Running pre-flight probe tests against Ollama...")

    for model_name in model_candidates:
        # Permutation A: Modern /api/embed (Batch format)
        try:
            url = f"{OLLAMA_ENDPOINT}/api/embed"
            payload = json.dumps({"model": model_name, "input": [test_text]}).encode("utf-8")
            req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                res = json.loads(resp.read().decode("utf-8"))
                if "embeddings" in res and len(res["embeddings"]) > 0:
                    vec = res["embeddings"][0]
                    print(f"[✔] SUCCESS: Endpoint /api/embed with model '{model_name}'")
                    print(f"    -> Vector Dimension: {len(vec)}")
                    return {
                        "endpoint": url,
                        "model": model_name,
                        "mode": "embed_batch",
                        "batch_size": 25
                    }
        except urllib.error.HTTPError as e:
            err_msg = extract_error_detail(e)
            print(f"    [x] Probe /api/embed ('{model_name}'): HTTP {e.code} -> {err_msg}")
        except Exception as e:
            print(f"    [x] Probe /api/embed ('{model_name}'): {e}")

        # Permutation B: Legacy /api/embeddings (Single format)
        try:
            url = f"{OLLAMA_ENDPOINT}/api/embeddings"
            payload = json.dumps({"model": model_name, "prompt": test_text}).encode("utf-8")
            req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                res = json.loads(resp.read().decode("utf-8"))
                if "embedding" in res and len(res["embedding"]) > 0:
                    vec = res["embedding"]
                    print(f"[✔] SUCCESS: Endpoint /api/embeddings with model '{model_name}'")
                    print(f"    -> Vector Dimension: {len(vec)}")
                    return {
                        "endpoint": url,
                        "model": model_name,
                        "mode": "embeddings_single",
                        "batch_size": 1
                    }
        except urllib.error.HTTPError as e:
            err_msg = extract_error_detail(e)
            print(f"    [x] Probe /api/embeddings ('{model_name}'): HTTP {e.code} -> {err_msg}")
        except Exception as e:
            print(f"    [x] Probe /api/embeddings ('{model_name}'): {e}")

    print("\n[!] All probe tests failed. Check the error messages above for details.")
    sys.exit(1)

def execute_embedding_request(config, texts: list) -> list:
    """Executes embedding requests according to the verified configuration."""
    prefixed = [f"search_document: {t}" for t in texts]

    if config["mode"] == "embed_batch":
        payload = json.dumps({"model": config["model"], "input": prefixed}).encode("utf-8")
        req = urllib.request.Request(config["endpoint"], data=payload, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return data["embeddings"]

    elif config["mode"] == "embeddings_single":
        results = []
        for t in prefixed:
            payload = json.dumps({"model": config["model"], "prompt": t}).encode("utf-8")
            req = urllib.request.Request(config["endpoint"], data=payload, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                results.append(data["embedding"])
        return results

def main():
    print("================================================================")
    print("  Windows Healing System - Knowledge Base Embedding Generator   ")
    print("================================================================")

    if not os.path.exists(KB_PATH):
        print(f"[!] ERROR: {KB_PATH} not found. Run build_knowledge_base.py first.")
        sys.exit(1)

    models = get_installed_models()
    config = find_working_configuration(models)

    with open(KB_PATH, "r", encoding="utf-8") as f:
        kb_items = json.load(f)

    total_items = len(kb_items)
    print(f"\n[*] Loaded {total_items} chunks from KnowledgeBase.json.")

    # Load existing cache if resuming
    embeddings_cache = {}
    if os.path.exists(CACHE_PATH):
        try:
            with open(CACHE_PATH, "r", encoding="utf-8") as f:
                existing_data = json.load(f)
                embeddings_cache = existing_data.get("vectors", {})
            print(f"[*] Found existing cache with {len(embeddings_cache)} items. Resuming...")
        except Exception:
            embeddings_cache = {}

    pending_items = [item for item in kb_items if item["id"] not in embeddings_cache]

    if not pending_items:
        print("[✔] All items are already embedded in cache!")
    else:
        batch_size = config["batch_size"]
        print(f"[*] Generating embeddings for {len(pending_items)} items (Batch size: {batch_size})...")
        start_time = time.time()

        for i in range(0, len(pending_items), batch_size):
            batch = pending_items[i:i + batch_size]
            texts = [
                f"{item['title']}. {item['summary']} {item.get('technical_details', '')}".strip()[:3500]
                for item in batch
            ]

            try:
                vectors = execute_embedding_request(config, texts)
                for item, vec in zip(batch, vectors):
                    embeddings_cache[item["id"]] = [round(v, 5) for v in vec]

                done = len(embeddings_cache)
                pct = (done / total_items) * 100
                print(f"  [{done:3d}/{total_items}] ({pct:5.1f}%) Embedded -> {batch[0]['title'][:40]}...")

                # Periodically flush to disk
                if len(embeddings_cache) % 50 == 0:
                    with open(CACHE_PATH, "w", encoding="utf-8") as f:
                        json.dump({
                            "model": config["model"],
                            "dimensions": len(vectors[0]),
                            "total_items": len(embeddings_cache),
                            "updated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
                            "vectors": embeddings_cache
                        }, f, separators=(',', ':'))

            except Exception as err:
                print(f"[!] Error processing batch: {err}")
                # Fallback to single item execution for this batch
                for item in batch:
                    single_text = f"{item['title']}. {item['summary']} {item.get('technical_details', '')}".strip()
                    try:
                        single_vec = execute_embedding_request(config, [single_text])[0]
                        embeddings_cache[item["id"]] = [round(v, 5) for v in single_vec]
                    except Exception as e_single:
                        print(f"    Failed on '{item['id']}': {e_single}")

    # Final Save
    print(f"\n[*] Writing final embeddings cache to: {CACHE_PATH} ...")
    os.makedirs(os.path.dirname(CACHE_PATH), exist_ok=True)
    with open(CACHE_PATH, "w", encoding="utf-8") as f:
        json.dump({
            "model": config["model"],
            "dimensions": 768,
            "total_items": len(embeddings_cache),
            "updated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
            "vectors": embeddings_cache
        }, f, separators=(',', ':'))

    file_size_mb = os.path.getsize(CACHE_PATH) / (1024 * 1024)
    print("\n================================================================")
    print(" [✔] EMBEDDING GENERATION COMPLETED SUCCESSFULLY")
    print(f"  - Model Used:            {config['model']}")
    print(f"  - Total Items Stored:    {len(embeddings_cache)} / {total_items}")
    print(f"  - Output Target:         {CACHE_PATH}")
    print(f"  - File Size:             {file_size_mb:.2f} MB")
    print("================================================================")
    print("[*] You can now commit Config/KnowledgeBase.embeddings.json to Git.")

if __name__ == "__main__":
    main()