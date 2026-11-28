# HTML Regenerate Streaming Design

## Goal

Regenerating an assistant message in List mode must show formatted HTML while chunks arrive, not switch from plain canvas text to HTML only after completion.

## Approach

- Keep the existing network and refresh flow unchanged. `stream_refresh` continues to control when a repaint happens: `live`, `calm`, or `still`.
- Route real streaming message bodies through the same display-regex and MuPDF HTML path as completed bodies. Append the existing `▌` caret to the rendered partial, without changing stored message content.
- Keep the synthetic non-streaming “thinking” pulse on the lightweight plain-text path. Keep canvas text as the failure fallback when MuPDF cannot construct or blit a document.
- Strengthen the existing real-path regenerate smoke test so it paints after each chunk and after completion, inspects the resulting HTML entries, checks every dirty request is regional `partial`, and verifies the final `2/2` swipe state.
- Update stale comments and `AGENTS.md`: HTML is now the normal renderer, not an experimental Debug mode.

## Boundaries

Book mode, Book themes, emoji/GFX support, and changes to HTML image-link behavior are separate work. No network, pacing, persistence, or user-setting changes are included. No git commit or push is made without explicit confirmation.

## Verification

The strengthened regenerate test must fail on the current plain-text streaming branch before production code changes. Then run the full KOReader UI smoke, Book smoke, LuaJIT syntax over every Lua file, i18n coverage, and `git diff --check`.
