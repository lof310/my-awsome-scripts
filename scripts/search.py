#!/usr/bin/env python3
import sys, json, argparse, requests, numpy as np
from pathlib import Path
from typing import List, Dict, Any, Tuple
from ddgs import DDGS
from markdownify import markdownify as md

try:
    from sentence_transformers import SentenceTransformer
    EMBEDDINGS_AVAILABLE = True
except ImportError:
    EMBEDDINGS_AVAILABLE = False

CACHE_DIR = Path.home() / ".cache" / "search_script"
MAX_CONTENT = 2000


def search(query: str, max_results: int = 10) -> List[Dict[str, Any]]:
    if not query.strip():
        raise ValueError("Query cannot be empty")
    max_results = max(1, min(max_results, 100))
    results = list(DDGS().text(query.strip(), max_results=max_results))
    if not results:
        raise ValueError("No results found")
    return results


def html2md(url: str, timeout: int = 10) -> str:
    if not url.startswith(("http://", "https://")):
        raise ValueError(f"Invalid URL: {url}")
    r = requests.get(url, headers={"User-Agent": "Mozilla/5.0"}, timeout=timeout)
    r.raise_for_status()
    return md(r.text)[:MAX_CONTENT]


def fmt_results(results: List[Dict[str, Any]], fmt: str = "text") -> str:
    if not results:
        return "No results."
    if fmt == "json":
        return json.dumps(results, indent=2, ensure_ascii=False)
    elif fmt == "table":
        return "\n".join([f"{i+1}. {r.get('title','')[:60]} | {r.get('href','')[:50]} | {r.get('body','')[:80]}..." 
                         for i, r in enumerate(results)])
    return "\n\n".join([f"{r.get('title','')}\n{r.get('href','')}\n{r.get('body','')}" for r in results])


def load_embeddings():
    if not EMBEDDINGS_AVAILABLE:
        raise ImportError("Install: pip install sentence-transformers")
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    return SentenceTransformer("all-MiniLM-L6-v2", cache_folder=str(CACHE_DIR))


def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    na, nb = np.linalg.norm(a), np.linalg.norm(b)
    return float(np.dot(a, b) / (na * nb)) if na and nb else 0.0


def mean_similarity(text: str, keywords: List[str], model) -> float:
    if not text.strip() or not keywords:
        return 0.0
    try:
        text_emb = model.encode(text.strip(), convert_to_numpy=True, truncate=True)
        kw_embs = model.encode([k.strip() for k in keywords if k.strip()], 
                               convert_to_numpy=True, truncate=True)
        if not len(kw_embs):
            return 0.0
        return float(np.mean([cosine_similarity(text_emb, k) for k in kw_embs]))
    except:
        return 0.0


def filter_by_similarity(results: List[Dict], keywords: List[str], topk: int, 
                         model, source: str = "description", timeout: int = 10,
                         verbose: bool = False) -> List[Dict]:
    if not results or not keywords:
        return results[:topk] if topk < len(results) else results
    
    use_content = source in ["content", "both"]
    content_only = source == "content"
    scored = []
    
    for i, r in enumerate(results):
        if verbose:
            print(f"[{i+1}/{len(results)}]", file=sys.stderr)
        
        if use_content:
            try:
                content = html2md(r.get("href", ""), timeout=timeout)
                text = content if content_only else f"{r.get('body', '')} {content}"
            except:
                text = r.get("body", "")
        else:
            text = r.get("body", "")
        
        score = mean_similarity(text, keywords, model)
        r["_similarity"] = score
        scored.append((r, score))
    
    scored.sort(key=lambda x: x[1], reverse=True)
    return [r for r, _ in scored[:topk]]


def main() -> int:
    p = argparse.ArgumentParser(description="Web search with semantic filtering")
    p.add_argument("query", nargs="?", help="Search query or URL")
    p.add_argument("--search", "-s", action="store_true", help="Perform web search")
    p.add_argument("--html2md", "-m", action="store_true", help="Convert HTML to Markdown")
    p.add_argument("--max_results", "-n", type=int, default=10, help="Max results (default: 10)")
    p.add_argument("--format", "-f", choices=["text", "json", "table"], default="text")
    p.add_argument("--filter", "-F", help="Filter by keyword (exact match)")
    p.add_argument("--filter-by-similarity", "-S", nargs="+", metavar="ARG",
                   help="Semantic filter: keyword1 [keyword2...] topk")
    p.add_argument("--similarity-source", choices=["description", "content", "both"],
                   default="description")
    p.add_argument("--sort", "-O", choices=["relevance", "title", "similarity"],
                   default="relevance")
    p.add_argument("--timeout", type=int, default=10)
    p.add_argument("--output", "-o", help="Output to file")
    p.add_argument("--verbose", "-v", action="store_true")
    args = p.parse_args()

    if not args.query:
        p.print_help()
        return 1

    try:
        is_search = args.search or not args.html2md
        
        if is_search:
            results = search(args.query, args.max_results)
            
            if args.filter:
                term = args.filter.lower()
                results = [r for r in results if term in r.get("title","").lower() 
                          or term in r.get("body","").lower()]
            
            if args.filter_by_similarity:
                if len(args.filter_by_similarity) < 2:
                    raise ValueError("-S requires: keyword(s) + topk")
                *keywords, topk_str = args.filter_by_similarity
                topk = int(topk_str)
                topk = max(1, min(topk, len(results)))
                
                if args.verbose:
                    print("Loading embeddings...", file=sys.stderr)
                model = load_embeddings()
                
                if args.verbose:
                    print(f"Filtering top {topk}...", file=sys.stderr)
                results = filter_by_similarity(results, keywords, topk, model,
                                              args.similarity_source, args.timeout,
                                              args.verbose)
                args.sort = "similarity"
            
            if args.sort == "title":
                results = sorted(results, key=lambda x: x.get("title", ""))
            
            out = fmt_results(results, args.format)
            
        elif args.html2md:
            out = html2md(args.query, args.timeout)
        else:
            p.print_help()
            return 1
        
        if args.output:
            Path(args.output).parent.mkdir(parents=True, exist_ok=True)
            with open(args.output, "w", encoding="utf-8") as f:
                f.write(out)
            if args.verbose:
                print(f"Written: {args.output}", file=sys.stderr)
        else:
            print(out)
        
        return 0
        
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 2
    except ImportError as e:
        print(f"Missing dependency: {e}", file=sys.stderr)
        return 3
    except KeyboardInterrupt:
        print("\nInterrupted", file=sys.stderr)
        return 130
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        if args.verbose:
            import traceback
            traceback.print_exc()
        return 1


if __name__ == "__main__":
    sys.exit(main())
