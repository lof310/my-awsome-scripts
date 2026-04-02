#!/usr/bin/env python3
"""Web Search Tool - Search the web with semantic filtering and content extraction."""

# =============================================================================
# Imports & Constants
# =============================================================================
import sys
import json
import argparse
import requests
import numpy as np
from pathlib import Path
from typing import List, Dict, Any, Optional
from ddgs import DDGS
from markdownify import markdownify as md

try:
    from sentence_transformers import SentenceTransformer
    EMBEDDINGS_AVAILABLE = True
except ImportError:
    EMBEDDINGS_AVAILABLE = False

SCRIPT_NAME = "search"
VERSION = "1.1.0"
CACHE_DIR = Path.home() / ".cache" / "search_script"
MAX_CONTENT = 2000
DEFAULT_TIMEOUT = 10
DEFAULT_MAX_RESULTS = 10

# Terminal colors
C = {'R': '\033[0;31m', 'G': '\033[0;32m', 'Y': '\033[1;33m', 'B': '\033[0;34m',
     'C': '\033[0;36m', 'BD': '\033[1m', 'NC': '\033[0m'}


# =============================================================================
# Logging Helpers
# =============================================================================
def log_error(msg: str) -> None:
    """Print error message to stderr."""
    print(f"{C['R']}[ERROR]{C['NC']} {msg}", file=sys.stderr)


def log_warn(msg: str) -> None:
    """Print warning message to stderr."""
    print(f"{C['Y']}[WARNING]{C['NC']} {msg}", file=sys.stderr)


def log_info(msg: str) -> None:
    """Print info message to stdout."""
    print(f"{C['G']}[INFO]{C['NC']} {msg}")


def log_debug(msg: str, verbose: bool = False) -> None:
    """Print debug message if verbose mode is enabled."""
    if verbose:
        print(f"{C['B']}[DEBUG]{C['NC']} {msg}", file=sys.stderr)


# =============================================================================
# Search Functions
# =============================================================================
def search(query: str, max_results: int = DEFAULT_MAX_RESULTS) -> List[Dict[str, Any]]:
    """Perform web search using DuckDuckGo.
    
    Args:
        query: Search query string
        max_results: Maximum number of results (1-100)
    
    Returns:
        List of search result dictionaries
    
    Raises:
        ValueError: If query is empty or no results found
    """
    if not query.strip():
        raise ValueError("Query cannot be empty")
    
    max_results = max(1, min(max_results, 100))
    results = list(DDGS().text(query.strip(), max_results=max_results))
    
    if not results:
        raise ValueError("No results found")
    
    return results


def html2md(url: str, timeout: int = DEFAULT_TIMEOUT) -> str:
    """Convert HTML webpage to Markdown.
    
    Args:
        url: URL of the webpage to convert
        timeout: Request timeout in seconds
    
    Returns:
        Markdown content (truncated to MAX_CONTENT)
    
    Raises:
        ValueError: If URL is invalid
        requests.RequestException: If request fails
    """
    if not url.startswith(("http://", "https://")):
        raise ValueError(f"Invalid URL: {url}")
    
    r = requests.get(url, headers={"User-Agent": "Mozilla/5.0"}, timeout=timeout)
    r.raise_for_status()
    return md(r.text)[:MAX_CONTENT]


def fmt_results(results: List[Dict[str, Any]], fmt: str = "text") -> str:
    """Format search results for output.
    
    Args:
        results: List of search result dictionaries
        fmt: Output format ('text', 'json', or 'table')
    
    Returns:
        Formatted string representation of results
    """
    if not results:
        return "No results."
    
    if fmt == "json":
        return json.dumps(results, indent=2, ensure_ascii=False)
    
    elif fmt == "table":
        lines = []
        for i, r in enumerate(results):
            title = r.get('title', '')[:60]
            href = r.get('href', '')[:50]
            body = r.get('body', '')[:80]
            lines.append(f"{i+1}. {title} | {href} | {body}...")
        return "\n".join(lines)
    
    # Default text format
    return "\n\n".join([
        f"{r.get('title', '')}\n{r.get('href', '')}\n{r.get('body', '')}" 
        for r in results
    ])


def load_embeddings():
    """Load sentence transformer model for semantic similarity.
    
    Returns:
        SentenceTransformer model instance
    
    Raises:
        ImportError: If sentence-transformers is not installed
    """
    if not EMBEDDINGS_AVAILABLE:
        raise ImportError("Install: pip install sentence-transformers")
    
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    return SentenceTransformer("all-MiniLM-L6-v2", cache_folder=str(CACHE_DIR))


def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    """Calculate cosine similarity between two vectors.
    
    Args:
        a: First vector
        b: Second vector
    
    Returns:
        Cosine similarity score (0.0 to 1.0)
    """
    na, nb = np.linalg.norm(a), np.linalg.norm(b)
    return float(np.dot(a, b) / (na * nb)) if na and nb else 0.0


def mean_similarity(text: str, keywords: List[str], model) -> float:
    """Calculate mean semantic similarity between text and keywords.
    
    Args:
        text: Text to compare
        keywords: List of keywords to compare against
        model: Sentence transformer model
    
    Returns:
        Mean similarity score (0.0 to 1.0)
    """
    if not text.strip() or not keywords:
        return 0.0
    
    try:
        text_emb = model.encode(text.strip(), convert_to_numpy=True, truncate=True)
        kw_embs = model.encode(
            [k.strip() for k in keywords if k.strip()], 
            convert_to_numpy=True, 
            truncate=True
        )
        
        if not len(kw_embs):
            return 0.0
        
        return float(np.mean([cosine_similarity(text_emb, k) for k in kw_embs]))
    except Exception:
        return 0.0


def filter_by_similarity(
    results: List[Dict], 
    keywords: List[str], 
    topk: int,
    model, 
    source: str = "description", 
    timeout: int = DEFAULT_TIMEOUT,
    verbose: bool = False
) -> List[Dict]:
    """Filter search results by semantic similarity to keywords.
    
    Args:
        results: List of search result dictionaries
        keywords: Keywords to match against
        topk: Number of top results to return
        model: Sentence transformer model
        source: Source for similarity ('description', 'content', or 'both')
        timeout: Timeout for fetching content
        verbose: Print progress messages
    
    Returns:
        Filtered and sorted list of results
    """
    if not results or not keywords:
        return results[:topk] if topk < len(results) else results
    
    use_content = source in ["content", "both"]
    content_only = source == "content"
    scored = []
    
    for i, r in enumerate(results):
        if verbose:
            log_debug(f"[{i+1}/{len(results)}]", verbose=True)
        
        if use_content:
            try:
                content = html2md(r.get("href", ""), timeout=timeout)
                text = content if content_only else f"{r.get('body', '')} {content}"
            except Exception:
                text = r.get("body", "")
        else:
            text = r.get("body", "")
        
        score = mean_similarity(text, keywords, model)
        r["_similarity"] = score
        scored.append((r, score))
    
    scored.sort(key=lambda x: x[1], reverse=True)
    return [r for r, _ in scored[:topk]]


# =============================================================================
# Usage / Help
# =============================================================================
def print_usage():
    """Print usage information."""
    print(f"""{C['BD']}Usage:{C['NC']} {SCRIPT_NAME} [OPTIONS] QUERY

{C['BD']}Web Search Tool v{VERSION}{C['NC']} - Search the web with semantic filtering

{C['BD']}Arguments:{C['NC']}
  QUERY                 Search query (required for search/html2md)

{C['BD']}Options:{C['NC']}
  --search, -s          Perform web search (default if no other mode specified)
  --html2md, -m         Convert HTML page to Markdown
  --max-results, -n N   Maximum results (default: {DEFAULT_MAX_RESULTS}, max: 100)
  --format, -f FORMAT   Output format: text, json, table (default: text)
  --filter, -F TERM     Filter results by keyword (exact match)
  --filter-by-similarity, -S KW1 [KW2...] TOPK
                        Semantic filter by keywords, return top K
  --similarity-source   Source for similarity: description, content, both
  --sort, -O TYPE       Sort by: relevance, title, similarity
  --timeout, -t SECS    Request timeout (default: {DEFAULT_TIMEOUT}s)
  --output, -o FILE     Write output to file
  --verbose, -v         Enable verbose/debug output
  --version             Show version
  --help, -h            Show this help message

{C['BD']}Examples:{C['NC']}
  {SCRIPT_NAME} "python tutorials" -n 20 -f table
  {SCRIPT_NAME} "machine learning" -S "tutorial beginner" 5
  {SCRIPT_NAME} "https://example.com" -m -o page.md
  {SCRIPT_NAME} "AI news" -F "2024" --sort title
""")


# =============================================================================
# Main
# =============================================================================
def main() -> int:
    """Main entry point."""
    p = argparse.ArgumentParser(
        description=f"{SCRIPT_NAME} v{VERSION} - Web search with semantic filtering",
        add_help=False
    )
    p.add_argument("query", nargs="?", help="Search query or URL")
    p.add_argument("--search", "-s", action="store_true", help="Perform web search")
    p.add_argument("--html2md", "-m", action="store_true", help="Convert HTML to Markdown")
    p.add_argument("--max-results", "-n", type=int, default=DEFAULT_MAX_RESULTS, 
                   help=f"Max results (default: {DEFAULT_MAX_RESULTS})")
    p.add_argument("--format", "-f", choices=["text", "json", "table"], default="text")
    p.add_argument("--filter", "-F", help="Filter by keyword (exact match)")
    p.add_argument("--filter-by-similarity", "-S", nargs="+", metavar="ARG",
                   help="Semantic filter: keyword1 [keyword2...] topk")
    p.add_argument("--similarity-source", choices=["description", "content", "both"],
                   default="description")
    p.add_argument("--sort", "-O", choices=["relevance", "title", "similarity"],
                   default="relevance")
    p.add_argument("--timeout", "-t", type=int, default=DEFAULT_TIMEOUT)
    p.add_argument("--output", "-o", help="Output to file")
    p.add_argument("--verbose", "-v", action="store_true")
    p.add_argument("--version", action="store_true")
    p.add_argument("--help", "-h", action="store_true")
    
    args = p.parse_args()

    if args.version:
        print(f"{SCRIPT_NAME} {VERSION}")
        return 0

    if args.help or not args.query:
        print_usage()
        return 0

    try:
        is_search = args.search or not args.html2md
        
        if is_search:
            if args.verbose:
                log_info(f"Searching for: {args.query}")
            
            results = search(args.query, args.max_results)
            
            if args.filter:
                term = args.filter.lower()
                results = [
                    r for r in results 
                    if term in r.get("title", "").lower() or term in r.get("body", "").lower()
                ]
                if args.verbose:
                    log_info(f"Filtered to {len(results)} results")
            
            if args.filter_by_similarity:
                if len(args.filter_by_similarity) < 2:
                    raise ValueError("-S requires: keyword(s) + topk")
                
                *keywords, topk_str = args.filter_by_similarity
                topk = int(topk_str)
                topk = max(1, min(topk, len(results)))
                
                if args.verbose:
                    log_info("Loading embeddings model...")
                model = load_embeddings()
                
                if args.verbose:
                    log_info(f"Filtering top {topk} by semantic similarity...")
                results = filter_by_similarity(
                    results, keywords, topk, model,
                    args.similarity_source, args.timeout, args.verbose
                )
                args.sort = "similarity"
            
            if args.sort == "title":
                results = sorted(results, key=lambda x: x.get("title", ""))
            
            out = fmt_results(results, args.format)
            
        elif args.html2md:
            if args.verbose:
                log_info(f"Converting URL to Markdown: {args.query}")
            out = html2md(args.query, args.timeout)
        else:
            print_usage()
            return 1
        
        if args.output:
            Path(args.output).parent.mkdir(parents=True, exist_ok=True)
            with open(args.output, "w", encoding="utf-8") as f:
                f.write(out)
            if args.verbose:
                log_info(f"Written: {args.output}")
        else:
            print(out)
        
        return 0
        
    except ValueError as e:
        log_error(str(e))
        return 2
    except ImportError as e:
        log_error(f"Missing dependency: {e}")
        return 3
    except KeyboardInterrupt:
        print("\nInterrupted", file=sys.stderr)
        return 130
    except Exception as e:
        log_error(str(e))
        if args.verbose:
            import traceback
            traceback.print_exc(file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
