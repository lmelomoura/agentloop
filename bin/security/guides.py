# bin/security/guides.py
"""Which of the vendored hunting guides an analysis should read.

Eleven guides (skills/security-analysis/references/, vendored from
cloudflare/security-audit-skill -- see UPSTREAM.md there) add up to ~105 KB,
about 30k tokens: read whole on every run they would eat a `quick` profile's
budget before the agent opened a file of the repository. So `prepare`
chooses, from signals it has in hand already -- the dependency inventory's
names and the paths of the tree, under the same `ignore_paths` and the same
`SKIP_DIRS` every other phase obeys -- and the profile puts a ceiling on how
many.

DETERMINISTIC AND RECORDED. The agent could pick its own guides after a
look at the tree; then the cost per run would be the model's mood and nothing
would say what it read. Here the list is data, it is stored on the analysis
(`ledger.set_guides`) and each unit's proof records what its run actually
opened off the run's stream (`evidence["guides"]`, security/evidence.py).

NEVER A FAILURE OF `prepare`. Guides are advice. `recommend` catches
everything, answers ATTACK-CLASSES alone plus a note the coverage paragraph
carries; the deterministic phases do not fall over for want of a reading
list.
"""

from fnmatch import fnmatchcase
from pathlib import Path

from . import ignores, secrets

ALWAYS = "ATTACK-CLASSES"

# name -> signals. `deps` are lowercase package names, a trailing `*` a prefix;
# `paths` are fnmatch patterns over the repository-relative path, and `*`
# crosses `/` in fnmatch, so `.claude/*` reaches `.claude/agents/x.md` and
# `*migrations/*` reaches `app/migrations/0001.py`. `follows` names guides
# whose match implies this one. `inventory` matches any non-empty inventory.
# THE ORDER IS THE TIE-BREAK (see `select`), so it is a decision, not a list.
GUIDES = (
    (ALWAYS, {"always": True}),
    ("WEB-PROTOCOL-AND-AUTH", {"deps": (
        "express", "koa", "fastify", "hapi", "@hapi/hapi", "@nestjs/core", "next", "nuxt",
        "flask", "django", "fastapi", "starlette", "tornado", "rails", "sinatra",
        "laravel/framework", "symfony/symfony", "slim/slim", "spring-boot",
        "github.com/gin-gonic/gin", "github.com/labstack/echo*", "github.com/go-chi/chi*",
        "github.com/gofiber/fiber*", "actix-web", "axum", "rocket")}),
    ("CLIENT-SIDE", {"paths": ("*.html", "*.jsx", "*.tsx", "*.vue", "*.svelte"),
                     "deps": ("react", "vue", "svelte", "@angular/core", "jquery")}),
    ("CLOUD-AND-DEPLOYMENT", {"paths": (
        "Dockerfile*", "*/Dockerfile*", "*.Dockerfile", "docker-compose*.yml",
        "docker-compose*.yaml", "*.tf", "Chart.yaml", "*/Chart.yaml", "k8s/*",
        "kubernetes/*", "manifests/*", "*cloudformation*", ".github/workflows/*",
        "serverless.yml", "wrangler.toml", "fly.toml", "Procfile")}),
    ("AI-AND-LLM", {"deps": (
        "openai", "anthropic", "@anthropic-ai/sdk", "langchain*", "@langchain/*",
        "llamaindex", "llama-index*", "mcp", "@modelcontextprotocol/*", "ai", "transformers"),
        "paths": ("CLAUDE.md", "AGENTS.md", ".claude/*", "SKILL.md", "*/SKILL.md",
                  ".mcp.json", "mcp.json", ".cursorrules")}),
    ("MEMORY-SAFETY-AND-BINARY", {"paths": (
        "*.c", "*.cc", "*.cpp", "*.h", "*.hpp", "*.rs", "*.zig", "Cargo.lock")}),
    ("PROTOCOLS-RPC-AND-MESSAGING", {"paths": ("*.proto",), "deps": (
        "grpc*", "@grpc/*", "grpcio", "amqplib", "pika", "kafkajs", "kafka-python",
        "confluent-kafka", "paho-mqtt", "mqtt", "ws", "socket.io", "websockets", "nats")}),
    ("DATA-ISOLATION-AND-LIFECYCLE", {"deps": (
        "sqlalchemy", "prisma", "@prisma/client", "sequelize", "typeorm", "knex", "drizzle-orm",
        "gorm.io/gorm", "diesel", "mongoose", "pg", "mysql2", "psycopg2*", "psycopg", "asyncpg",
        "pymongo"), "paths": ("*migrations/*", "*db/migrate/*", "*alembic/*")}),
    ("DESKTOP-MOBILE-AND-LOCAL-IPC", {"deps": ("electron", "@tauri-apps/api", "react-native", "expo"),
                                      "paths": ("*.swift", "*.kt", "*.m", "android/*", "ios/*",
                                                "*.xcodeproj/*")}),
    # LAST of the matched guides on purpose: its inventory signal fires on
    # nearly every project, and ties break by table order -- placed earlier it
    # would take `quick`'s single slot from the domain guide that actually
    # describes the repository.
    ("SUPPLY-CHAIN-AND-RELEASE", {"inventory": True, "paths": (
        ".github/workflows/*", ".gitlab-ci.yml", "bitbucket-pipelines.yml", "Jenkinsfile",
        ".circleci/*")}),
    ("RESOURCE-EXHAUSTION-AND-AVAILABILITY", {"follows": ("WEB-PROTOCOL-AND-AUTH",
                                                          "PROTOCOLS-RPC-AND-MESSAGING")}),
)
NAMES = tuple(name for name, _ in GUIDES)
PROFILES = ("quick", "standard", "deep")


def signals(root, ignore, components) -> dict:
    """What the tree and the inventory say: lowercase dependency names, and
    every repository-relative path the other phases would read -- the same
    `secrets.skipped` and `ignores.ignored` predicates, so an ignored
    `.github/**` gives no signal, exactly as it gives no finding."""
    root = Path(root)
    deps = {str(c.get("name", "")).lower() for c in (components or []) if c.get("name")}
    paths = []
    for p in sorted(root.rglob("*")):
        if not p.is_file() or p.is_symlink():
            continue
        rel = str(p.relative_to(root))
        if secrets.skipped(rel) or ignores.ignored(rel, ignore):
            continue
        paths.append(rel)
    return {"deps": deps, "paths": paths, "inventory": bool(deps)}


def _dep_hit(pattern, deps) -> bool:
    if pattern.endswith("*"):
        prefix = pattern[:-1]
        return any(d.startswith(prefix) for d in deps)
    return pattern in deps


def _hits(spec, sig, matched) -> int:
    n = 0
    n += sum(1 for pat in spec.get("deps", ()) if _dep_hit(pat, sig["deps"]))
    n += sum(1 for pat in spec.get("paths", ())
             if any(fnmatchcase(rel, pat) for rel in sig["paths"]))
    if spec.get("inventory") and sig.get("inventory"):
        n += 1
    n += sum(1 for other in spec.get("follows", ()) if other in matched)
    return n


def select(sig, profile) -> list:
    """ATTACK-CLASSES first, then the matched guides by number of signals
    (ties by table order), cut by the profile: `quick` keeps one, `standard`
    all that matched, `deep` reads all eleven whether they matched or not."""
    if profile == "deep":
        return list(NAMES)
    matched = {}
    for name, spec in GUIDES:
        if spec.get("always"):
            continue
        n = _hits(spec, sig, matched)
        if n:
            matched[name] = n
    order = {name: i for i, name in enumerate(NAMES)}
    ranked = sorted(matched, key=lambda name: (-matched[name], order[name]))
    if profile == "quick":
        ranked = ranked[:1]
    return [ALWAYS] + ranked


SELECTION_FAILED_NOTE = ("The hunting-guide selection did not run ({reason}); only "
                         "ATTACK-CLASSES was recommended to the agent.")


def recommend(root, ignore, components, profile):
    """(guides, note). Never raises -- see the module docstring."""
    try:
        return select(signals(root, ignore, components), profile), ""
    except Exception as exc:  # noqa: BLE001 -- advice must not fail the phase
        reason = f"{type(exc).__name__}: {exc}"
        return [ALWAYS], SELECTION_FAILED_NOTE.format(reason=reason)
