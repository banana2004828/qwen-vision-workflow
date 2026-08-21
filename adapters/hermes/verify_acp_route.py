"""Headless, read-only Hermes ACP routing evidence.

The verifier deliberately follows the Hermes 0.20.4 implementation instead of
looking for a convenient ``probe_*`` hook.  It imports the real routing,
ACP-adapter, auxiliary-vision, and main-model boundary functions from one
selected Hermes source/venv tree, captures only booleans and fixed route
labels, and emits no prompt, image data/URL, visual description, environment,
headers, or credentials.

This is instrumentation, not a model call.  The final auxiliary relay-to-SDK
callback is replaced with an in-process recorder only after
``agent.auxiliary_client`` has resolved the provider, model, credentials, and
fallback destination, so the real request construction and text fallback are
exercised without contacting a provider.
Any layout, import, or observation failure is an instrumentation miss and can
only result in an ``unverified`` result in the PowerShell adapter.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import contextlib
import importlib
import io
import json
import logging
import mimetypes
import os
import shutil
import sys
import sysconfig
import tempfile
from pathlib import Path
from types import ModuleType, SimpleNamespace
from typing import Any, Dict, Iterable, Optional, Sequence, Tuple


_AUXILIARY_TASK = "vision"

# These are the only Hermes modules this verifier is allowed to load.  In
# particular, there is no guessed probe-function list and no fallback import
# of an unqualified external ``agent`` package.
_TARGET_MODULE_NAMES = {
    "image_routing": "agent.image_routing",
    "acp_server": "acp_adapter.server",
    "run_agent": "run_agent",
    "vision_tools": "tools.vision_tools",
    "config": "hermes_cli.config",
    "acp_schema": "acp.schema",
    "auxiliary_client": "agent.auxiliary_client",
}


def _normal_path(value: Path | str) -> str:
    """Return a case-normalized absolute path for containment checks."""

    return os.path.normcase(os.path.abspath(os.fspath(value)))


def _is_within(path: Path | str, roots: Iterable[Path | str]) -> bool:
    candidate = _normal_path(path)
    for root in roots:
        normalized_root = _normal_path(root).rstrip(os.sep)
        if candidate == normalized_root or candidate.startswith(normalized_root + os.sep):
            return True
    return False


def _target_layout(hermes_home: Path) -> Optional[Tuple[Path, list[Path]]]:
    """Find a complete Hermes source tree and its venv roots.

    A directory merely containing a fake ``agent`` package is not a valid
    target.  The source root must contain the real 0.20.4 entry points used by
    this verifier, which also makes an empty Hermes home plus external
    ``PYTHONPATH`` unable to satisfy the probe.
    """

    home = hermes_home.resolve(strict=False)
    source_candidates = (home / "hermes-agent", home)
    for source in source_candidates:
        required = (
            source / "agent" / "image_routing.py",
            source / "acp_adapter" / "server.py",
            source / "run_agent.py",
            source / "tools" / "vision_tools.py",
            source / "hermes_cli" / "config.py",
        )
        if not source.is_dir() or not all(path.is_file() for path in required):
            continue

        roots: list[Path] = [source]
        venv_candidates = (source / "venv", home / "venv")
        for venv in venv_candidates:
            if not venv.is_dir():
                continue
            roots.append(venv)
            for relative in (
                Path("Lib") / "site-packages",
                Path("lib") / "site-packages",
            ):
                site_packages = venv / relative
                if site_packages.is_dir():
                    roots.append(site_packages)
        return source, roots
    return None


def _safe_module_file(module: ModuleType, allowed_roots: Sequence[Path]) -> bool:
    """Require an imported target module to resolve inside source/venv roots."""

    module_file = getattr(module, "__file__", None)
    if not isinstance(module_file, str) or not module_file:
        return False
    try:
        resolved = Path(module_file).resolve(strict=True)
    except (OSError, RuntimeError, ValueError):
        return False
    return _is_within(resolved, allowed_roots)


def _import_target_modules(source_root: Path, allowed_roots: Sequence[Path]) -> Optional[Dict[str, ModuleType]]:
    """Import only fixed Hermes modules after sanitizing import search paths."""

    original_path = list(sys.path)
    standard_paths = {
        str(Path(path).resolve(strict=False))
        for path in sysconfig.get_paths().values()
        if isinstance(path, str) and path
    }
    # Keep the interpreter's standard library while excluding PYTHONPATH,
    # script-directory imports, and user-site packages.  Target venv paths are
    # added explicitly and are still checked by ``_safe_module_file``.
    safe_path = [str(source_root)]
    safe_path.extend(str(root) for root in allowed_roots if root != source_root)
    safe_path.extend(path for path in standard_paths if Path(path).exists())
    try:
        sys.path[:] = list(dict.fromkeys(safe_path))
        modules: Dict[str, ModuleType] = {}
        for key, module_name in _TARGET_MODULE_NAMES.items():
            already_loaded = sys.modules.get(module_name)
            if already_loaded is not None and not _safe_module_file(already_loaded, allowed_roots):
                return None
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                module = already_loaded or importlib.import_module(module_name)
            if not _safe_module_file(module, allowed_roots):
                return None
            modules[key] = module
        return modules
    except Exception:
        return None
    finally:
        sys.path[:] = original_path


def _image_part_has_image(value: Any) -> bool:
    """Recognize the exact OpenAI image-part shape without exposing its URL."""

    if not isinstance(value, list):
        return False
    for part in value:
        if not isinstance(part, dict) or part.get("type") != "image_url":
            continue
        image_url = part.get("image_url")
        if not isinstance(image_url, dict):
            continue
        url = image_url.get("url")
        if isinstance(url, str) and url.startswith("data:image/"):
            return True
    return False


def _visual_text_note(value: Any) -> bool:
    return isinstance(value, str) and "[visual text note]" in value


def _config_target(config_module: ModuleType) -> Optional[dict[str, Any]]:
    """Read only the fixed provider/model fields needed for route evidence."""

    loader = getattr(config_module, "load_config_readonly", None)
    if not callable(loader):
        loader = getattr(config_module, "load_config", None)
    if not callable(loader):
        return None
    try:
        cfg = loader()
    except Exception:
        return None
    if not isinstance(cfg, dict):
        return None
    auxiliary = cfg.get("auxiliary")
    vision = auxiliary.get("vision") if isinstance(auxiliary, dict) else None
    if not isinstance(vision, dict):
        return None
    provider = vision.get("provider")
    model = vision.get("model")
    if not isinstance(provider, str) or not isinstance(model, str):
        return None
    return {
        "config": cfg,
        "provider": provider.strip().lower(),
        "model": model.strip(),
    }


def _valid_native_parts(value: Any) -> bool:
    """Validate the fixed return shape from Hermes build_native_content_parts."""

    if not isinstance(value, tuple) or len(value) != 2:
        return False
    parts, skipped = value
    if not isinstance(parts, list) or not isinstance(skipped, list) or skipped:
        return False
    for part in parts:
        if not isinstance(part, dict) or part.get("type") != "image_url":
            continue
        image_url = part.get("image_url")
        if isinstance(image_url, dict) and isinstance(image_url.get("url"), str):
            return image_url["url"].startswith("data:image/")
    return False


def _valid_image_refs(value: Any) -> bool:
    if not isinstance(value, tuple) or len(value) != 2:
        return False
    local_paths, urls = value
    return isinstance(local_paths, list) and isinstance(urls, list) and urls == ["https://example.invalid/qvw.png"]


def _run_real_main_boundary(
    auxiliary_module: ModuleType,
    vision_module: ModuleType,
    run_agent_module: ModuleType,
    image_path: Path,
    user_content: Any,
) -> Optional[dict[str, Any]]:
    """Run the real aux resolver and AIAgent image-to-text boundary.

    The interception point is Hermes' ``_relay_async_completion``.  By the
    time that function is reached, ``agent.auxiliary_client`` has resolved the
    task provider, model, credentials, client, fallback identity, and request
    body.  The recorder replaces only the callback immediately before the SDK
    transport; it does not replace ``async_call_llm`` or the image fallback
    description method.  A fixed response object then lets the production
    ``_describe_image_for_anthropic_fallback`` method complete normally.
    """

    captured: dict[str, Any] = {}
    old_relay = getattr(auxiliary_module, "_relay_async_completion", None)
    if not callable(old_relay):
        return None
    had_async = hasattr(vision_module, "async_call_llm")
    had_extract = hasattr(vision_module, "extract_content_or_reasoning")
    had_get_hermes_dir = hasattr(vision_module, "get_hermes_dir")
    had_debug = hasattr(vision_module, "_debug")
    old_async = getattr(vision_module, "async_call_llm", None)
    old_extract = getattr(vision_module, "extract_content_or_reasoning", None)
    old_get_hermes_dir = getattr(vision_module, "get_hermes_dir", None)
    old_debug = getattr(vision_module, "_debug", None)
    cache_root = Path(tempfile.mkdtemp(prefix="qvw-hermes-vision-probe-"))

    async def recorder(
        _client: Any,
        request: dict[str, Any],
        *,
        provider: Optional[str] = None,
        api_mode: Optional[str] = None,
        create: Any = None,
    ) -> Any:
        # These values are read from the actual auxiliary resolver call.  Do
        # not use config values here: fallback/provider drift must remain
        # visible to the PowerShell acceptance gate.
        relay_context_var = getattr(auxiliary_module, "_RELAY_AUX_CALL_CONTEXT", None)
        relay_context = relay_context_var.get() if relay_context_var is not None else None
        if isinstance(relay_context, dict):
            captured["task"] = relay_context.get("task")
        captured["provider"] = provider
        captured["model"] = request.get("model") if isinstance(request, dict) else None
        captured["api_mode"] = api_mode
        captured["messages"] = request.get("messages") if isinstance(request, dict) else None
        message = SimpleNamespace(content="[visual text note]", reasoning=None, reasoning_content=None, reasoning_details=None)
        return SimpleNamespace(choices=[SimpleNamespace(message=message)])

    class _NoopDebug:
        def log_call(self, *args: Any, **kwargs: Any) -> None:
            return None

        def save(self, *args: Any, **kwargs: Any) -> None:
            return None

    try:
        # Keep the real auxiliary entry points and only replace the final
        # relay-to-SDK callback.
        auxiliary_module._relay_async_completion = recorder
        vision_module.async_call_llm = getattr(auxiliary_module, "async_call_llm")
        vision_module.extract_content_or_reasoning = getattr(auxiliary_module, "extract_content_or_reasoning")
        vision_module.get_hermes_dir = lambda *_args, **_kwargs: cache_root
        vision_module._debug = _NoopDebug()

        agent_type = getattr(run_agent_module, "AIAgent", None)
        if agent_type is None:
            return None
        agent = object.__new__(agent_type)
        # Force the production non-vision branch without replacing its
        # description method.  The method below must invoke vision_analyze_tool
        # and reach the recorder after provider resolution.
        agent._model_supports_vision = lambda: False
        agent._anthropic_image_fallback_cache = {}
        prepared = agent_type._prepare_messages_for_non_vision_model(
            agent, [{"role": "user", "content": user_content}]
        )
        after_content = prepared[0].get("content") if isinstance(prepared, list) and prepared else None
    except Exception:
        return None
    finally:
        auxiliary_module._relay_async_completion = old_relay
        if had_async:
            vision_module.async_call_llm = old_async
        else:
            delattr(vision_module, "async_call_llm")
        if had_extract:
            vision_module.extract_content_or_reasoning = old_extract
        else:
            delattr(vision_module, "extract_content_or_reasoning")
        if had_get_hermes_dir:
            vision_module.get_hermes_dir = old_get_hermes_dir
        else:
            delattr(vision_module, "get_hermes_dir")
        if had_debug:
            vision_module._debug = old_debug
        else:
            delattr(vision_module, "_debug")
        shutil.rmtree(cache_root, ignore_errors=True)

    messages = captured.get("messages")
    has_image = False
    if isinstance(messages, list) and len(messages) == 1 and isinstance(messages[0], dict):
        content = messages[0].get("content")
        if isinstance(content, list):
            for part in content:
                if not isinstance(part, dict) or part.get("type") != "image_url":
                    continue
                image_url = part.get("image_url")
                if isinstance(image_url, dict) and isinstance(image_url.get("url"), str):
                    has_image = image_url["url"].startswith("data:image/")
                    break
    provider = captured.get("provider")
    model = captured.get("model")
    if not isinstance(provider, str) or not provider.strip() or not isinstance(model, str) or not model.strip():
        return None
    return {
        "provider": provider.strip().lower(),
        "model": model.strip(),
        "task": captured.get("task"),
        "request_has_image": has_image,
        "main_before_has_image": _image_part_has_image(user_content),
        "main_after_has_image": _image_part_has_image(after_content),
        "main_after_has_visual_text_note": _visual_text_note(after_content),
    }


def _probe_real_acp_chain(hermes_home: Path, image_path: Path) -> dict[str, Any]:
    layout = _target_layout(hermes_home)
    if layout is None or not image_path.is_file():
        return {"instrumentation_available": False}
    source_root, allowed_roots = layout
    modules = _import_target_modules(source_root, allowed_roots)
    if modules is None:
        return {"instrumentation_available": False}

    image_routing = modules["image_routing"]
    acp_server = modules["acp_server"]
    run_agent = modules["run_agent"]
    vision_tools = modules["vision_tools"]
    config_module = modules["config"]
    schema = modules["acp_schema"]

    # Fixed Hermes 0.20.4 entry points.  Missing or replaced functions are an
    # instrumentation miss; no arbitrary function result is accepted.
    extract_image_refs = getattr(image_routing, "extract_image_refs", None)
    decide_image_input_mode = getattr(image_routing, "decide_image_input_mode", None)
    build_native_content_parts = getattr(image_routing, "build_native_content_parts", None)
    content_blocks_to_content = getattr(acp_server, "_content_blocks_to_openai_user_content", None)
    prepare_messages = getattr(getattr(run_agent, "AIAgent", None), "_prepare_messages_for_non_vision_model", None)
    image_block_type = getattr(schema, "ImageContentBlock", None)
    text_block_type = getattr(schema, "TextContentBlock", None)
    vision_analyze_tool = getattr(vision_tools, "vision_analyze_tool", None)
    if not all(
        callable(value)
        for value in (
            extract_image_refs,
            decide_image_input_mode,
            build_native_content_parts,
            content_blocks_to_content,
            prepare_messages,
            vision_analyze_tool,
        )
    ) or image_block_type is None or text_block_type is None:
        return {"instrumentation_available": False}

    config_target = _config_target(config_module)
    if config_target is None:
        return {"instrumentation_available": False}
    # The config is read to prove the target schema exists, but the accepted
    # route identity below must come from auxiliary_client's live resolution.
    # A configured Alibaba/Qwen pair that resolves through another provider or
    # fallback therefore remains visible and cannot be accepted.

    try:
        image_refs = extract_image_refs("https://example.invalid/qvw.png")
        native_parts = build_native_content_parts("route probe", [str(image_path)], [])
        # Force the fixed non-vision boundary decision without consulting a
        # remote capability catalog.  The actual before/after boundary below
        # still runs through AIAgent's production method.
        mode = decide_image_input_mode(
            "deepseek", "deepseek-v4-pro", {"agent": {"image_input_mode": "text"}}
        )
        if not _valid_image_refs(image_refs) or not _valid_native_parts(native_parts) or mode != "text":
            return {"instrumentation_available": False}

        mime = mimetypes.guess_type(image_path.name)[0] or "image/png"
        encoded = base64.b64encode(image_path.read_bytes()).decode("ascii")
        image_block = image_block_type(type="image", data=encoded, mime_type=mime)
        text_block = text_block_type(type="text", text="route probe")
        user_content = content_blocks_to_content([text_block, image_block])
        before_has_image = _image_part_has_image(user_content)
        if not before_has_image:
            return {"instrumentation_available": False}

        agent_type = getattr(run_agent, "AIAgent", None)
        if agent_type is None:
            return {"instrumentation_available": False}
    except Exception:
        return {"instrumentation_available": False}

    auxiliary_request = _run_real_main_boundary(
        modules["auxiliary_client"], vision_tools, run_agent, image_path, user_content
    )
    if auxiliary_request is None:
        return {"instrumentation_available": False}

    return {
        "instrumentation_available": True,
        "auxiliary": {
            "task": auxiliary_request["task"],
            "provider": auxiliary_request["provider"],
            "model": auxiliary_request["model"],
            "request_has_image": bool(
                auxiliary_request["task"] == _AUXILIARY_TASK
                and auxiliary_request["request_has_image"]
            ),
        },
        "main": {
            "before_has_image": bool(auxiliary_request["main_before_has_image"]),
            "after_has_image": bool(auxiliary_request["main_after_has_image"]),
            "after_has_visual_text_note": bool(auxiliary_request["main_after_has_visual_text_note"]),
        },
    }


def probe(hermes_home: Path, image_path: Path) -> dict[str, Any]:
    if not hermes_home.is_dir() or not image_path.is_file():
        return {"instrumentation_available": False}
    old_logging_disable = logging.root.manager.disable
    logging.disable(logging.CRITICAL)
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return _probe_real_acp_chain(hermes_home, image_path)
    except Exception:
        return {"instrumentation_available": False}
    finally:
        logging.disable(old_logging_disable)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--hermes-home", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--timeout", type=int, default=30)
    args = parser.parse_args(argv)
    # Never include any argument value in output.  They may contain private
    # paths, prompts, or other user-controlled data.
    result = probe(Path(args.hermes_home), Path(args.image))
    sys.stdout.write(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
